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
# shellcheck source=lib/arbiter.sh disable=SC1091
source "$ROOT_DIR/lib/arbiter.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/mockbin"
mkdir -p "$MOCK_BIN"
ln -sf "$ROOT_DIR/tests/mocks/herdr" "$MOCK_BIN/herdr"
export PATH="$MOCK_BIN:$PATH"

MOCK_DIR="$TMP_ROOT/herdr-mock"
mkdir -p "$MOCK_DIR"
export HERDR_MOCK_DIR="$MOCK_DIR"
export HERDR_MOCK_REPO="$TMP_ROOT"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
printf 'test:\n\t@echo ok\n' > "$REPO/Makefile"
cp "$ROOT_DIR/army.config.toml.example" "$REPO/army.config.toml"
git -C "$REPO" add Makefile army.config.toml
git -C "$REPO" commit -q -m "initial"

SLUG="$(state_init_slug "$REPO" "Arbiter Project")"
ensure_git_exclude "$REPO"
# shellcheck disable=SC2016
TEST_CMD='test "$CI" = "true" && test -z "${HERDR_PANE_ID:-}" && echo gate-ok' profile_ensure "$REPO"

MAIN0="$(git -C "$REPO" rev-parse HEAD)"

# Branches: T1 edits a.py; T2 edits a.py differently (conflicts with T1);
# T3 edits b.py; RES resolves a.py on top of T1.
mk_branch() {
  local branch="$1" base="$2" file="$3" content="$4"
  git -C "$REPO" checkout -q --detach "$base"
  printf '%s\n' "$content" > "$REPO/$file"
  git -C "$REPO" add -- "$file"
  git -C "$REPO" commit -q -m "$branch: $file"
  git -C "$REPO" branch -f "$branch" HEAD >/dev/null 2>&1 || git -C "$REPO" update-ref "refs/heads/$branch" HEAD
  git -C "$REPO" checkout -q main
}

mk_branch t1 "$MAIN0" "a.py" "a-one"
mk_branch t2 "$MAIN0" "a.py" "a-two"
mk_branch t3 "$MAIN0" "b.py" "b-three"
T1_SHA="$(git -C "$REPO" rev-parse refs/heads/t1)"
T2_SHA="$(git -C "$REPO" rev-parse refs/heads/t2)"
T3_SHA="$(git -C "$REPO" rev-parse refs/heads/t3)"

git -C "$REPO" checkout -q --detach "$T1_SHA"
printf 'a-resolved\n' > "$REPO/a.py"
git -C "$REPO" add a.py
git -C "$REPO" commit -q -m "resolve a.py"
RES_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main

echo "=== Test 1: stopped (T*) lock holder is reaped ==="
arbiter_init_ref "$REPO" "$MAIN0"

sleep 60 &
STOP_PID=$!
mkdir -p "$REPO/.agent-army/arbiter.lock"
printf '%s\n' "$STOP_PID" > "$REPO/.agent-army/arbiter.lock/pid"
kill -STOP "$STOP_PID"
trap 'kill -9 '"$STOP_PID"' 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT
STATE_CHECK="$(ps -o state= -p "$STOP_PID" | awk '{print substr($1,1,1)}')"
if [ "$STATE_CHECK" != "T" ]; then
  echo "FAIL: expected stopped process state T, got '$STATE_CHECK'" >&2
  kill -9 "$STOP_PID" 2>/dev/null || true
  exit 1
fi
if ! arbiter_lock "$REPO/.agent-army"; then
  echo "FAIL: arbiter_lock must reap a stopped (T*) holder and acquire" >&2
  kill -9 "$STOP_PID" 2>/dev/null || true
  exit 1
fi
kill -9 "$STOP_PID" 2>/dev/null || true
arbiter_unlock "$REPO/.agent-army"
if [ -d "$REPO/.agent-army/arbiter.lock" ]; then
  echo "FAIL: arbiter_unlock left the lock behind" >&2
  exit 1
fi
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "=== Test 2: dead lock holder is reaped ==="
mkdir -p "$REPO/.agent-army/arbiter.lock"
printf '999999999\n' > "$REPO/.agent-army/arbiter.lock/pid"
if ! arbiter_lock "$REPO/.agent-army"; then
  echo "FAIL: arbiter_lock must reap a dead holder pid" >&2
  exit 1
