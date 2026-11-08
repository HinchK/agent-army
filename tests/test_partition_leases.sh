#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=lib/pyenv.sh disable=SC1091
source "$ROOT_DIR/lib/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/partition.sh disable=SC1091
source "$ROOT_DIR/lib/partition.sh"

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

echo "=== Test 1: partition_paths_overlap prefix-boundary semantics [Review Focus #2] ==="
if ! partition_paths_overlap "src/auth" "src/auth/token.py"; then
  echo "FAIL: src/auth and src/auth/token.py should overlap" >&2
  exit 1
fi
if ! partition_paths_overlap "src/auth/token.py" "src/auth"; then
  echo "FAIL: overlap must be symmetric" >&2
  exit 1
fi
if partition_paths_overlap "src/auth" "src/auth_v2/token.py"; then
  echo "FAIL: src/auth and src/auth_v2/token.py must be disjoint (prefix boundary)" >&2
  exit 1
fi
if ! partition_paths_overlap "src/a.py" "src/a.py"; then
  echo "FAIL: identical paths should overlap" >&2
  exit 1
fi
if ! partition_paths_overlap "src/**" "src/deep/nested/file.py"; then
  echo "FAIL: glob src/** should overlap paths beneath src/" >&2
  exit 1
fi

echo "=== Test 2: partition_validate_paths rejects traversal, absolute, and .agent-army paths ==="
for bad in "../secret.txt" "/etc/passwd" ".agent-army/state.json" ".agent-army" ".." "src/../../escape.py" "foo/.."; do
  if partition_validate_paths "$bad" >/dev/null 2>&1; then
    echo "FAIL: partition_validate_paths accepted dangerous path '$bad'" >&2
    exit 1
  fi
done
for good in "src/a.py" "src/**,tests/**" "Makefile" "docs/guide.md"; do
  if ! partition_validate_paths "$good" >/dev/null 2>&1; then
    echo "FAIL: partition_validate_paths rejected valid owns '$good'" >&2
    exit 1
  fi
done
if partition_validate_paths "" >/dev/null 2>&1; then
  echo "FAIL: partition_validate_paths accepted an empty owns list" >&2
  exit 1
fi

echo "=== Test 3: partition_acquire_wave rejects overlap and leaves leases.json unchanged ==="
REPO="$TMP_ROOT/repo"
init_test_repo "$REPO"
state_init_slug "$REPO" "My Project!" >/dev/null
ensure_git_exclude "$REPO"

WAVE_OK='[{"id":"W1-T1","seat":"worker_1","owns":["src/auth"]},{"id":"W1-T2","seat":"worker_2","owns":["src/auth_v2"]}]'
partition_acquire_wave "$REPO" "$WAVE_OK"
LEASE_COUNT="$(jq 'length' "$REPO/.agent-army/leases.json")"
if [ "$LEASE_COUNT" != "2" ]; then
  echo "FAIL: expected 2 leases after acquire, got $LEASE_COUNT" >&2
  exit 1
fi

WAVE_OVERLAP='[{"id":"W1-T3","seat":"worker_1","owns":["src/auth/token.py"]},{"id":"W1-T4","seat":"worker_2","owns":["src/auth"]}]'
if partition_acquire_wave "$REPO" "$WAVE_OVERLAP" >/dev/null 2>&1; then
  echo "FAIL: acquire accepted a wave with overlapping owns" >&2
  exit 1
fi
LEASE_COUNT_AFTER="$(jq 'length' "$REPO/.agent-army/leases.json")"
if [ "$LEASE_COUNT_AFTER" != "2" ]; then
  echo "FAIL: failed acquire modified leases.json ($LEASE_COUNT_AFTER != 2)" >&2
  exit 1
fi

WAVE_CONFLICT_EXISTING='[{"id":"W1-T5","seat":"worker_1","owns":["src/auth/middleware.py"]}]'
if partition_acquire_wave "$REPO" "$WAVE_CONFLICT_EXISTING" >/dev/null 2>&1; then
  echo "FAIL: acquire accepted a wave conflicting with an existing lease" >&2
  exit 1
