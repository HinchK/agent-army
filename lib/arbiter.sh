#!/bin/bash
set -euo pipefail

_ARB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_ARB_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_ARB_DIR/common.sh"
# shellcheck source=lib/config.sh disable=SC1091
source "$_ARB_DIR/config.sh"
# shellcheck source=lib/worktree.sh disable=SC1091
source "$_ARB_DIR/worktree.sh"
# shellcheck source=lib/partition.sh disable=SC1091
source "$_ARB_DIR/partition.sh"

ARBITER_QUEUE="integration.jsonl"

_arbiter_queue_path() {
  printf '%s/.agent-army/%s' "$1" "$ARBITER_QUEUE"
}

_arbiter_ref() {
  local slug
  slug="$(state_read_slug "$1")"
  printf 'refs/heads/army/%s/integration' "$slug"
}

# --- lock with stopped-holder reaping ---------------------------------------

_arbiter_lock_stale() {
  local lock_dir="$1"
  local pid
  pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    return 0
  fi
  # kill -0 succeeds for a STOPPED process, so it is only half the liveness
  # check; a holder whose ps state starts with T (T, TN, T+) is stale too.
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  local state
  state="$(ps -o state= -p "$pid" 2>/dev/null | awk '{print substr($1,1,1)}' || true)"
  if [ "$state" = "T" ]; then
    return 0
  fi
  return 1
}

# arbiter_lock <state_dir> [lock_name]
arbiter_lock() {
  local state_dir="$1"
  local name="${2:-arbiter.lock}"
  local lock_dir="$state_dir/$name"
  mkdir -p "$state_dir"
  local tries=0
  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' $$ > "$lock_dir/pid"
      return 0
    fi
    if _arbiter_lock_stale "$lock_dir"; then
      rm -rf "$lock_dir"
      continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "${ARBITER_LOCK_WAIT_TRIES:-50}" ]; then
      log_error "arbiter_lock: lock busy at $lock_dir"
      return 1
    fi
    sleep "${ARBITER_LOCK_POLL_SEC:-0.1}"
  done
}

# arbiter_unlock <state_dir> [lock_name]
arbiter_unlock() {
  local state_dir="${1:?state_dir required}"
  local name="${2:-arbiter.lock}"
  rm -rf "${state_dir:?}/${name}" 2>/dev/null || true
}

# --- queue primitives -------------------------------------------------------

# arbiter_init_ref <repo_dir> [base_commit]
arbiter_init_ref() {
  local repo_dir="$1"
  local base="${2:-HEAD}"
  local ref
  ref="$(_arbiter_ref "$repo_dir")"
  if git -C "$repo_dir" show-ref --verify --quiet "$ref"; then
    log_error "arbiter_init_ref: $ref already exists"
    return 1
  fi
  git -C "$repo_dir" update-ref "$ref" "$(git -C "$repo_dir" rev-parse "$base")"
}

# _arbiter_enqueue_locked <queue> <row>
_arbiter_enqueue_locked() {
  printf '%s\n' "$2" >> "$1"
}

# arbiter_enqueue <repo_dir> <task_id> <seat> <sha> [priority] [supersedes_task_id]
# Appends one queued row under the arbiter lock so a concurrent drain's
# read-rewrite cycle can never drop the record (drain holds the same lock for
# the whole pick/merge/rewrite loop).
arbiter_enqueue() {
  local repo_dir="$1"
  local task_id="$2"
  local seat="$3"
  local sha="$4"
  local priority="${5:-normal}"
  local supersedes="${6:-}"
  local queue
  queue="$(_arbiter_queue_path "$repo_dir")"
  local state_dir
  state_dir="$(dirname "$queue")"
  mkdir -p "$state_dir"
  touch "$queue"
  local ts row
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  row="$(jq -nc \
    --arg ts "$ts" \
    --arg t "$task_id" \
    --arg s "$seat" \
    --arg sha "$sha" \
    --arg p "$priority" \
    --arg sup "$supersedes" \
    '{ts:$ts,ticket:$t,seat:$s,sha:$sha,status:"queued",priority:$p,supersedes:$sup}')"
  local append_rc=0
  arbiter_lock "$state_dir" || return 1
  _arbiter_enqueue_locked "$queue" "$row" || append_rc=$?
  arbiter_unlock "$state_dir"
  return "$append_rc"
}