fi
arbiter_unlock "$REPO/.agent-army"

echo "=== Test 3: arbiter_init_ref refuses an existing ref ==="
if arbiter_init_ref "$REPO" "$MAIN0" >/dev/null 2>&1; then
  echo "FAIL: arbiter_init_ref must refuse when the ref already exists" >&2
  exit 1
fi

echo "=== Test 4: drain integrates T1, stops at conflicting T2, preserves T2+T3 queue ==="
# Idle seat worktrees so promote's pool sync has something to advance.
# shellcheck source=lib/config.sh disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/lifecycle.sh disable=SC1091
source "$ROOT_DIR/lib/lifecycle.sh"
export ARMY_SUBMIT_DELAY=0
swarm_up "$REPO" "$REPO/army.config.toml"
W1_WT="$(jq -r '.seats.worker_1.worktree_dir' "$REPO/.agent-army/seats.json")"
VER_WT="$(jq -r '.seats.verifier.worktree_dir' "$REPO/.agent-army/seats.json")"

arbiter_enqueue "$REPO" "T1" "worker_1" "$T1_SHA"
arbiter_enqueue "$REPO" "T2" "worker_2" "$T2_SHA"
arbiter_enqueue "$REPO" "T3" "worker_1" "$T3_SHA"

DRAIN_RC=0
arbiter_drain "$REPO" >/dev/null 2>&1 || DRAIN_RC=$?
if [ "$DRAIN_RC" -ne 2 ]; then
  echo "FAIL: conflicting drain must return 2, got $DRAIN_RC" >&2
  exit 1
fi

INTEG_TIP="$(git -C "$REPO" rev-parse "refs/heads/army/$SLUG/integration")"
if [ "$INTEG_TIP" != "$T1_SHA" ]; then
  echo "FAIL: integration must stop at T1 after conflict, got $INTEG_TIP" >&2
  exit 1
fi
T2_STATUS="$(jq -r 'select(.ticket == "T2") | .status' "$REPO/.agent-army/integration.jsonl" | tail -n 1)"
T3_STATUS="$(jq -r 'select(.ticket == "T3") | .status' "$REPO/.agent-army/integration.jsonl" | tail -n 1)"
if [ "$T2_STATUS" != "queued" ] || [ "$T3_STATUS" != "queued" ]; then
  echo "FAIL: T2/T3 must remain queued after conflict, got $T2_STATUS/$T3_STATUS" >&2
  exit 1
fi
FAILURE_STATUS="$(jq -r '.status' "$REPO/.agent-army/drain-failure.json")"
FAILURE_OWNS="$(jq -r '.owns | join(",")' "$REPO/.agent-army/drain-failure.json")"
if [ "$FAILURE_STATUS" != "conflict" ] || [ "$FAILURE_OWNS" != "a.py" ]; then
  echo "FAIL: drain-failure.json expected conflict on a.py, got $FAILURE_STATUS/$FAILURE_OWNS" >&2
  exit 1
fi

echo "=== Test 5: resolution with priority=front supersedes T2 and drains T3 in one pass ==="
arbiter_enqueue "$REPO" "T2-RESOLVE" "worker_2" "$RES_SHA" "front" "T2"
DRAIN2_RC=0
arbiter_drain "$REPO" >/dev/null 2>&1 || DRAIN2_RC=$?
if [ "$DRAIN2_RC" -ne 0 ]; then
  echo "FAIL: resolution drain must return 0, got $DRAIN2_RC" >&2
  exit 1
fi
RES_STATUS="$(jq -r 'select(.ticket == "T2-RESOLVE") | .status' "$REPO/.agent-army/integration.jsonl" | tail -n 1)"
T2_STATUS2="$(jq -r 'select(.ticket == "T2") | .status' "$REPO/.agent-army/integration.jsonl" | tail -n 1)"
T3_STATUS2="$(jq -r 'select(.ticket == "T3") | .status' "$REPO/.agent-army/integration.jsonl" | tail -n 1)"
if [ "$RES_STATUS" != "integrated" ] || [ "$T2_STATUS2" != "superseded" ] || [ "$T3_STATUS2" != "integrated" ]; then
  echo "FAIL: expected integrated/superseded/integrated, got $RES_STATUS/$T2_STATUS2/$T3_STATUS2" >&2
  exit 1
