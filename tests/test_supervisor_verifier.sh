#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=lib/pyenv.sh disable=SC1091
source "$ROOT_DIR/lib/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/profile.sh disable=SC1091
source "$ROOT_DIR/lib/profile.sh"
# shellcheck source=lib/worktree.sh disable=SC1091
source "$ROOT_DIR/lib/worktree.sh"
# shellcheck source=lib/partition.sh disable=SC1091
source "$ROOT_DIR/lib/partition.sh"
# shellcheck source=lib/briefs.sh disable=SC1091
source "$ROOT_DIR/lib/briefs.sh"
# shellcheck source=lib/supervisor.sh disable=SC1091
source "$ROOT_DIR/lib/supervisor.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/mockbin"
mkdir -p "$MOCK_BIN"
ln -sf "$ROOT_DIR/tests/mocks/herdr" "$MOCK_BIN/herdr"
export PATH="$MOCK_BIN:$PATH"

MOCK_DIR="$TMP_ROOT/herdr-mock"
mkdir -p "$MOCK_DIR"
export HERDR_MOCK_DIR="$MOCK_DIR"
export ARMY_SUBMIT_DELAY=0
export SUPERVISOR_POLL_SEC="${SUPERVISOR_POLL_SEC:-0.2}"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
printf 'test:\n\t@echo ok\n' > "$REPO/Makefile"
git -C "$REPO" add Makefile
git -C "$REPO" commit -q -m "initial"
export HERDR_MOCK_REPO="$REPO"

SLUG="$(state_init_slug "$REPO" "Gate Project")"
ensure_git_exclude "$REPO"
cp "$ROOT_DIR/army.config.toml.example" "$REPO/army.config.toml"
TEST_CMD="echo gate-ok" profile_ensure "$REPO"

# shellcheck source=lib/config.sh disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/lifecycle.sh disable=SC1091
source "$ROOT_DIR/lib/lifecycle.sh"
swarm_up "$REPO" "$REPO/army.config.toml"
W1_WT="$(jq -r '.seats.worker_1.worktree_dir' "$REPO/.agent-army/seats.json")"

BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" update-ref "refs/heads/$SLUG/integration" "$BASE"
INTEGRATION="refs/heads/$SLUG/integration"

CALLS="$MOCK_DIR/calls.log"

write_brief() {
  local path="$1" id="$2" owns="$3" verify="${4:-none}"
  cat > "$path" <<EOF
<task_brief id="$id" wave="1" seat="worker_1" verify="$verify">
  <role>Worker.</role>
  <objective>Do the mock work.</objective>
  <scope><read>README.md</read><owns>$owns</owns></scope>
  <gates><done_criteria>mock criteria</done_criteria></gates>
</task_brief>
EOF
}

commit_on_worker_branch() {
  local file="$1" content="$2"
  mkdir -p "$W1_WT/$(dirname "$file")"
  printf '%s\n' "$content" > "$W1_WT/$file"
  git -C "$W1_WT" add -- "$file"
  git -C "$W1_WT" commit -q -m "worker change: $file"
  git -C "$W1_WT" rev-parse HEAD
}

echo "=== Test 1: stale anchor (mtime < prompt_ts) ignored; fresh anchor read [Review Focus #4] ==="
mkdir -p "$W1_WT/.agent-army/anchors"
STALE_LINE='WORKER DONE #W1-T1 1111111111111111111111111111111111111111'
printf '%s\n' "$STALE_LINE" > "$W1_WT/.agent-army/anchors/T1.txt"
STALE_TS="$(( $(date +%s) + 5 ))"
printf '%s\n' "$STALE_TS" > "$W1_WT/.agent-army/anchors/T1.prompt_ts"
if LINE="$(supervisor_read_anchor "$W1_WT" ".agent-army/anchors/T1.txt" "$W1_WT/.agent-army/anchors/T1.prompt_ts" "worker_1-$SLUG")"; then
  echo "FAIL: stale anchor (mtime < prompt_ts) was harvested: $LINE" >&2
  exit 1
fi

sleep 1
FRESH_LINE='WORKER DONE #T1 2222222222222222222222222222222222222222'
printf '%s\n' "$FRESH_LINE" > "$W1_WT/.agent-army/anchors/T1.txt"
FRESH_TS="$(( $(date +%s) - 5 ))"
printf '%s\n' "$FRESH_TS" > "$W1_WT/.agent-army/anchors/T1.prompt_ts"
LINE="$(supervisor_read_anchor "$W1_WT" ".agent-army/anchors/T1.txt" "$W1_WT/.agent-army/anchors/T1.prompt_ts" "worker_1-$SLUG")"
if [ "$LINE" != "$FRESH_LINE" ]; then
  echo "FAIL: fresh anchor not read back verbatim: '$LINE'" >&2
  exit 1
