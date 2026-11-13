#!/bin/bash
set -euo pipefail

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_COMMON_DIR/pyenv.sh"

log_info() {
  printf '[army:info] %s\n' "$*" >&2
}

log_warn() {
  printf '[army:warn] %s\n' "$*" >&2
}

log_error() {
  printf '[army:error] %s\n' "$*" >&2
}

# herdr_agent_status_json
# Reads one `herdr agent get` payload on stdin. Live herdr wraps the agent
# under .result.agent; the test mock prints agent_status at the top level.
herdr_agent_status_json() {
  jq -r '.result.agent.agent_status // .agent_status // ""' 2>/dev/null || true
}

slugify() {
  local raw="${1:-}"
  local slug
  slug="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  if [ -z "$slug" ]; then
    slug="project"
  elif ! printf '%s' "$slug" | grep -qE '^[a-z]'; then
    slug="a-${slug}"
  fi
  printf '%s\n' "$slug"
}

state_init_slug() {
  local repo_dir="$1"
  local army_name="$2"
  local state_dir="$repo_dir/.agent-army"
  local state_file="$state_dir/state.json"

  mkdir -p "$state_dir"

  if [ -f "$state_file" ]; then
    local existing_slug
    existing_slug="$(jq -r '.slug // empty' "$state_file" 2>/dev/null || true)"
    if [ -n "$existing_slug" ]; then
      printf '%s\n' "$existing_slug"
      return 0
    fi
  fi

  local slug
  slug="$(slugify "$army_name")"
  local tmp_file="$state_file.tmp.$$"

  if [ -f "$state_file" ]; then
    jq --arg slug "$slug" \
      '.slug = $slug | .zero_integrate_waves = (.zero_integrate_waves // 0) | .status = (.status // "idle")' \
      "$state_file" > "$tmp_file"
  else
    jq -n --arg slug "$slug" \
      '{slug: $slug, zero_integrate_waves: 0, status: "idle"}' > "$tmp_file"
  fi
  mv "$tmp_file" "$state_file"
  printf '%s\n' "$slug"
}

state_read_slug() {
  local repo_dir="$1"
  local state_file="$repo_dir/.agent-army/state.json"
  if [ ! -f "$state_file" ]; then
    log_error "State file not found: $state_file"
    return 1
  fi
  local slug
  slug="$(jq -r '.slug // empty' "$state_file" 2>/dev/null || true)"
  if [ -z "$slug" ]; then
    log_error "Missing .slug in $state_file"
    return 1
  fi
  printf '%s\n' "$slug"
}

