#!/bin/bash
set -euo pipefail

_BRIEFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_BRIEFS_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_BRIEFS_DIR/common.sh"
# shellcheck source=lib/worktree.sh disable=SC1091
source "$_BRIEFS_DIR/worktree.sh"
# shellcheck source=lib/providers.sh disable=SC1091
source "$_BRIEFS_DIR/providers.sh"

# briefs_dispatch_task <repo_dir> <seat> <wave> <task_id> <xml_file_src>
#
# Exact seating order per dispatch:
#   1. rm -f the seat's stale anchor file
#   2. write .active_task + <task_id>.prompt_ts (epoch seconds)
#   3. copy the brief into <worktree>/.agent-army/briefs/<wave>-<task_id>.xml
#   4. snapshot the pre-task worktree state (best effort, dirty only)
#   5. start a fresh agent session on the existing pane
#   6. herdr agent prompt <seat>-<slug> with a <200 byte file-path prompt
#   7. sleep ARMY_SUBMIT_DELAY (default 1) && herdr agent send-keys <target> enter
briefs_dispatch_task() {
  local repo_dir="$1"
  local seat="$2"
  local wave="$3"
  local task_id="$4"
  local xml_src="$5"

  local slug
  slug="$(state_read_slug "$repo_dir")"
  local seats_file="$repo_dir/.agent-army/seats.json"
  if ! jq -e --arg s "$seat" '.seats[$s]' "$seats_file" >/dev/null 2>&1; then
    log_error "briefs_dispatch_task: seat '$seat' not found in $seats_file"
    return 1
  fi
  local pane_id worktree_dir kind model
  pane_id="$(jq -r --arg s "$seat" '.seats[$s].pane_id' "$seats_file")"
  worktree_dir="$(jq -r --arg s "$seat" '.seats[$s].worktree_dir' "$seats_file")"
  kind="$(jq -r --arg s "$seat" '.seats[$s].kind // "opencode"' "$seats_file")"
  model="$(jq -r --arg s "$seat" '.seats[$s].model // ""' "$seats_file")"

  local anchors_dir="$worktree_dir/.agent-army/anchors"
  local briefs_dir="$worktree_dir/.agent-army/briefs"
  mkdir -p "$anchors_dir" "$briefs_dir"

  rm -f "$anchors_dir/${task_id}.txt"
  printf '%s\n' "$(date +%s)" > "$anchors_dir/${task_id}.prompt_ts"
  printf '%s\n' "$task_id" > "$worktree_dir/.agent-army/.active_task"
  cp "$xml_src" "$briefs_dir/${wave}-${task_id}.xml"

  if [ -n "$(git -C "$worktree_dir" status --porcelain)" ]; then
    worktree_snapshot "$repo_dir" "$seat" >/dev/null 2>&1 || true
  fi

  providers_prepare_seat "$worktree_dir" "$kind" "$model"
  providers_start_fresh_session "$repo_dir" "$seat" "$pane_id" "$kind" "$model"
  providers_submit_prompt "${seat}-${slug}" "Read .agent-army/briefs/${wave}-${task_id}.xml, execute the task within scope, commit your work, and write the completion anchor file."
}

# briefs_dispatch_verifier <repo_dir> <wave> <task_id> <verify_xml_src>
# Same flow on the verifier seat using the .verify anchor namespace.
briefs_dispatch_verifier() {
  local repo_dir="$1"
  local wave="$2"
  local task_id="$3"
  local verify_xml_src="$4"

  local slug
  slug="$(state_read_slug "$repo_dir")"
  local seats_file="$repo_dir/.agent-army/seats.json"
  if ! jq -e '.seats.verifier' "$seats_file" >/dev/null 2>&1; then
    log_error "briefs_dispatch_verifier: no verifier seat in $seats_file"
    return 1
  fi
  local pane_id worktree_dir kind model
  pane_id="$(jq -r '.seats.verifier.pane_id' "$seats_file")"
  worktree_dir="$(jq -r '.seats.verifier.worktree_dir' "$seats_file")"
  kind="$(jq -r '.seats.verifier.kind // "opencode"' "$seats_file")"
  model="$(jq -r '.seats.verifier.model // ""' "$seats_file")"

  local anchors_dir="$worktree_dir/.agent-army/anchors"
  local briefs_dir="$worktree_dir/.agent-army/briefs"
  mkdir -p "$anchors_dir" "$briefs_dir"

  rm -f "$anchors_dir/${task_id}.verify.txt"
  printf '%s\n' "$(date +%s)" > "$anchors_dir/${task_id}.verify.prompt_ts"
  printf '%s\n' "$task_id" > "$worktree_dir/.agent-army/.active_task"
  cp "$verify_xml_src" "$briefs_dir/${wave}-${task_id}-verify.xml"

  providers_prepare_seat "$worktree_dir" "$kind" "$model"
  providers_start_fresh_session "$repo_dir" "verifier" "$pane_id" "$kind" "$model"
  providers_submit_prompt "verifier-${slug}" "Read .agent-army/briefs/${wave}-${task_id}-verify.xml, audit the commit diff, and write the verifier anchor file."
}

# briefs_clear_active_task <worktree_dir>
# Clears the .active_task marker once the seat's task reaches a terminal state
# so worktree_sync_pool may advance it again.
briefs_clear_active_task() {
  rm -f "$1/.agent-army/.active_task" 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    dispatch-task)
      shift
      briefs_dispatch_task "$@"
      ;;
    dispatch-verifier)
      shift
      briefs_dispatch_verifier "$@"
      ;;
    clear-active-task)
      shift
      briefs_clear_active_task "$@"
      ;;
    *)
      echo "Usage: briefs.sh {dispatch-task|dispatch-verifier|clear-active-task} <args>" >&2
      exit 1
      ;;
  esac
fi
