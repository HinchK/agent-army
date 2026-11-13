#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=lib/pyenv.sh disable=SC1091
source "$ROOT_DIR/lib/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/worktree.sh disable=SC1091
source "$ROOT_DIR/lib/worktree.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

init_test_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  echo "hello" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "initial"
}

REPO="$TMP_ROOT/repo"
init_test_repo "$REPO"
SLUG="$(state_init_slug "$REPO" "My Project!")"
if [ "$SLUG" != "my-project" ]; then
  echo "FAIL: expected slug 'my-project', got '$SLUG'" >&2
  exit 1
fi

echo "=== Test 1: worktree_provision creates seat worktree on army/<slug>/<seat> branch ==="
WT_W1="$(worktree_provision "$REPO" "worker_1")"
if [ ! -d "$WT_W1/.agent-army/briefs" ] || [ ! -d "$WT_W1/.agent-army/anchors" ]; then
  echo "FAIL: worktree_provision did not create briefs/anchors dirs" >&2
  exit 1
fi
BRANCH="$(git -C "$WT_W1" symbolic-ref --short HEAD)"
if [ "$BRANCH" != "army/my-project/worker_1" ]; then
  echo "FAIL: expected branch 'army/my-project/worker_1', got '$BRANCH'" >&2
  exit 1
fi

mkdir -p "$WT_W1/.agent-army/anchors"
echo "WORKER DONE #W1-T1 abc" > "$WT_W1/.agent-army/anchors/W1-T1.txt"
PORCELAIN="$(git -C "$WT_W1" status --porcelain)"
if [ -n "$PORCELAIN" ]; then
  echo "FAIL: anchor write inside .agent-army/ dirtied git status: $PORCELAIN" >&2
  exit 1
fi

WT_W1_AGAIN="$(worktree_provision "$REPO" "worker_1")"
if [ "$WT_W1_AGAIN" != "$WT_W1" ]; then
  echo "FAIL: worktree_provision is not idempotent: '$WT_W1_AGAIN' != '$WT_W1'" >&2
  exit 1
fi

echo "=== Test 2: worktree_sync_pool advances idle seats, skips busy + .active_task seats ==="
WT_W2="$(worktree_provision "$REPO" "worker_2")"
WT_VER="$(worktree_provision "$REPO" "verifier")"
BASE_HEAD="$(git -C "$REPO" rev-parse HEAD)"

echo "second" >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "advance main"
MAIN_HEAD="$(git -C "$REPO" rev-parse HEAD)"

worktree_sync_pool "$REPO" "main" "worker_2"
for seat_wt in "$WT_W1" "$WT_VER"; do
  if [ "$(git -C "$seat_wt" rev-parse HEAD)" != "$MAIN_HEAD" ]; then
    echo "FAIL: idle seat worktree $seat_wt did not advance to main HEAD" >&2
    exit 1
  fi
done
if [ "$(git -C "$WT_W2" rev-parse HEAD)" != "$BASE_HEAD" ]; then
  echo "FAIL: busy seat worker_2 advanced despite busy_seats_csv" >&2
  exit 1
fi

echo "third" >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "advance main again"
MAIN_HEAD2="$(git -C "$REPO" rev-parse HEAD)"
printf '%s\n' "W2-T1" > "$WT_W2/.agent-army/.active_task"

worktree_sync_pool "$REPO" "main" ""
if [ "$(git -C "$WT_W2" rev-parse HEAD)" != "$BASE_HEAD" ]; then
  echo "FAIL: seat with .active_task advanced during sync" >&2
  exit 1
fi
if [ "$(git -C "$WT_W1" rev-parse HEAD)" != "$MAIN_HEAD2" ]; then
  echo "FAIL: worker_1 did not advance to second main HEAD" >&2
  exit 1
fi

rm -f "$WT_W2/.agent-army/.active_task"
worktree_sync_pool "$REPO" "main" ""
if [ "$(git -C "$WT_W2" rev-parse HEAD)" != "$MAIN_HEAD2" ]; then
  echo "FAIL: worker_2 did not advance after .active_task cleared" >&2
  exit 1
fi

echo "untracked" > "$WT_W1/loose-file.txt"
if worktree_sync_pool "$REPO" "main" "" >/dev/null 2>&1; then
  echo "FAIL: worktree_sync_pool must fail when an idle worktree is dirty" >&2
  exit 1
fi
rm -f "$WT_W1/loose-file.txt"

