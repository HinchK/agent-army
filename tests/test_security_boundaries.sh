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

SLUG="$(state_init_slug "$REPO" "Secure Project")"
ensure_git_exclude "$REPO"
cp "$ROOT_DIR/army.config.toml.example" "$REPO/army.config.toml"
TEST_CMD="echo gate-ok" profile_ensure "$REPO"

# shellcheck source=lib/config.sh disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/lifecycle.sh disable=SC1091
source "$ROOT_DIR/lib/lifecycle.sh"
swarm_up "$REPO" "$REPO/army.config.toml"

BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" update-ref "refs/heads/army/$SLUG/integration" "$BASE"
INTEGRATION="refs/heads/army/$SLUG/integration"


echo "=== Test 1: secret added in an intermediate commit and deleted in the tip still blocks ==="
git -C "$REPO" checkout -q --detach
printf 'AWS_SECRET=AKIAIOSFODNN7EXAMPLE\n' > "$REPO/.env"
git -C "$REPO" add -f .env
git -C "$REPO" commit -q -m "sneak secret in"
git -C "$REPO" rm -q -f .env
git -C "$REPO" commit -q -m "remove secret again"
TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main

SCAN_RC=0
supervisor_scan_secrets "$REPO" "$INTEGRATION" "$TIP_SHA" >/dev/null 2>&1 || SCAN_RC=$?
if [ "$SCAN_RC" -ne 20 ]; then
  echo "FAIL: deleted-in-tip secret must return 20, got $SCAN_RC" >&2
  exit 1
fi

echo "=== Test 2: binary blobs do not crash the scanner under set -euo pipefail [Review Focus #3] ==="
git -C "$REPO" update-ref "$INTEGRATION" "$TIP_SHA"
git -C "$REPO" checkout -q --detach "$TIP_SHA"
printf 'binary\x00\x01\x02AKIAIOSFODNN7EXAMPLE\x00marker' > "$REPO/asset.bin"
git -C "$REPO" add asset.bin
git -C "$REPO" commit -q -m "add binary blob"
BIN_SHA="$(git -C "$REPO" rev-parse HEAD)"

SCAN_RC=0
ERR_OUT="$(supervisor_scan_secrets "$REPO" "$INTEGRATION" "$BIN_SHA" 2>&1 >/dev/null)" || SCAN_RC=$?
if [ "$SCAN_RC" -ne 20 ]; then
  echo "FAIL: secret-bearing binary blob must return 20, got $SCAN_RC (stderr: $ERR_OUT)" >&2
  exit 1
fi

printf 'binary\x00\x01\x02clean-blob-no-secrets-here\x00' > "$REPO/clean.bin"
git -C "$REPO" add clean.bin
git -C "$REPO" commit -q -m "add clean binary blob"
CLEAN_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" update-ref "$INTEGRATION" "$BIN_SHA"
git -C "$REPO" checkout -q main

if ! supervisor_scan_secrets "$REPO" "$INTEGRATION" "$CLEAN_SHA" >/dev/null 2>&1; then
  echo "FAIL: clean binary blob must not trip the scanner (grep exit 1 must not abort)" >&2
  exit 1
fi

echo "=== Test 2b: key files and .pem paths block; .env.example does not ==="
git -C "$REPO" update-ref "$INTEGRATION" "$CLEAN_SHA"
git -C "$REPO" checkout -q --detach "$CLEAN_SHA"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n' > "$REPO/id_rsa"
git -C "$REPO" add id_rsa
printf 'export A=1\n' > "$REPO/.env.example"
git -C "$REPO" add .env.example
git -C "$REPO" commit -q -m "key + env example"
KEY_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
SCAN_RC=0
supervisor_scan_secrets "$REPO" "$INTEGRATION" "$KEY_SHA" >/dev/null 2>&1 || SCAN_RC=$?
if [ "$SCAN_RC" -ne 20 ]; then
  echo "FAIL: private key blob must return 20, got $SCAN_RC" >&2
  exit 1
fi

git -C "$REPO" checkout -q --detach "$CLEAN_SHA"
printf 'A=1\n' > "$REPO/.env.example"
git -C "$REPO" add .env.example
git -C "$REPO" commit -q -m "env example only"
ENVEX_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
if ! supervisor_scan_secrets "$REPO" "$INTEGRATION" "$ENVEX_SHA" >/dev/null 2>&1; then
  echo "FAIL: .env.example alone must not block" >&2
  exit 1