# _arbiter_pick <queue_path>
# Prints "<index>\n<record-json>" for the next queued record: priority=front
# first, then oldest ts. Prints nothing when no queued records remain.
_arbiter_pick() {
  local queue="$1"
  resolve_python
  "$PYTHON_BIN" - "$queue" <<'PY'
import json
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

queued = [(i, r) for i, r in enumerate(rows) if r.get("status") == "queued"]
if not queued:
    sys.exit(0)
front = [(i, r) for i, r in queued if r.get("priority") == "front"]
pick = front[0] if front else queued[0]
print(pick[0])
print(json.dumps(pick[1]))
PY
}

# _arbiter_rewrite <queue_path> <mode> [args...]
# Modes (atomically rewrite integration.jsonl under the arbiter lock):
#   mark_index <index> <status>
#   mark_ticket <ticket> <from_status> <to_status>
#   mark_integrated <to_status>
_arbiter_rewrite() {
  local queue="$1"
  local mode="$2"
  shift 2
  resolve_python
  "$PYTHON_BIN" - "$queue" "$mode" "$@" <<'PY'
import json
import os
import sys

queue, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
rows = []
with open(queue, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

if mode == "mark_index":
    idx, status = int(args[0]), args[1]
    rows[idx]["status"] = status
elif mode == "mark_ticket":
    ticket, from_status, to_status = args[0], args[1], args[2]
    for row in rows:
        if row.get("status") == from_status and row.get("ticket") == ticket:
            row["status"] = to_status
elif mode == "mark_integrated":
    to_status = args[0]
    for row in rows:
        if row.get("status") == "integrated":
            row["status"] = to_status
else:
    raise SystemExit("unknown rewrite mode: %s" % mode)

tmp = queue + ".tmp.$$"
with open(tmp, "w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")
os.replace(tmp, queue)
PY
}

_arbiter_write_failure() {
  local repo_dir="$1"
  local status="$2" ticket="$3" seat="$4" sha="$5" tip="$6" gate_log="${7:-}"
  local owns
  owns="$(git -C "$repo_dir" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null || true)"
  local state_dir="$repo_dir/.agent-army"
  jq -n \
    --arg status "$status" \
    --arg ticket "$ticket" \
    --arg seat "$seat" \
    --arg sha "$sha" \
    --arg tip "$tip" \
    --arg gate_log "$gate_log" \
    --argjson owns "$(printf '%s\n' "$owns" | jq -R . | jq -s .)" \
    '{status:$status,ticket:$ticket,seat:$seat,sha:$sha,integration_tip:$tip,gate_log:$gate_log,owns:$owns}' \
    > "$state_dir/drain-failure.json"
}

# arbiter_drain <repo_dir>
# Merges queued GREEN shas onto army/<slug>/integration in a detached
# worktree, gates each combined tree under the clean environment, and
# CAS-updates the ref. Returns 0 on full drain, 2 on conflict/integration_red
# (record and successors stay queued; drain-failure.json is written).
arbiter_drain() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local state_dir="$repo_dir/.agent-army"
  local queue
  queue="$(_arbiter_queue_path "$repo_dir")"
  [ -f "$queue" ] || return 0

  local ref
  ref="$(_arbiter_ref "$repo_dir")"
  local slug
  slug="$(state_read_slug "$repo_dir")"
  local wt="$state_dir/worktrees/arbiter-$slug"

  arbiter_lock "$state_dir" || return 1
  local rc=0
  _arbiter_drain_locked "$repo_dir" "$queue" "$ref" "$wt" "$slug" || rc=$?
  arbiter_unlock "$state_dir"
  return "$rc"
}