echo "dirty" >> "$WT_VER/README.md"
if worktree_sync_pool "$REPO" "main" "" >/dev/null 2>&1; then
  echo "FAIL: worktree_sync_pool must fail when an idle worktree is dirty" >&2
  exit 1
fi
git -C "$WT_VER" checkout -- README.md

echo "=== Test 3: worktree_snapshot captures diff, status, and untracked files ==="
echo "snapshot change" >> "$WT_W1/README.md"
echo "brand new" > "$WT_W1/untracked-note.txt"
SNAP="$(worktree_snapshot "$REPO" "worker_1")"
if [ ! -f "$SNAP/status.porcelain" ] || [ ! -f "$SNAP/diff.patch" ]; then
  echo "FAIL: snapshot missing status.porcelain or diff.patch at $SNAP" >&2
  exit 1
fi
if ! grep -q 'untracked-note.txt' "$SNAP/status.porcelain"; then
  echo "FAIL: snapshot status missing untracked file: $(cat "$SNAP/status.porcelain")" >&2
  exit 1
fi
if ! grep -q 'snapshot change' "$SNAP/diff.patch"; then
  echo "FAIL: snapshot diff missing the uncommitted change" >&2
  exit 1
fi
if [ ! -f "$SNAP/untracked/untracked-note.txt" ]; then
  echo "FAIL: snapshot did not copy the untracked file" >&2
  exit 1
fi
git -C "$WT_W1" checkout -- README.md
rm -f "$WT_W1/untracked-note.txt"

echo "=== Test 4: worktree_teardown snapshots dirty worktrees before removal ==="
echo "teardown change" >> "$WT_W2/README.md"
TDIR="$REPO/.agent-army/snapshots"
BEFORE_TEARDOWN_SNAPS="$(find "$TDIR" -type d -name 'worker_2' 2>/dev/null | wc -l | tr -d ' ')"
worktree_teardown "$REPO" "worker_2"
AFTER_TEARDOWN_SNAPS="$(find "$TDIR" -type d -name 'worker_2' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$AFTER_TEARDOWN_SNAPS" -le "$BEFORE_TEARDOWN_SNAPS" ]; then
  echo "FAIL: worktree_teardown did not snapshot the dirty worktree" >&2
  exit 1
fi
if [ -d "$WT_W2" ]; then
  echo "FAIL: worktree_teardown left the worktree directory behind" >&2
  exit 1
fi

echo "PASS: test_worktree_sync.sh (worktree section)"

# ---------------------------------------------------------------------------
# Task 3: seat lifecycle & file-path brief dispatch (mock herdr)
# ---------------------------------------------------------------------------

# shellcheck source=lib/config.sh disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/lifecycle.sh disable=SC1091
source "$ROOT_DIR/lib/lifecycle.sh"
# shellcheck source=lib/briefs.sh disable=SC1091
source "$ROOT_DIR/lib/briefs.sh"

echo "=== Test 4b: agent status is read from the live envelope and the flat mock ==="
NESTED="$(printf '%s' '{"id":"cli:agent:get","result":{"agent":{"agent_status":"idle","pane_id":"w28:p8"}}}' | herdr_agent_status_json)"
FLAT="$(printf '%s' '{"agent_status":"blocked","pane_id":"ws-mock:p1"}' | herdr_agent_status_json)"
NESTED_PANE="$(printf '%s' '{"id":"cli:agent:get","result":{"agent":{"agent_status":"idle","pane_id":"w28:p8"}}}' | herdr_agent_pane_json)"
FLAT_PANE="$(printf '%s' '{"agent_status":"blocked","pane_id":"ws-mock:p1"}' | herdr_agent_pane_json)"
if [ "$NESTED" != "idle" ] || [ "$FLAT" != "blocked" ] || [ "$NESTED_PANE" != "w28:p8" ] || [ "$FLAT_PANE" != "ws-mock:p1" ]; then
  echo "FAIL: agent payload parsed nested='$NESTED' flat='$FLAT' panes='$NESTED_PANE'/'$FLAT_PANE'" >&2
  exit 1
fi

echo "=== Test 4c: pane split JSON uses result.pane.pane_id, not the envelope id ==="
PARSED="$(_parse_pane_id '{"id":"cli:pane:split","result":{"pane":{"pane_id":"w28:p2"},"type":"pane_info"}}')"
if [ "$PARSED" != "w28:p2" ]; then
  echo "FAIL: parsed '$PARSED' from pane split JSON" >&2
  exit 1