fi
if [ -f "$REPO/.agent-army/drain-failure.json" ]; then
  echo "FAIL: successful drain must remove drain-failure.json" >&2
  exit 1
fi

echo "=== Test 6: promote --confirm fast-forwards main, releases leases, syncs pool; pane check ==="
partition_acquire_wave "$REPO" '[{"id":"T1","seat":"worker_1","owns":["a.py"]},{"id":"T3","seat":"worker_1","owns":["b.py"]}]'
jq -e 'has("T1") and has("T3")' "$REPO/.agent-army/leases.json" >/dev/null

PROMOTED_COUNT="$(arbiter_promote "$REPO" --confirm)"
if [ "$PROMOTED_COUNT" != "3" ]; then
  echo "FAIL: expected 3 promoted records (T1, T2-RESOLVE, T3), got $PROMOTED_COUNT" >&2
  exit 1
fi
MAIN_HEAD="$(git -C "$REPO" rev-parse main)"
INTEG_HEAD="$(git -C "$REPO" rev-parse "refs/heads/army/$SLUG/integration")"
if [ "$MAIN_HEAD" != "$INTEG_HEAD" ]; then
  echo "FAIL: promote must fast-forward main to the integration tip" >&2
  exit 1
fi
if [ "$(git -C "$W1_WT" rev-parse HEAD)" != "$MAIN_HEAD" ] || [ "$(git -C "$VER_WT" rev-parse HEAD)" != "$MAIN_HEAD" ]; then
  echo "FAIL: promote must sync idle worker/verifier worktrees to the new main" >&2
  exit 1
fi
if jq -e 'has("T1")' "$REPO/.agent-army/leases.json" >/dev/null 2>&1; then
  echo "FAIL: promote must release promoted tickets' leases" >&2
  exit 1
fi
ALL_PROMOTED="$(jq -r 'select(.status != "promoted") | .ticket' "$REPO/.agent-army/integration.jsonl" | wc -l | tr -d ' ')"
if [ "$ALL_PROMOTED" != "1" ]; then
  echo "FAIL: only the superseded T2 record may stay unpromoted, got $ALL_PROMOTED" >&2
  exit 1
fi

echo "=== Test 7: _arb_promote_pane_check refuses a live Herdr agent pane ==="
W1_PANE="$(jq -r '.seats.worker_1.pane_id' "$REPO/.agent-army/seats.json")"
if HERDR_PANE_ID="$W1_PANE" _arb_promote_pane_check >/dev/null 2>&1; then
  echo "FAIL: promote must refuse when HERDR_PANE_ID is a live Herdr agent pane" >&2
  exit 1
fi
if ! HERDR_PANE_ID="ws-mock:no-such-pane" _arb_promote_pane_check >/dev/null 2>&1; then
  echo "FAIL: promote must allow an HERDR_PANE_ID with no live agent on it" >&2
  exit 1
fi
if ! (unset HERDR_PANE_ID && _arb_promote_pane_check) >/dev/null 2>&1; then
  echo "FAIL: promote must allow the outer commander process (HERDR_PANE_ID unset)" >&2
  exit 1
fi

echo "=== Test 8: promote refuses a dirty root or wrong branch ==="
printf 'dirty\n' >> "$REPO/Makefile"
if arbiter_promote "$REPO" --confirm >/dev/null 2>&1; then
  echo "FAIL: promote must refuse a dirty root checkout" >&2
  exit 1
fi
git -C "$REPO" checkout -- Makefile
git -C "$REPO" checkout -q -b side-branch
if arbiter_promote "$REPO" --confirm >/dev/null 2>&1; then
  echo "FAIL: promote must refuse when the root is not on base_branch" >&2
  exit 1
fi
git -C "$REPO" checkout -q main
git -C "$REPO" branch -q -D side-branch

echo "PASS: test_arbiter_promote.sh"
