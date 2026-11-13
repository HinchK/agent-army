#!/bin/bash
set -euo pipefail

_LIFECYCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_LIFECYCLE_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_LIFECYCLE_DIR/common.sh"
# shellcheck source=lib/config.sh disable=SC1091
source "$_LIFECYCLE_DIR/config.sh"
# shellcheck source=lib/worktree.sh disable=SC1091
source "$_LIFECYCLE_DIR/worktree.sh"
# shellcheck source=lib/providers.sh disable=SC1091
source "$_LIFECYCLE_DIR/providers.sh"

_parse_pane_id() {
  local out="${1:-}"
  local cand=""
  if printf '%s' "$out" | jq -e '.result.pane.pane_id' >/dev/null 2>&1; then
    cand="$(printf '%s' "$out" | jq -r '.result.pane.pane_id')"
    printf '%s' "$cand"
    return 0
  fi
  cand="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]+:[A-Za-z0-9_-]+' | head -n 1 || true)"
  if [ -z "$cand" ]; then
    cand="$(printf '%s\n' "$out" | tail -n 1 | tr -d '[:space:]')"
  fi
  printf '%s' "$cand"
}

# swarm_up <repo_dir> <config_path>
# Seats the standing pool: exclude -> provision worktrees -> pane split with
# --cwd <worktree> --direction right --no-focus -> credential-free agent start
# -> seats.json.
# Reuses existing seat records whose agents still respond. Never creates an
# ops pane.
swarm_up() {
  local repo_dir="$1"
  local config_path="$2"
  repo_dir="$(cd "$repo_dir" && pwd -P)"

  eval "$(config_dump "$config_path")"
  ensure_git_exclude "$repo_dir"
  local slug
  slug="$(state_read_slug "$repo_dir")"

  local ws_id=""
  ws_id="$(find_workspace_by_cwd "$repo_dir" || true)"

  local state_dir="$repo_dir/.agent-army"
  local seats_file="$state_dir/seats.json"
  mkdir -p "$state_dir"

  local -a roster=() toks
  while read -r -a toks; do
    roster+=("${toks[@]}")
  done <<< "${SEAT_IDS:-}"
  if [ "${#roster[@]}" -eq 0 ]; then
    log_error "swarm_up: config declares no seats"
    return 1
  fi

  local seats_json="{}"
  if [ -f "$seats_file" ]; then
    seats_json="$(cat "$seats_file")"
  fi

  for seat in "${roster[@]}"; do
    local seat_upper
    seat_upper="$(printf '%s' "$seat" | tr '[:lower:]-' '[:upper:]_')"
    local kind model role worktree_flag critical
    kind="$(eval "printf '%s' \"\${SEAT_${seat_upper}_KIND:-opencode}\"")"
    model="$(eval "printf '%s' \"\${SEAT_${seat_upper}_MODEL:-}\"")"
    role="$(eval "printf '%s' \"\${SEAT_${seat_upper}_ROLE:-worker}\"")"
    worktree_flag="$(eval "printf '%s' \"\${SEAT_${seat_upper}_WORKTREE:-true}\"")"
    critical="$(eval "printf '%s' \"\${SEAT_${seat_upper}_CRITICAL:-false}\"")"
    [ "$critical" = "true" ] || critical=false

    local agent="${seat}-${slug}"
    # local is function-scoped, so a previous seat's worktree must be cleared
    # or a reused seat records the prior seat's path.
    local pane_id=""
    local wt=""
    local branch=""

    local existing_pane=""
    existing_pane="$(jq -r --arg s "$seat" '.seats[$s].pane_id // ""' "$seats_file" 2>/dev/null || true)"
    if [ -n "$existing_pane" ] && herdr agent get "$agent" >/dev/null 2>&1 \
      && [ "$(herdr agent get "$agent" 2>/dev/null | herdr_agent_status_json)" != "" ]; then
      pane_id="$existing_pane"
    else
      if [ "$worktree_flag" != "false" ]; then
        wt="$(worktree_provision "$repo_dir" "$seat")"
      else
        wt="$repo_dir"
      fi
      branch="army/$slug/$seat"
      providers_prepare_seat "$wt" "$kind" "$model"

      local split_out=""
      if [ -n "$ws_id" ]; then
        split_out="$(herdr --workspace "$ws_id" pane split --cwd "$wt" --direction right --no-focus 2>/dev/null || true)"
      fi
      if [ -z "$split_out" ]; then
        split_out="$(herdr pane split --cwd "$wt" --direction right --no-focus)"
      fi
      pane_id="$(_parse_pane_id "$split_out")"
      if [ -z "$pane_id" ]; then
        log_error "swarm_up: could not parse a pane id from pane split output for seat '$seat'"
        return 1
      fi
      providers_start_fresh_session "$repo_dir" "$seat" "$pane_id" "$kind" "$model"
    fi

    if [ -z "${wt:-}" ]; then
      wt="$(jq -r --arg s "$seat" '.seats[$s].worktree_dir // ""' "$seats_file" 2>/dev/null || true)"
    fi
    branch="army/$slug/$seat"
    seats_json="$(jq \
      --arg seat "$seat" \
      --arg pane "$pane_id" \
      --arg agent "$agent" \
      --arg kind "$kind" \
      --arg model "$model" \
      --arg role "$role" \
      --arg wt "$wt" \
      --arg branch "$branch" \
      --arg critical "$critical" \
      '.seats[$seat] = {pane_id:$pane, agent_name:$agent, kind:$kind, model:$model, role:$role, worktree_dir:$wt, branch:$branch, critical:($critical == "true")}' \
      <<< "$seats_json")"
  done

  if [ -n "$ws_id" ]; then
    seats_json="$(jq --arg ws "$ws_id" '.workspace_id = $ws' <<< "$seats_json")"
  fi

  local tmp_seats="$state_dir/seats.json.tmp.$$"
  printf '%s\n' "$seats_json" > "$tmp_seats"
  mv "$tmp_seats" "$seats_file"
}