fi

MOCK_BIN="$TMP_ROOT/mockbin"
mkdir -p "$MOCK_BIN"
ln -sf "$ROOT_DIR/tests/mocks/herdr" "$MOCK_BIN/herdr"
export PATH="$MOCK_BIN:$PATH"

MOCK_DIR="$TMP_ROOT/herdr-mock"
mkdir -p "$MOCK_DIR"
export HERDR_MOCK_DIR="$MOCK_DIR"

export ARMY_SUBMIT_DELAY=0

SEAT_REPO="$TMP_ROOT/seat-repo"
init_test_repo "$SEAT_REPO"
export HERDR_MOCK_REPO="$SEAT_REPO"
state_init_slug "$SEAT_REPO" "Seat Project" >/dev/null
SEAT_SLUG="$(state_read_slug "$SEAT_REPO")"
cp "$ROOT_DIR/army.config.toml.example" "$SEAT_REPO/army.config.toml"

echo "=== Test 5: swarm_up seats workers in exact order and never creates an ops pane ==="
GITHUB_TOKEN="gh-token-secret" GH_TOKEN="gh2" AWS_ACCESS_KEY_ID="AKIA123" AWS_SECRET_ACCESS_KEY="s" \
  swarm_up "$SEAT_REPO" "$SEAT_REPO/army.config.toml"

for seat in worker_1 worker_2 verifier; do
  if [ ! -d "$SEAT_REPO/.agent-army/worktrees/$seat" ]; then
    echo "FAIL: swarm_up did not provision a worktree for $seat" >&2
    exit 1
  fi
done
if [ ! -f "$SEAT_REPO/.agent-army/seats.json" ]; then
  echo "FAIL: swarm_up did not write seats.json" >&2
  exit 1
fi
SEAT_COUNT="$(jq '.seats | length' "$SEAT_REPO/.agent-army/seats.json")"
if [ "$SEAT_COUNT" != "3" ]; then
  echo "FAIL: expected 3 seats in seats.json, got $SEAT_COUNT" >&2
  exit 1
fi
WS_ID="$(jq -r '.workspace_id' "$SEAT_REPO/.agent-army/seats.json")"
if [ "$WS_ID" != "ws-mock" ]; then
  echo "FAIL: expected workspace_id 'ws-mock', got '$WS_ID'" >&2
  exit 1
fi

CALLS="$MOCK_DIR/calls.log"
FIRST_SPLIT_LINE="$(grep -n 'pane split' "$CALLS" | head -n 1 | cut -d: -f1)"
FIRST_START_LINE="$(grep -n 'agent start' "$CALLS" | head -n 1 | cut -d: -f1)"
if [ -z "$FIRST_SPLIT_LINE" ] || [ -z "$FIRST_START_LINE" ] || [ "$FIRST_SPLIT_LINE" -gt "$FIRST_START_LINE" ]; then
  echo "FAIL: seating order violated (pane split must precede agent start)" >&2
  exit 1
fi
while IFS= read -r split_line; do
  split_cwd="$(printf '%s' "$split_line" | sed -nE 's/pane split --cwd ([^ ]+) --direction (right|down) --no-focus.*/\1/p')"
  case "$split_cwd" in
    */.agent-army/worktrees/*) ;;
    *)
      echo "FAIL: pane split targeted non-worktree cwd '$split_cwd' (ops pane)" >&2
      exit 1
      ;;
  esac
done < <(grep 'pane split' "$CALLS")
if grep -q 'pane run .* exit' "$CALLS"; then
  echo "FAIL: fresh seat start closed the shell with exit" >&2
  exit 1
fi
if ! grep -q 'agent rename worker_1-.* --clear' "$CALLS"; then
  echo "FAIL: fresh start did not clear the previous agent name" >&2
  exit 1
fi

echo "=== Test 5b: a second swarm_up keeps each seat on its own worktree ==="
swarm_up "$SEAT_REPO" "$SEAT_REPO/army.config.toml"
W1_WT="$(jq -r '.seats.worker_1.worktree_dir' "$SEAT_REPO/.agent-army/seats.json")"
VER_WT="$(jq -r '.seats.verifier.worktree_dir' "$SEAT_REPO/.agent-army/seats.json")"
case "$W1_WT" in
  */worker_1) ;;
  *)
    echo "FAIL: worker_1 worktree is '$W1_WT'" >&2
    exit 1
    ;;