# git_exclude_ensure <repo_dir> <pattern>
# Idempotently appends <pattern> to the shared .git/info/exclude (the common
# git dir is shared by every linked worktree, so one write covers all seats).
git_exclude_ensure() {
  local repo_dir="$1"
  local pattern="$2"
  local common_dir
  common_dir="$(git -C "$repo_dir" rev-parse --git-common-dir)"
  case "$common_dir" in
    /*) ;;
    *) common_dir="$repo_dir/$common_dir" ;;
  esac
  local exclude_file="$common_dir/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"

  if ! grep -qxF "$pattern" "$exclude_file" 2>/dev/null; then
    if [ -s "$exclude_file" ] && [ "$(tail -c 1 "$exclude_file" | wc -l | tr -d ' ')" -eq 0 ]; then
      printf '\n' >> "$exclude_file"
    fi
    printf '%s\n' "$pattern" >> "$exclude_file"
  fi
}

ensure_git_exclude() {
  git_exclude_ensure "$1" '.agent-army/'
}

clean_gate_exec() {
  local cwd="$1"
  local profile_env_file="$2"
  local timeout_sec="$3"
  local test_cmd="$4"

  local state_dir
  if [ -n "$profile_env_file" ]; then
    state_dir="$(cd "$(dirname "$profile_env_file")" 2>/dev/null && pwd -P || printf '%s/.agent-army' "$cwd")"
  else
    state_dir="$cwd/.agent-army"
  fi
  local gate_tmp="$state_dir/gate-tmp"
  mkdir -p "$gate_tmp"

  local env_args=()
  env_args+=("PATH=${PATH:-/usr/bin:/bin}")
  env_args+=("HOME=${HOME:-/tmp}")
  env_args+=("CI=true")
  env_args+=("TMPDIR=$gate_tmp")

  if [ -n "$profile_env_file" ] && [ -f "$profile_env_file" ]; then
    local tc_lines
    # shellcheck disable=SC2016
    tc_lines="$(
      /bin/bash -c '
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$1"
        for token in ${TOOLCHAIN_VARS:-}; do
          case "$token" in
            HERDR_*|REPO_DIR=*|STATE_DIR=*|CI=*|PATH=*|HOME=*|TMPDIR=*|HERDR|REPO_DIR|STATE_DIR|CI|PATH|HOME|TMPDIR)
              continue
              ;;
            *=*)
              printf "%s\n" "$token"
              ;;
            *)
              if [ -n "${!token:-}" ]; then
                printf "%s=%s\n" "$token" "${!token}"
              fi
              ;;
          esac
        done
      ' _ "$profile_env_file"
    )"
    if [ -n "$tc_lines" ]; then
      while IFS= read -r line; do
        if [ -n "$line" ]; then
          env_args+=("$line")
        fi
      done <<< "$tc_lines"
    fi
  fi

  local timeout_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=("$(command -v timeout)" "$timeout_sec")
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=("$(command -v gtimeout)" "$timeout_sec")
  else
    resolve_python
    timeout_cmd=(
      "$PYTHON_BIN" -c
      'import subprocess,sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=int(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)'
      "$timeout_sec"
    )
  fi

  (
    cd "$cwd"
    env -i "${env_args[@]}" "${timeout_cmd[@]}" /bin/bash -c "$test_cmd"
  )
}

find_workspace_by_cwd() {
  local repo_dir="$1"
  if [ ! -d "$repo_dir" ]; then
    log_error "Repository directory does not exist: $repo_dir"
    return 1
  fi
  local phys_cwd
  phys_cwd="$(cd "$repo_dir" && pwd -P)"
  local ws_out=""
  local pane_out=""
  if command -v herdr >/dev/null 2>&1; then
    ws_out="$(herdr workspace list 2>/dev/null || true)"
    pane_out="$(herdr pane list 2>/dev/null || true)"
  fi

  resolve_python
  "$PYTHON_BIN" - "$phys_cwd" "$ws_out" "$pane_out" <<'PY'
import json
import os
import sys

target = os.path.realpath(sys.argv[1])
ws_raw = sys.argv[2]
pane_raw = sys.argv[3]

def norm(p):
    if not p or not isinstance(p, str):
        return ""
    try:
        return os.path.realpath(p)
    except Exception:
        return p.rstrip("/")

def extract_items(raw):
    if not raw.strip():
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return data
        if isinstance(data, dict):
            for k in ("workspaces", "panes", "items", "data"):
                if isinstance(data.get(k), list):
                    return data[k]
            return [data]
    except Exception:
        pass
    return []

for item in extract_items(ws_raw):
    if not isinstance(item, dict):
        continue
    cwd = item.get("cwd") or item.get("path") or item.get("root") or item.get("directory")
    if norm(cwd) == target:
        ws_id = item.get("workspace_id") or item.get("id") or item.get("name")
        if ws_id:
            print(ws_id)
            sys.exit(0)

for item in extract_items(pane_raw):
    if not isinstance(item, dict):
        continue
    cwd = item.get("cwd") or item.get("path") or item.get("root") or item.get("directory")
    if norm(cwd) == target:
        ws_id = item.get("workspace_id")
        if not ws_id:
            pane_id = str(item.get("id") or item.get("pane_id") or "")
            if ":" in pane_id:
                ws_id = pane_id.split(":", 1)[0]
        if ws_id:
            print(ws_id)
            sys.exit(0)

for raw in (ws_raw, pane_raw):
    for line in raw.splitlines():
        tokens = line.strip().split()
        if len(tokens) >= 2:
            for tok in tokens[1:]:
                if norm(tok) == target:
                    cand = tokens[0].split(":", 1)[0]
                    print(cand)
                    sys.exit(0)

sys.exit(1)
PY
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    gate)
      shift
      clean_gate_exec "$@"
      ;;
    *)
      echo "Usage: common.sh gate <cwd> <profile_env_file> <timeout_sec> <test_cmd>" >&2
      exit 1
      ;;
  esac
fi