fi

WAVE_DANGEROUS='[{"id":"W1-T6","seat":"worker_1","owns":["../escape.py"]}]'
if partition_acquire_wave "$REPO" "$WAVE_DANGEROUS" >/dev/null 2>&1; then
  echo "FAIL: acquire accepted a dangerous owns path" >&2
  exit 1
fi

echo "=== Test 4: partition_check_diff_in_owns coverage including root files + ** globs ==="
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b army/my-project/worker_1
mkdir -p "$REPO/src/auth" "$REPO/tests"
echo "code" > "$REPO/src/auth/token.py"
echo "test" > "$REPO/tests/test_token.py"
echo "build" > "$REPO/Makefile"
git -C "$REPO" add src/auth/token.py tests/test_token.py Makefile
git -C "$REPO" commit -q -m "owned changes"
SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main

if ! partition_check_diff_in_owns "$REPO" "$BASE" "$SHA" "src/**,tests/**,Makefile"; then
  echo "FAIL: diff with root-level Makefile + ** globs should be covered" >&2
  exit 1
fi
if partition_check_diff_in_owns "$REPO" "$BASE" "$SHA" "src/**"; then
  echo "FAIL: tests/ and Makefile are not owned by src/** alone" >&2
  exit 1
fi

git -C "$REPO" checkout -q army/my-project/worker_1
mkdir -p "$REPO/src"
echo "extra" > "$REPO/src/unowned.py"
git -C "$REPO" add src/unowned.py
git -C "$REPO" commit -q -m "unowned addition"
SHA2="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
if partition_check_diff_in_owns "$REPO" "$BASE" "$SHA2" "src/auth,tests/**,Makefile"; then
  echo "FAIL: src/unowned.py is outside owns and must fail" >&2
  exit 1
fi

git -C "$REPO" checkout -q army/my-project/worker_1
mkdir -p "$REPO/.agent-army"
echo "smuggled" > "$REPO/.agent-army/smuggled.txt"
git -C "$REPO" add -f .agent-army/smuggled.txt
git -C "$REPO" commit -q -m "agent-army touch"
SHA3="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
if partition_check_diff_in_owns "$REPO" "$BASE" "$SHA3" "src/**,tests/**,Makefile,.agent-army/**"; then
  echo "FAIL: commits touching .agent-army/ must always fail the owns check" >&2
  exit 1
fi

if partition_check_diff_in_owns "$REPO" "$BASE" "$BASE" "src/**"; then
  echo "FAIL: an empty diff must fail the owns check" >&2
  exit 1
fi

echo "=== Test 5: partition_release_task and partition_reassign_lease ==="
partition_release_task "$REPO" "W1-T2"
if jq -e 'has("W1-T2")' "$REPO/.agent-army/leases.json" >/dev/null; then
  echo "FAIL: partition_release_task left W1-T2 in leases.json" >&2
  exit 1
fi

partition_reassign_lease "$REPO" "W1-T1" "W2-RESOLVE-W1-T1" "worker_1" "src/auth"
if jq -e 'has("W1-T1")' "$REPO/.agent-army/leases.json" >/dev/null; then
  echo "FAIL: reassign left the old task lease in place" >&2
  exit 1
fi
NEW_OWNS="$(jq -r '.["W2-RESOLVE-W1-T1"].owns[0]' "$REPO/.agent-army/leases.json")"
NEW_SEAT="$(jq -r '.["W2-RESOLVE-W1-T1"].seat' "$REPO/.agent-army/leases.json")"
if [ "$NEW_OWNS" != "src/auth" ] || [ "$NEW_SEAT" != "worker_1" ]; then
  echo "FAIL: reassigned lease has wrong owns='$NEW_OWNS' or seat='$NEW_SEAT'" >&2
  exit 1
fi
if partition_reassign_lease "$REPO" "W1-T1" "W2-X" "worker_1" "src/auth" >/dev/null 2>&1; then
  echo "FAIL: reassigning a lease that is not held must fail" >&2
  exit 1
fi

echo "PASS: test_partition_leases.sh"
