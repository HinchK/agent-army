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