fi
rm -f "$W1_WT/.agent-army/anchors/T1.txt" "$W1_WT/.agent-army/anchors/T1.prompt_ts"

echo "=== Test 1b: missing anchor falls back to one herdr agent read ==="
mkdir -p "$MOCK_DIR/read"
printf 'noise line\nWORKER DONE #T9 3333333333333333333333333333333333333333\nnoise\n' \
  > "$MOCK_DIR/read/worker_1-$SLUG"
LINE="$(supervisor_read_anchor "$W1_WT" ".agent-army/anchors/T9.txt" "$W1_WT/.agent-army/anchors/T9.prompt_ts" "worker_1-$SLUG")"
case "$LINE" in
  'WORKER DONE #T9 3333333333333333333333333333333333333333') ;;
  *)
    echo "FAIL: herdr read fallback returned '$LINE'" >&2
    exit 1
    ;;
esac
rm -rf "$MOCK_DIR/read"

echo "=== Test 2: flake rerun — fail on attempt 1, pass on attempt 2 => GREEN, no repair ==="
FLAKE_COUNTER="$TMP_ROOT/flake-counter"
FLAKE_CMD="n=\$(cat '$FLAKE_COUNTER' 2>/dev/null || printf '0'); n=\$((n+1)); printf '%s' \"\$n\" > '$FLAKE_COUNTER'; test \"\$n\" -ge 2"
TEST_CMD="$FLAKE_CMD" profile_ensure "$REPO" >/dev/null

BRIEF="$REPO/.agent-army/briefs/src-W1-T1.xml"
mkdir -p "$REPO/.agent-army/briefs"
write_brief "$BRIEF" "W1-T1" "src/feature.py"
partition_acquire_wave "$REPO" '[{"id":"W1-T1","seat":"worker_1","owns":["src/feature.py"]}]'
STARTS_BEFORE_T2="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
briefs_dispatch_task "$REPO" "worker_1" "1" "W1-T1" "$BRIEF"
GATE_OUT="$(supervisor_gate_commit "$REPO" "1" "W1-T1" "worker_1" "$(git -C "$W1_WT" rev-parse HEAD)" "$BASE" "src/feature.py" "none" || true)"
case "$GATE_OUT" in
  GREEN:*) ;;
  *)
    echo "FAIL: flake rerun expected GREEN:<sha>, got '$GATE_OUT'" >&2
    exit 1
    ;;
esac
STARTS_W1="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
if [ "$STARTS_W1" -ne $((STARTS_BEFORE_T2 + 1)) ]; then
  echo "FAIL: flake rerun must not start a repair session (starts went $STARTS_BEFORE_T2 -> $STARTS_W1; expected exactly +1 for the dispatch)" >&2
  exit 1
fi
partition_release_task "$REPO" "W1-T1"

echo "=== Test 3: mandatory verifier when a test file changes even with verify=none ==="
TEST_CMD="echo gate-ok" profile_ensure "$REPO" >/dev/null
TEST_SHA="$(commit_on_worker_branch "tests/test_app.py" "def test_app(): pass")"
BASE_T3="$(git -C "$W1_WT" rev-parse "$TEST_SHA^")"
if ! supervisor_needs_verifier "$REPO" "$BASE_T3" "$TEST_SHA" "none"; then
  echo "FAIL: supervisor_needs_verifier must fire when tests/test_app.py changes" >&2
  exit 1
fi
partition_acquire_wave "$REPO" '[{"id":"W1-T2","seat":"worker_1","owns":["tests/test_app.py"]}]'
GATE_OUT="$(supervisor_gate_commit "$REPO" "1" "W1-T2" "worker_1" "$TEST_SHA" "$BASE_T3" "tests/test_app.py" "none" || true)"
case "$GATE_OUT" in
  GREEN:*) ;;
  *)
    echo "FAIL: expected GREEN after verifier PASS, got '$GATE_OUT'" >&2
    exit 1
    ;;
esac
if ! grep -q 'agent prompt verifier-' "$CALLS"; then
  echo "FAIL: verifier seat was never prompted for the test-file change" >&2
  exit 1
fi
partition_release_task "$REPO" "W1-T2"

echo "=== Test 4: VERIFIER FAIL -> one repair turn; second failure ends RED and releases the lease ==="
printf 'VERIFIER FAIL #%%TASK%% deadbeefdeadbeef the diff violates the spec\n' > "$MOCK_DIR/verifier-verdict"
git -C "$REPO" update-ref "$INTEGRATION" "$(git -C "$W1_WT" rev-parse HEAD)"
BASE2="$(git -C "$REPO" rev-parse "$INTEGRATION")"