_arbiter_drain_locked() {
  local repo_dir="$1"
  local queue="$2"
  local ref="$3"
  local wt="$4"
  local slug="$5"
  local state_dir="$repo_dir/.agent-army"

  local test_cmd
  test_cmd="$(/bin/bash -c 'TEST_CMD=""; source "$1" >/dev/null 2>&1; printf "%s" "${TEST_CMD:-}"' _ "$state_dir/profile.env" 2>/dev/null || true)"
  if [ -z "$test_cmd" ]; then
    log_error "arbiter_drain: no TEST_CMD in $state_dir/profile.env"
    return 1
  fi
  local gate_timeout="${ARMY_VERIFY_TIMEOUT_SEC:-${ARMY_TASK_TIMEOUT_SEC:-1800}}"

  while true; do
    local sel
    sel="$(_arbiter_pick "$queue")"
    if [ -z "$sel" ]; then
      break
    fi
    local idx rec ticket seat sha supersedes
    idx="$(printf '%s\n' "$sel" | sed -n 1p)"
    rec="$(printf '%s\n' "$sel" | sed -n 2p)"
    ticket="$(printf '%s' "$rec" | jq -r '.ticket')"
    seat="$(printf '%s' "$rec" | jq -r '.seat')"
    sha="$(printf '%s' "$rec" | jq -r '.sha')"
    supersedes="$(printf '%s' "$rec" | jq -r '.supersedes // ""')"

    local i0
    i0="$(git -C "$repo_dir" rev-parse "$ref")"

    if ! git -C "$repo_dir" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
      if [ -d "$wt" ]; then
        rm -rf "$wt"
      fi
      mkdir -p "$(dirname "$wt")"
      git -C "$repo_dir" worktree add --detach "$wt" "$i0" >/dev/null 2>&1
    fi
    git -C "$wt" checkout -f --detach "$i0" >/dev/null 2>&1
    git -C "$wt" reset --hard "$i0" >/dev/null
    git -C "$wt" clean -fdq >/dev/null 2>&1 || true

    if ! git -C "$wt" merge --no-edit "$sha" >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      git -C "$wt" reset --hard "$i0" >/dev/null
      git -C "$wt" clean -fdq >/dev/null 2>&1 || true
      log_error "arbiter_drain: conflict merging $ticket ($sha) onto $i0"
      _arbiter_write_failure "$repo_dir" "conflict" "$ticket" "$seat" "$sha" "$i0" ""
      return 2
    fi

    local gate_log="$state_dir/gate-logs/arbiter-$ticket.log"
    mkdir -p "$state_dir/gate-logs"
    if ! clean_gate_exec "$wt" "$state_dir/profile.env" "$gate_timeout" "$test_cmd" > "$gate_log" 2>&1; then
      git -C "$wt" reset --hard "$i0" >/dev/null
      git -C "$wt" clean -fdq >/dev/null 2>&1 || true
      log_error "arbiter_drain: combined-tree gate red for $ticket (log: $gate_log)"
      _arbiter_write_failure "$repo_dir" "integration_red" "$ticket" "$seat" "$sha" "$i0" "$gate_log"
      return 2
    fi

    local candidate
    candidate="$(git -C "$wt" rev-parse HEAD)"
    if ! git -C "$repo_dir" update-ref "$ref" "$candidate" "$i0" 2>/dev/null; then
      git -C "$wt" reset --hard "$i0" >/dev/null
      log_error "arbiter_drain: CAS update of $ref failed (tip moved)"
      _arbiter_write_failure "$repo_dir" "conflict" "$ticket" "$seat" "$sha" "$i0" ""
      return 2
    fi

    _arbiter_rewrite "$queue" "mark_index" "$idx" "integrated"
    if [ -n "$supersedes" ]; then
      _arbiter_rewrite "$queue" "mark_ticket" "$supersedes" "queued" "superseded"
    fi
  done

  rm -f "$state_dir/drain-failure.json"
  return 0
}

# _arb_promote_pane_check
# Refuses when HERDR_PANE_ID names a pane occupied by a live Herdr agent; the
# outer commander.py process runs with the variable unset and passes.
_arb_promote_pane_check() {
  local pane="${HERDR_PANE_ID:-}"
  if [ -z "$pane" ]; then
    return 0
  fi
  local listing
  listing="$(herdr agent list 2>/dev/null || true)"
  if [ -z "$listing" ]; then
    log_error "_arb_promote_pane_check: cannot verify HERDR_PANE_ID '$pane' (herdr agent list empty)"
    return 1
  fi
  resolve_python
  if "$PYTHON_BIN" - "$listing" "$pane" <<'PY'
import json
import sys

raw, pane = sys.argv[1], sys.argv[2]


def items(raw):
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("agents", "items", "data"):
            if isinstance(data.get(key), list):
                return data[key]
        return [data]
    return []


for item in items(raw):
    if not isinstance(item, dict):
        continue
    if str(item.get("pane_id") or item.get("pane") or "") == pane:
        sys.exit(1)
sys.exit(0)
PY
  then
    return 0
  fi
  log_error "_arb_promote_pane_check: HERDR_PANE_ID '$pane' is occupied by a live Herdr agent"
  return 1
}