fi

echo "=== Test 2c: secret in the first line of a >64KB blob is caught (grep -q SIGPIPE regression) ==="
# grep -q exits at the first match; on a blob larger than the pipe buffer the
# early exit SIGPIPEs cat-file under pipefail and the old code failed OPEN.
git -C "$REPO" checkout -q --detach "$CLEAN_SHA"
{ printf 'ghp_AAAAABBBBBCCCCCDDDDDEEEEEFFFFFGGGGG\n'; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$REPO/big.bundle"
git -C "$REPO" add big.bundle
git -C "$REPO" commit -q -m "big bundle with early secret"
BIG_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
SCAN_RC=0
supervisor_scan_secrets "$REPO" "$INTEGRATION" "$BIG_SHA" >/dev/null 2>&1 || SCAN_RC=$?
if [ "$SCAN_RC" -ne 20 ]; then
  echo "FAIL: secret at the head of a >64KB blob must return 20, got $SCAN_RC" >&2
  exit 1
fi
# Same oversized blob without the secret must stay clean (full-stream grep).
git -C "$REPO" checkout -q --detach "$CLEAN_SHA"
head -c 200000 /dev/zero | tr '\0' 'x' > "$REPO/big-clean.bundle"
git -C "$REPO" add big-clean.bundle
git -C "$REPO" commit -q -m "big clean bundle"
BIGCLEAN_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
if ! supervisor_scan_secrets "$REPO" "$INTEGRATION" "$BIGCLEAN_SHA" >/dev/null 2>&1; then
  echo "FAIL: clean >64KB blob must not block" >&2
  exit 1
fi

echo "=== Test 2d: dispatch refuses a task id that could escape anchor paths ==="
# Guards fire before any file side effects, so /dev/null is a safe brief src.
if briefs_dispatch_task "$REPO" "worker_1" "9" '../../escape' /dev/null 2>/dev/null; then
  echo "FAIL: briefs_dispatch_task must reject a traversal task id" >&2
  exit 1
fi
if briefs_dispatch_verifier "$REPO" "9" 'a/b' /dev/null 2>/dev/null; then
  echo "FAIL: briefs_dispatch_verifier must reject a path-bearing task id" >&2
  exit 1
fi
if compgen -G "$REPO/.agent-army/worktrees/worker_1/.agent-army/anchors/*escape*" >/dev/null \
  || [ -e "$REPO/escape.txt" ]; then
  echo "FAIL: rejected task id must not create files" >&2
  exit 1
fi

echo "=== Test 2e: missing integration ref fails closed (no vacuous clean scan) ==="
# rev-list on a missing ref errors into the void; the old loop body never ran
# and the scan returned 0 (clean) for a secret-bearing commit. The scan must
# fail non-zero instead, and must still block once the ref is restored.
git -C "$REPO" checkout -q --detach "$CLEAN_SHA"
printf 'ghp_EEEEEFFFFFGGGGGHHHHHIIIIIZZZZZ1234567890\n' > "$REPO/leak-noref.txt"
git -C "$REPO" add leak-noref.txt
git -C "$REPO" commit -q -m "leak without integration ref"
NOREF_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
git -C "$REPO" update-ref -d "$INTEGRATION"
SCAN_NOREF_RC=0
supervisor_scan_secrets "$REPO" "$INTEGRATION" "$NOREF_SHA" >/dev/null 2>&1 || SCAN_NOREF_RC=$?
if [ "$SCAN_NOREF_RC" -eq 0 ]; then
  echo "FAIL: scan must fail closed when the integration ref is missing" >&2
  exit 1
fi
git -C "$REPO" update-ref "$INTEGRATION" "$BASE"
SCAN_RESTORED_RC=0
supervisor_scan_secrets "$REPO" "$INTEGRATION" "$NOREF_SHA" >/dev/null 2>&1 || SCAN_RESTORED_RC=$?
if [ "$SCAN_RESTORED_RC" -ne 20 ]; then
  echo "FAIL: restored ref must make the same commit block (20), got $SCAN_RESTORED_RC" >&2
  exit 1
fi

echo "=== Test 3: WORKER BLOCKED ... AUTH and agent_status=blocked halt as BLOCKED:AUTH ==="
git -C "$REPO" update-ref "$INTEGRATION" "$(git -C "$REPO" rev-parse "army/$SLUG/worker_1")"
BLOCK_BASE="$(git -C "$REPO" rev-parse "$INTEGRATION")"
mkdir -p "$MOCK_DIR/worker-mode" "$REPO/.agent-army/briefs"
printf 'blocked-auth\n' > "$MOCK_DIR/worker-mode/S1-T1"
cat > "$REPO/.agent-army/briefs/s-S1-T1.xml" <<'EOF'
<task_brief id="S1-T1" wave="1" seat="worker_1" verify="none">
  <role>Worker.</role>
  <objective>Touch an auth boundary.</objective>
  <scope><read>README.md</read><owns>src/auth.py</owns></scope>
</task_brief>
EOF
partition_acquire_wave "$REPO" '[{"id":"S1-T1","seat":"worker_1","owns":["src/auth.py"]}]'
briefs_dispatch_task "$REPO" "worker_1" "1" "S1-T1" "$REPO/.agent-army/briefs/s-S1-T1.xml"
MANIFEST="$REPO/.agent-army/waves/1.json"
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
{"wave": 1, "tasks": [
  {"id": "S1-T1", "seat": "worker_1", "owns": ["src/auth.py"], "verify": "none", "brief": "$REPO/.agent-army/briefs/s-S1-T1.xml", "base_ref": "$BLOCK_BASE"}
]}
EOF
RECEIPT="$(supervisor_supervise_wave "$REPO" "$MANIFEST")"
STATUS="$(printf '%s' "$RECEIPT" | jq -r '.tasks["S1-T1"].status')"
BOUNDARY="$(printf '%s' "$RECEIPT" | jq -r '.tasks["S1-T1"].boundary')"
if [ "$STATUS" != "BLOCKED" ] || [ "$BOUNDARY" != "AUTH" ]; then
  echo "FAIL: expected BLOCKED/AUTH from worker anchor, got $STATUS/$BOUNDARY: $RECEIPT" >&2
  exit 1
fi
if jq -e 'has("S1-T1")' "$REPO/.agent-army/leases.json" >/dev/null 2>&1; then
  echo "FAIL: BLOCKED task must release its lease" >&2
  exit 1
fi

printf 'silent\n' > "$MOCK_DIR/worker-mode/S1-T2"
mkdir -p "$MOCK_DIR/status"
printf 'blocked\n' > "$MOCK_DIR/status/worker_1-$SLUG"
cat > "$REPO/.agent-army/briefs/s-S1-T2.xml" <<'EOF'
<task_brief id="S1-T2" wave="1" seat="worker_1" verify="none">
  <role>Worker.</role>
  <objective>Wait silently while herdr reports blocked.</objective>
  <scope><read>README.md</read><owns>src/wait.py</owns></scope>
</task_brief>
EOF
partition_acquire_wave "$REPO" '[{"id":"S1-T2","seat":"worker_1","owns":["src/wait.py"]}]'
briefs_dispatch_task "$REPO" "worker_1" "1" "S1-T2" "$REPO/.agent-army/briefs/s-S1-T2.xml"
MANIFEST2="$REPO/.agent-army/waves/1b.json"
cat > "$MANIFEST2" <<EOF
{"wave": 1, "tasks": [
  {"id": "S1-T2", "seat": "worker_1", "owns": ["src/wait.py"], "verify": "none", "brief": "$REPO/.agent-army/briefs/s-S1-T2.xml", "base_ref": "$BLOCK_BASE"}
]}
EOF
RECEIPT2="$(supervisor_supervise_wave "$REPO" "$MANIFEST2")"
STATUS2="$(printf '%s' "$RECEIPT2" | jq -r '.tasks["S1-T2"].status')"
BOUNDARY2="$(printf '%s' "$RECEIPT2" | jq -r '.tasks["S1-T2"].boundary')"
REASON2="$(printf '%s' "$RECEIPT2" | jq -r '.tasks["S1-T2"].reason')"
if [ "$STATUS2" != "BLOCKED" ] || [ "$BOUNDARY2" != "AUTH" ]; then
  echo "FAIL: expected BLOCKED/AUTH from herdr agent_status, got $STATUS2/$BOUNDARY2: $RECEIPT2" >&2
  exit 1
fi
if [ "$REASON2" != "herdr_agent_blocked" ]; then
  echo "FAIL: expected reason herdr_agent_blocked, got '$REASON2'" >&2
  exit 1
fi
rm -f "$MOCK_DIR/status/worker_1-$SLUG"

echo "PASS: test_security_boundaries.sh"
