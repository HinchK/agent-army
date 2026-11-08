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

# _briefs_write_prompt_marker <prompt_ts_file>
# Records "<epoch-seconds.fraction> <nonce>". The nonce uniquifies each
# attempt; the sub-second timestamp lets supervisor_read_anchor reject an
# anchor written back within the same 1-second mtime tick. Written AFTER the
# fresh agent session starts, so any anchor predating this attempt (the
# previous agent is interrupted best-effort by providers_start_fresh_session)
# is older than the marker.
_briefs_write_prompt_marker() {
  resolve_python
  "$PYTHON_BIN" -c 'import secrets, time; print("%.6f %s" % (time.time(), secrets.token_hex(4)))' > "$1"
}

# _briefs_valid_task_id <id>
# Mirrors commander.py's _TASK_ID_RE: 1-64 chars of [A-Za-z0-9_-] starting
# with an alphanumeric. Ids are interpolated into anchor/brief paths, so a
# '/' or '..' would escape those directories.
_briefs_valid_task_id() {
  local id="$1"
  case "$id" in
    ''|*[!A-Za-z0-9_-]*|[-_]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

# briefs_dispatch_task <repo_dir> <seat> <wave> <task_id> <xml_file_src>
#
# Seating order per dispatch:
#   1. rm -f the seat's stale anchor file
#   2. write .active_task
#   3. copy the brief into <worktree>/.agent-army/briefs/<wave>-<task_id>.xml
#   4. snapshot the pre-task worktree state (best effort, dirty only)
#   5. start a fresh agent session on the existing pane (interrupts any
#      previous attempt first), THEN record the nonce prompt marker
#   6. herdr agent prompt <seat>-<slug> with a <200 byte file-path prompt
#   7. sleep ARMY_SUBMIT_DELAY (default 1) && herdr agent send-keys <target> enter
briefs_dispatch_task() {
  local repo_dir="$1"
  local seat="$2"
  local wave="$3"
  local task_id="$4"
  local xml_src="$5"

  # task_id is interpolated into anchor/brief paths: reject anything the
  # Python boundary would reject (path traversal, hidden files, separators).
  if ! _briefs_valid_task_id "$task_id"; then
    log_error "briefs_dispatch_task: invalid task id '$task_id' (need [A-Za-z0-9][A-Za-z0-9_-]{0,63})"
    return 1
  fi

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
  printf '%s\n' "$task_id" > "$worktree_dir/.agent-army/.active_task"
  cp "$xml_src" "$briefs_dir/${wave}-${task_id}.xml"

  if [ -n "$(git -C "$worktree_dir" status --porcelain)" ]; then
    worktree_snapshot "$repo_dir" "$seat" >/dev/null 2>&1 || true
  fi

  providers_prepare_seat "$worktree_dir" "$kind" "$model"
  providers_start_fresh_session "$repo_dir" "$seat" "$pane_id" "$kind" "$model"
  _briefs_write_prompt_marker "$anchors_dir/${task_id}.prompt_ts"
  providers_submit_prompt "${seat}-${slug}" "Read .agent-army/briefs/${wave}-${task_id}.xml, execute the task within scope, commit your work, and write the completion anchor file."
}

# briefs_dispatch_verifier <repo_dir> <wave> <task_id> <verify_xml_src>
# Same flow on the verifier seat using the .verify anchor namespace.
briefs_dispatch_verifier() {
  local repo_dir="$1"
  local wave="$2"
  local task_id="$3"
  local verify_xml_src="$4"

  # Same charset guard as briefs_dispatch_task: the id reaches anchor paths.
  if ! _briefs_valid_task_id "$task_id"; then
    log_error "briefs_dispatch_verifier: invalid task id '$task_id' (need [A-Za-z0-9][A-Za-z0-9_-]{0,63})"
    return 1
  fi

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
  printf '%s\n' "$task_id" > "$worktree_dir/.agent-army/.active_task"
  cp "$verify_xml_src" "$briefs_dir/${wave}-${task_id}-verify.xml"

  providers_prepare_seat "$worktree_dir" "$kind" "$model"
  providers_start_fresh_session "$repo_dir" "verifier" "$pane_id" "$kind" "$model"
  _briefs_write_prompt_marker "$anchors_dir/${task_id}.verify.prompt_ts"
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