BRIEF4="$REPO/.agent-army/briefs/src-W2-T1.xml"
write_brief "$BRIEF4" "W2-T1" "src/service.py" "asymmetric"
partition_acquire_wave "$REPO" '[{"id":"W2-T1","seat":"worker_1","owns":["src/service.py"]}]'
STARTS_BEFORE="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
briefs_dispatch_task "$REPO" "worker_1" "2" "W2-T1" "$BRIEF4"

MANIFEST="$REPO/.agent-army/waves/2.json"
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
{"wave": 2, "tasks": [
  {"id": "W2-T1", "seat": "worker_1", "owns": ["src/service.py"], "verify": "asymmetric", "brief": "$BRIEF4", "base_ref": "$BASE2"}
]}
EOF
RECEIPT="$(supervisor_supervise_wave "$REPO" "$MANIFEST")"
RECEIPT_STATUS="$(printf '%s' "$RECEIPT" | jq -r '.tasks["W2-T1"].status')"
if [ "$RECEIPT_STATUS" != "RED" ]; then
  echo "FAIL: expected RED after two verifier failures, got $RECEIPT_STATUS: $RECEIPT" >&2
  exit 1
fi
STARTS_AFTER="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
if [ "$STARTS_AFTER" -ne $((STARTS_BEFORE + 2)) ]; then
  echo "FAIL: expected exactly 1 repair session (initial + 1 repair = +2 total, got $((STARTS_AFTER - STARTS_BEFORE)))" >&2
  exit 1
fi
if jq -e 'has("W2-T1")' "$REPO/.agent-army/leases.json" >/dev/null 2>&1; then
  echo "FAIL: RED task must release its partition lease" >&2
  exit 1
fi
REASON="$(printf '%s' "$RECEIPT" | jq -r '.tasks["W2-T1"].reason')"
case "$REASON" in
  verifier_failed:*) ;;
  *)
    echo "FAIL: expected RED:verifier_failed:<reason>, got '$REASON'" >&2
    exit 1
    ;;
esac

echo "=== Test 5: task timeout — first expiry re-dispatches once, second blocks ==="
export ARMY_TASK_TIMEOUT_SEC=1
mkdir -p "$MOCK_DIR/worker-mode"
printf 'silent\n' > "$MOCK_DIR/worker-mode/W2-T2"
git -C "$REPO" update-ref "$INTEGRATION" "$(git -C "$W1_WT" rev-parse HEAD)"
BASE3="$(git -C "$REPO" rev-parse "$INTEGRATION")"
BRIEF5="$REPO/.agent-army/briefs/src-W2-T2.xml"
write_brief "$BRIEF5" "W2-T2" "src/slow.py"
partition_acquire_wave "$REPO" '[{"id":"W2-T2","seat":"worker_1","owns":["src/slow.py"]}]'
STARTS_T5="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
briefs_dispatch_task "$REPO" "worker_1" "2" "W2-T2" "$BRIEF5"

MANIFEST5="$REPO/.agent-army/waves/2b.json"
cat > "$MANIFEST5" <<EOF
{"wave": 2, "tasks": [
  {"id": "W2-T2", "seat": "worker_1", "owns": ["src/slow.py"], "verify": "none", "brief": "$BRIEF5", "base_ref": "$BASE3"}
]}
EOF
RECEIPT5="$(supervisor_supervise_wave "$REPO" "$MANIFEST5")"
STATUS5="$(printf '%s' "$RECEIPT5" | jq -r '.tasks["W2-T2"].status')"
BOUNDARY5="$(printf '%s' "$RECEIPT5" | jq -r '.tasks["W2-T2"].boundary')"
SNAPSHOT5="$(printf '%s' "$RECEIPT5" | jq -r '.tasks["W2-T2"].snapshot')"
if [ "$STATUS5" != "BLOCKED" ] || [ "$BOUNDARY5" != "TIMEOUT" ]; then
  echo "FAIL: expected BLOCKED/TIMEOUT, got $STATUS5/$BOUNDARY5: $RECEIPT5" >&2
  exit 1
fi
if [ ! -d "$SNAPSHOT5" ]; then
  echo "FAIL: BLOCKED:TIMEOUT must carry a snapshot path, got '$SNAPSHOT5'" >&2
  exit 1
fi
STARTS_T5_AFTER="$(grep -c 'agent start worker_1-' "$CALLS" || true)"
if [ "$STARTS_T5_AFTER" -ne $((STARTS_T5 + 2)) ]; then
  echo "FAIL: timeout re-dispatch must happen exactly once (+2 starts, got $((STARTS_T5_AFTER - STARTS_T5)))" >&2
  exit 1
fi
if jq -e 'has("W2-T2")' "$REPO/.agent-army/leases.json" >/dev/null 2>&1; then
  echo "FAIL: BLOCKED task must release its partition lease" >&2
  exit 1
fi
unset ARMY_TASK_TIMEOUT_SEC

echo "PASS: test_supervisor_verifier.sh"