esac
case "$VER_WT" in
  */verifier) ;;
  *)
    echo "FAIL: verifier worktree is '$VER_WT'" >&2
    exit 1
    ;;
esac

echo "=== Test 6: worker/verifier launches are credential-free ==="
for seat in worker_1 worker_2 verifier; do
  ENV_FILE="$MOCK_DIR/env/${seat}-${SEAT_SLUG}.env"
  if [ ! -f "$ENV_FILE" ]; then
    echo "FAIL: no captured env for ${seat}-${SEAT_SLUG}" >&2
    exit 1
  fi
  if grep -qE '^(GITHUB_TOKEN|GH_TOKEN|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY)=' "$ENV_FILE"; then
    echo "FAIL: ${seat} agent env still carries credentials" >&2
    exit 1
  fi
  for required in AWS_SHARED_CREDENTIALS_FILE GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_CONFIG; do
    if ! grep -q "^${required}=/nonexistent$" "$ENV_FILE"; then
      echo "FAIL: ${seat} agent env missing ${required}=/nonexistent" >&2
      exit 1
    fi
  done
done

echo "=== Test 7: swarm_verify_seats fails closed when a critical seat is missing ==="
swarm_verify_seats "$SEAT_REPO" "$SEAT_REPO/army.config.toml"

jq '.seats |= del(.verifier)' "$SEAT_REPO/.agent-army/seats.json" > "$MOCK_DIR/seats.tmp"
mv "$MOCK_DIR/seats.tmp" "$SEAT_REPO/.agent-army/seats.json"
if swarm_verify_seats "$SEAT_REPO" "$SEAT_REPO/army.config.toml" >/dev/null 2>&1; then
  echo "FAIL: swarm_verify_seats must fail when the critical verifier seat is missing" >&2
  exit 1
fi
swarm_up "$SEAT_REPO" "$SEAT_REPO/army.config.toml"
swarm_verify_seats "$SEAT_REPO" "$SEAT_REPO/army.config.toml"

echo "=== Test 8: briefs_dispatch_task fresh session, anchor deletion, prompt_ts, short prompt ==="
WORKTREE_W1="$(jq -r '.seats.worker_1.worktree_dir' "$SEAT_REPO/.agent-army/seats.json")"
ANCHORS="$WORKTREE_W1/.agent-army/anchors"
mkdir -p "$ANCHORS" "$SEAT_REPO/.agent-army/briefs"
printf 'WORKER DONE #W1-T1 stalesha0000000000000000000000000000\n' > "$ANCHORS/W1-T1.txt"
touch -t 202001010000 "$ANCHORS/W1-T1.txt"
BEFORE_STARTS="$(grep -c 'agent start worker_1-' "$CALLS" || true)"

cat > "$SEAT_REPO/.agent-army/briefs/src-W1-T1.xml" <<'EOF'
<task_brief id="W1-T1" wave="1" seat="worker_1" verify="none">
  <role>Test engineer.</role>
  <objective>Do mock work.</objective>
  <scope><read>README.md</read><owns>src/feature.py</owns></scope>
  <gates><done_criteria>mock</done_criteria></gates>
</task_brief>
EOF

# silent mode: the mock worker writes nothing, so the stale-anchor deletion
# is observable directly (a live worker would recreate the anchor immediately).
mkdir -p "$MOCK_DIR/worker-mode"
printf 'silent\n' > "$MOCK_DIR/worker-mode/W1-T1"

BEFORE_TS="$(date +%s)"
sleep 1
briefs_dispatch_task "$SEAT_REPO" "worker_1" "1" "W1-T1" "$SEAT_REPO/.agent-army/briefs/src-W1-T1.xml"

if [ -e "$ANCHORS/W1-T1.txt" ]; then
  echo "FAIL: briefs_dispatch_task must delete the stale anchor file before prompting" >&2
  exit 1
fi
if [ ! -f "$ANCHORS/W1-T1.prompt_ts" ]; then
  echo "FAIL: briefs_dispatch_task did not write W1-T1.prompt_ts" >&2
  exit 1
fi
# Marker format is "<epoch-seconds[.fraction]> <nonce>": compare whole
# seconds only, and fail closed if the marker is not parseable as such.
PROMPT_TS="$(cat "$ANCHORS/W1-T1.prompt_ts")"
PROMPT_EPOCH="${PROMPT_TS%% *}"
PROMPT_EPOCH="${PROMPT_EPOCH%%.*}"
case "$PROMPT_EPOCH" in
  ''|*[!0-9]*)
    echo "FAIL: W1-T1.prompt_ts is not an epoch marker: '$PROMPT_TS'" >&2
    exit 1
    ;;
