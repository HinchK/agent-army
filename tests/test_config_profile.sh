#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=lib/pyenv.sh disable=SC1091
source "$ROOT_DIR/lib/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/profile.sh disable=SC1091
source "$ROOT_DIR/lib/profile.sh"

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

echo "=== Test 1: slugify and state_init_slug single-slug invariant ==="
REPO1="$TMP_ROOT/repo1"
init_test_repo "$REPO1"

if state_read_slug "$REPO1" >/dev/null 2>&1; then
  echo "FAIL: state_read_slug should fail before state_init_slug" >&2
  exit 1
fi

SLUG1="$(state_init_slug "$REPO1" "My Project!")"
if [ "$SLUG1" != "my-project" ]; then
  echo "FAIL: expected slug 'my-project', got '$SLUG1'" >&2
  exit 1
fi

SLUG2="$(state_init_slug "$REPO1" "Completely Different Name")"
if [ "$SLUG2" != "my-project" ]; then
  echo "FAIL: single-slug invariant violated: expected 'my-project', got '$SLUG2'" >&2
  exit 1
fi

READ_SLUG="$(state_read_slug "$REPO1")"
if [ "$READ_SLUG" != "my-project" ]; then
  echo "FAIL: state_read_slug returned '$READ_SLUG'" >&2
  exit 1
fi

ZERO_WAVES="$(jq -r '.zero_integrate_waves' "$REPO1/.agent-army/state.json")"
STATE_STATUS="$(jq -r '.status' "$REPO1/.agent-army/state.json")"
if [ "$ZERO_WAVES" != "0" ] || [ "$STATE_STATUS" != "idle" ]; then
  echo "FAIL: unexpected initial state fields: zero_integrate_waves=$ZERO_WAVES status=$STATE_STATUS" >&2
  exit 1
fi

echo "=== Test 2: ensure_git_exclude idempotency and git status cleanliness ==="
ensure_git_exclude "$REPO1"
ensure_git_exclude "$REPO1"

EXCLUDE_FILE="$REPO1/.git/info/exclude"
COUNT="$(grep -c '^\.agent-army/$' "$EXCLUDE_FILE")"
if [ "$COUNT" -ne 1 ]; then
  echo "FAIL: expected exactly 1 .agent-army/ entry in exclude, got $COUNT" >&2
  exit 1
fi

mkdir -p "$REPO1/.agent-army/anchors"
echo "test" > "$REPO1/.agent-army/anchors/W1-T1.txt"
PORCELAIN="$(git -C "$REPO1" status --porcelain)"
if [ -n "$PORCELAIN" ]; then
  echo "FAIL: expected empty git status --porcelain, got: $PORCELAIN" >&2
  exit 1
fi

echo "=== Test 3: test_cmd_is_runnable and profile_ensure ==="
for bad_cmd in "" "none" "true" "  " "NONE" "TRUE" ":"; do
  if test_cmd_is_runnable "$bad_cmd"; then
    echo "FAIL: test_cmd_is_runnable accepted bad command: '$bad_cmd'" >&2
    exit 1
  fi
done

if ! test_cmd_is_runnable "pytest"; then
  echo "FAIL: test_cmd_is_runnable rejected 'pytest'" >&2
  exit 1
fi

if TEST_CMD="true" profile_ensure "$REPO1" >/dev/null 2>&1; then
  echo "FAIL: profile_ensure should fail when TEST_CMD=true" >&2
  exit 1
fi

TEST_CMD="pytest -q" TOOLCHAIN_VARS="FOO_TOOL=bar_val" profile_ensure "$REPO1"
if [ ! -f "$REPO1/.agent-army/profile.env" ]; then
  echo "FAIL: profile_ensure did not write .agent-army/profile.env" >&2
  exit 1
fi

echo "=== Test 4: clean_gate_exec runs with CI=true and strips HERDR_*, REPO_DIR, STATE_DIR ==="
PROFILE_FILE="$REPO1/.agent-army/profile.env"
# shellcheck disable=SC2016
HERDR_PANE_ID="w1:p1" HERDR_ENV="1" REPO_DIR="/bad/repo" STATE_DIR="/bad/state" CI="false" \
  clean_gate_exec "$REPO1" "$PROFILE_FILE" 10 \
  'test "$CI" = "true" && test -z "${HERDR_PANE_ID:-}" && test -z "${HERDR_ENV:-}" && test -z "${REPO_DIR:-}" && test -z "${STATE_DIR:-}" && test "${FOO_TOOL:-}" = "bar_val" && test -d "${TMPDIR:-}"'

echo "=== Test 5: config_dump exports expected variables ==="
ARMY_NAME=""
ARMY_BASE_BRANCH=""
COMMANDER_HARNESS=""
SEAT_IDS=""
SEAT_WORKER_1_KIND=""
SEAT_VERIFIER_ROLE=""
eval "$(config_dump "$ROOT_DIR/army.config.toml.example")"
if [ "$ARMY_NAME" != "my-project" ] || [ "$ARMY_BASE_BRANCH" != "main" ]; then
  echo "FAIL: unexpected ARMY_NAME=$ARMY_NAME or ARMY_BASE_BRANCH=$ARMY_BASE_BRANCH" >&2
  exit 1
fi
if [ "$COMMANDER_HARNESS" != "pi" ] || [ "$SEAT_IDS" != "worker_1 worker_2 verifier" ]; then
  echo "FAIL: unexpected COMMANDER_HARNESS=$COMMANDER_HARNESS or SEAT_IDS=$SEAT_IDS" >&2
  exit 1
fi
if [ "$SEAT_WORKER_1_KIND" != "opencode" ] || [ "$SEAT_VERIFIER_ROLE" != "verifier" ]; then
  echo "FAIL: unexpected seat exports: SEAT_WORKER_1_KIND=$SEAT_WORKER_1_KIND SEAT_VERIFIER_ROLE=$SEAT_VERIFIER_ROLE" >&2
  exit 1
fi

echo "PASS: test_config_profile.sh"