# swarm_verify_seats <repo_dir> <config_path>
# Checks the configured roster against seats.json and `herdr agent list`.
# Fails closed when any critical seat is missing.
swarm_verify_seats() {
  local repo_dir="$1"
  local config_path="$2"
  repo_dir="$(cd "$repo_dir" && pwd -P)"

  eval "$(config_dump "$config_path")"
  local slug
  slug="$(state_read_slug "$repo_dir")"
  local seats_file="$repo_dir/.agent-army/seats.json"
  if [ ! -f "$seats_file" ]; then
    log_error "swarm_verify_seats: missing $seats_file (run swarm_up first)"
    return 1
  fi

  local agent_listing
  agent_listing="$(herdr agent list 2>/dev/null || true)"

  local -a toks
  while read -r -a toks; do
    local seat seat_upper critical agent_name recorded
    for seat in "${toks[@]}"; do
      [ -n "$seat" ] || continue
      seat_upper="$(printf '%s' "$seat" | tr '[:lower:]-' '[:upper:]_')"
      critical="$(eval "printf '%s' \"\${SEAT_${seat_upper}_CRITICAL:-false}\"")"
      agent_name="${seat}-${slug}"

      recorded="$(jq -r --arg s "$seat" '.seats[$s].agent_name // ""' "$seats_file" 2>/dev/null || true)"
      if [ "$recorded" != "$agent_name" ]; then
        log_error "swarm_verify_seats: seat '$seat' not recorded in seats.json"
        return 1
      fi

      if ! printf '%s' "$agent_listing" | grep -qF "$agent_name"; then
        if [ "$critical" = "true" ]; then
          log_error "swarm_verify_seats: critical seat agent '$agent_name' is not live"
          return 1
        fi
        log_warn "swarm_verify_seats: non-critical seat agent '$agent_name' is not live"
      fi
    done
  done <<< "${SEAT_IDS:-}"
}

# swarm_down <repo_dir>
# Snapshots any dirty worktrees and closes only the panes recorded in
# seats.json. Worktrees themselves stay standing for inspection.
swarm_down() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local seats_file="$repo_dir/.agent-army/seats.json"
  if [ ! -f "$seats_file" ]; then
    log_warn "swarm_down: no $seats_file; nothing to close"
    return 0
  fi

  local slug
  slug="$(state_read_slug "$repo_dir")"

  local seat pane_id wt
  while IFS=$'\t' read -r seat pane_id wt; do
    [ -n "$seat" ] || continue
    if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null || true)" ]; then
      worktree_snapshot "$repo_dir" "$seat" >/dev/null 2>&1 || true
    fi
    if [ -n "$pane_id" ]; then
      herdr pane close "$pane_id" >/dev/null 2>&1 || true
    fi
  done < <(jq -r '.seats | to_entries[] | [.key, .value.pane_id // "", .value.worktree_dir // ""] | @tsv' "$seats_file")
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    up)
      shift
      swarm_up "$@"
      ;;
    verify)
      shift
      swarm_verify_seats "$@"
      ;;
    down)
      shift
      swarm_down "$@"
      ;;
    *)
      echo "Usage: lifecycle.sh {up|verify|down} <repo_dir> <config_path>" >&2
      exit 1
      ;;
  esac
fi