esac
if [ "$PROMPT_EPOCH" -lt "$BEFORE_TS" ]; then
  echo "FAIL: prompt_ts $PROMPT_TS predates dispatch ($BEFORE_TS)" >&2
  exit 1
fi
if [ ! -f "$WORKTREE_W1/.agent-army/briefs/1-W1-T1.xml" ]; then
  echo "FAIL: brief was not copied into the worktree" >&2
  exit 1
fi
if [ ! -e "$WORKTREE_W1/.agent-army/.active_task" ]; then
  echo "FAIL: briefs_dispatch_task did not mark the seat active" >&2
  exit 1
fi
AFTER_STARTS="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
if [ "$AFTER_STARTS" -ne $((BEFORE_STARTS + 1)) ]; then
  echo "FAIL: expected one fresh agent session ($BEFORE_STARTS -> $AFTER_STARTS)" >&2
  exit 1
fi

LAST_PROMPT="$(grep 'agent prompt worker_1-' "$CALLS" | tail -n 1)"
PROMPT_TEXT="${LAST_PROMPT#* :: }"
PROMPT_BYTES="$(printf '%s' "$PROMPT_TEXT" | wc -c | tr -d ' ')"
if [ "$PROMPT_BYTES" -ge 200 ]; then
  echo "FAIL: dispatched prompt is $PROMPT_BYTES bytes (>=200); raw XML must never be pasted" >&2
  exit 1
fi
case "$PROMPT_TEXT" in
  "Read .agent-army/briefs/1-W1-T1.xml,"*) ;;
  *)
    echo "FAIL: unexpected prompt text: $PROMPT_TEXT" >&2
    exit 1
    ;;
esac

echo "=== Test 9: providers_submit_prompt rejects prompts >= 200 bytes ==="
LONG_PROMPT="$(head -c 250 /dev/zero | tr '\0' 'x')"
if providers_submit_prompt "worker_1-$SEAT_SLUG" "$LONG_PROMPT" >/dev/null 2>&1; then
  echo "FAIL: providers_submit_prompt accepted a >=200 byte prompt" >&2
  exit 1
fi

echo "=== Test 10: briefs_dispatch_verifier uses the verify anchor namespace ==="
VER_WT="$(jq -r '.seats.verifier.worktree_dir' "$SEAT_REPO/.agent-army/seats.json")"
mkdir -p "$VER_WT/.agent-army/anchors" "$SEAT_REPO/.agent-army/briefs"
printf 'VERIFIER PASS #W1-T1 stalesha\n' > "$VER_WT/.agent-army/anchors/W1-T1.verify.txt"
touch -t 202001010000 "$VER_WT/.agent-army/anchors/W1-T1.verify.txt"
cat > "$SEAT_REPO/.agent-army/briefs/src-W1-T1-verify.xml" <<'EOF'
<verifier_brief id="W1-T1"><objective>audit</objective></verifier_brief>
EOF
printf 'silent\n' > "$MOCK_DIR/verifier-mode"
briefs_dispatch_verifier "$SEAT_REPO" "1" "W1-T1" "$SEAT_REPO/.agent-army/briefs/src-W1-T1-verify.xml"
printf 'active\n' > "$MOCK_DIR/verifier-mode"
if [ -e "$VER_WT/.agent-army/anchors/W1-T1.verify.txt" ]; then
  echo "FAIL: verifier dispatch must delete the stale verify anchor" >&2
  exit 1
fi
if [ ! -f "$VER_WT/.agent-army/anchors/W1-T1.verify.prompt_ts" ]; then
  echo "FAIL: verifier dispatch must write W1-T1.verify.prompt_ts" >&2
  exit 1
fi
if [ ! -f "$VER_WT/.agent-army/briefs/1-W1-T1-verify.xml" ]; then
  echo "FAIL: verifier brief was not copied into the verifier worktree" >&2
  exit 1
fi
LAST_VPROMPT="$(grep 'agent prompt verifier-' "$CALLS" | tail -n 1)"
case "${LAST_VPROMPT#* :: }" in
  "Read .agent-army/briefs/1-W1-T1-verify.xml,"*) ;;
  *)
    echo "FAIL: unexpected verifier prompt: $LAST_VPROMPT" >&2
    exit 1
    ;;