# _arbiter_promote_mark <repo_dir> <queue>
# Releases integrated/superseded leases, rewrites integrated->promoted, and
# prints the promoted count. Runs under the arbiter lock.
_arbiter_promote_mark() {
  local repo_dir="$1"
  local queue="$2"
  local tickets
  tickets="$("$PYTHON_BIN" - "$queue" <<'PY'
import json
import sys

promoted = []
superseded = []
rows = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
for row in rows:
    if row.get("status") == "integrated":
        promoted.append(row.get("ticket", ""))
    elif row.get("status") == "superseded":
        superseded.append(row.get("ticket", ""))
for ticket in promoted + superseded:
    print(ticket)
PY
)"
  if [ -n "$tickets" ]; then
    local ticket
    while IFS= read -r ticket; do
      [ -n "$ticket" ] || continue
      partition_release_task "$repo_dir" "$ticket" >/dev/null 2>&1 || true
    done <<< "$tickets"
  fi

  local count
  count="$(jq -r 'select(.status == "integrated") | .ticket' "$queue" | wc -l | tr -d ' ')"
  _arbiter_rewrite "$queue" "mark_integrated" "promoted"
  printf '%s\n' "$count"
}

# arbiter_promote <repo_dir> --confirm
# Fast-forwards local main to the integration tip (never pushes), marks
# integrated records promoted, releases their leases, and syncs the idle
# worktree pool. Prints the number of promoted records.
arbiter_promote() {
  local repo_dir="${1:-}"
  local confirm="${2:-}"
  if [ "$confirm" != "--confirm" ]; then
    log_error "arbiter_promote: refusing to run without --confirm"
    return 1
  fi
  repo_dir="$(cd "$repo_dir" && pwd -P)"

  _arb_promote_pane_check || return 1

  local slug
  slug="$(state_read_slug "$repo_dir")"
  local base_branch="main"
  if [ -f "$repo_dir/army.config.toml" ]; then
    base_branch="$(config_dump "$repo_dir/army.config.toml" | grep -E '^export ARMY_BASE_BRANCH=' | sed -E "s/^export ARMY_BASE_BRANCH=(.*)$/\1/" | tr -d \')"
  fi

  local current_branch
  current_branch="$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$current_branch" != "$base_branch" ]; then
    log_error "arbiter_promote: root checkout is on '$current_branch', expected '$base_branch'"
    return 1
  fi
  local porcelain
  # Parity with preflight_check: the README quickstart leaves
  # army.config.toml untracked and mission.md lives beside the repo, so both
  # `??` lines are tolerated there. Promote must accept exactly the same two
  # (they cannot affect a fast-forward) or every first-run wave halts with a
  # misleading PROMOTE_FAILED handoff. Anything else stays dirty.
  porcelain="$(git -C "$repo_dir" status --porcelain | grep -vE '^\?\? (army\.config\.toml|mission\.md)$' || true)"
  if [ -n "$porcelain" ]; then
    log_error "arbiter_promote: root checkout has uncommitted changes"
    return 1
  fi

  if ! git -C "$repo_dir" merge --ff-only "refs/heads/army/$slug/integration" >/dev/null 2>&1; then
    log_error "arbiter_promote: main cannot fast-forward to army/$slug/integration"
    return 1
  fi

  local queue
  queue="$(_arbiter_queue_path "$repo_dir")"
  [ -f "$queue" ] || { printf '0\n'; return 0; }

  resolve_python
  # The tickets read and the mark_integrated rewrite happen under the arbiter
  # lock: an enqueue landing between them would otherwise be silently dropped
  # by the os.replace rewrite (the same failure mode drain's lock prevents).
  # The guarded call keeps the unlock on every path.
  local mark_rc=0 count=""
  arbiter_lock "$repo_dir/.agent-army" || return 1
  count="$(_arbiter_promote_mark "$repo_dir" "$queue")" || mark_rc=$?
  arbiter_unlock "$repo_dir/.agent-army"
  if [ "$mark_rc" -ne 0 ]; then
    return "$mark_rc"
  fi

  local target
  target="$(git -C "$repo_dir" rev-parse HEAD)"
  worktree_sync_pool "$repo_dir" "$target" ""
  printf '%s\n' "$count"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    init-ref)
      shift
      arbiter_init_ref "$@"
      ;;
    enqueue)
      shift
      arbiter_enqueue "$@"
      ;;
    drain)
      shift
      arbiter_drain "$@"
      ;;
    promote)
      shift
      arbiter_promote "$@"
      ;;
    *)
      echo "Usage: arbiter.sh {init-ref|enqueue|drain|promote} <args>" >&2
      exit 1
      ;;
  esac
fi