esac

echo "=== Test 10b: an anchor written during agent start stays readable ==="
# shellcheck source=lib/supervisor.sh disable=SC1091
source "$ROOT_DIR/lib/supervisor.sh"
# Silent prompt: the only anchor is the one written before agent start returns.
printf 'silent\n' > "$MOCK_DIR/verifier-mode"
FRESH_LINE="VERIFIER PASS #W1-T1 deadbeef"
printf '%s|%s\n' "$VER_WT/.agent-army/anchors/W1-T1.verify.txt" "$FRESH_LINE" > "$MOCK_DIR/anchor-on-start"
briefs_dispatch_verifier "$SEAT_REPO" "1" "W1-T1" "$SEAT_REPO/.agent-army/briefs/src-W1-T1-verify.xml"
rm -f "$MOCK_DIR/anchor-on-start"
FRESH_GOT="$(supervisor_read_anchor "$VER_WT" ".agent-army/anchors/W1-T1.verify.txt" "$VER_WT/.agent-army/anchors/W1-T1.verify.prompt_ts" "verifier-$SEAT_SLUG" || true)"
printf 'active\n' > "$MOCK_DIR/verifier-mode"
if [ "$FRESH_GOT" != "$FRESH_LINE" ]; then
  echo "FAIL: anchor written during agent start was not readable: '$FRESH_GOT'" >&2
  exit 1
fi

echo "=== Test 10c: a fresh verifier verdict survives another dispatch ==="
printf '%s\n' '1.0 nonce' > "$VER_WT/.agent-army/anchors/W1-T1.verify.prompt_ts"
printf '%s\n' 'VERIFIER PASS #W1-T1 deadbeef' > "$VER_WT/.agent-army/anchors/W1-T1.verify.txt"
touch "$VER_WT/.agent-army/anchors/W1-T1.verify.txt"
briefs_dispatch_verifier "$SEAT_REPO" "1" "W1-T1" "$SEAT_REPO/.agent-army/briefs/src-W1-T1-verify.xml"
KEPT="$(cat "$VER_WT/.agent-army/anchors/W1-T1.verify.txt" 2>/dev/null || true)"
if [ "$KEPT" != "VERIFIER PASS #W1-T1 deadbeef" ]; then
  echo "FAIL: a fresh verifier verdict was replaced: '$KEPT'" >&2
  exit 1
fi

echo "=== Test 11: swarm_down closes recorded panes and snapshots dirty worktrees ==="
echo "dirty worktree" >> "$WORKTREE_W1/README.md"
PANE_IDS="$(jq -r '.seats | to_entries[] | .value.pane_id' "$SEAT_REPO/.agent-army/seats.json")"
CLOSES_BEFORE="$(grep -c 'pane close' "$CALLS" || true)"
SNAP_DIR="$SEAT_REPO/.agent-army/snapshots"
mkdir -p "$SNAP_DIR"
W1_SNAPS_BEFORE="$(find "$SNAP_DIR" -type d -name worker_1 2>/dev/null | wc -l | tr -d ' ')"
swarm_down "$SEAT_REPO"
CLOSES_AFTER="$(grep -c 'pane close' "$CALLS" || true)"
if [ "$CLOSES_AFTER" -ne $((CLOSES_BEFORE + 3)) ]; then
  echo "FAIL: swarm_down closed $((CLOSES_AFTER - CLOSES_BEFORE)) panes, expected 3" >&2
  exit 1
fi
W1_SNAPS_AFTER="$(find "$SNAP_DIR" -type d -name worker_1 2>/dev/null | wc -l | tr -d ' ')"
if [ "$W1_SNAPS_AFTER" -le "$W1_SNAPS_BEFORE" ]; then
  echo "FAIL: swarm_down did not snapshot the dirty worker_1 worktree" >&2
  exit 1
fi
CLOSED_PANES="$(grep 'pane close' "$CALLS" | awk '{print $3}' | tail -n 3)"
for pane in $PANE_IDS; do
  if ! printf '%s\n' "$CLOSED_PANES" | grep -qF "$pane"; then
    echo "FAIL: swarm_down did not close recorded pane $pane" >&2
    exit 1
  fi
done
git -C "$WORKTREE_W1" checkout -- README.md

echo "PASS: test_worktree_sync.sh (seat lifecycle section)"

