#!/bin/bash
set -euo pipefail

_WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_WT_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_WT_DIR/common.sh"

worktree_pool_root() {
  printf '%s/.agent-army/worktrees' "$1"
}

# worktree_provision <repo_dir> <seat> [base_ref]
# Prints the physical worktree path on stdout.
worktree_provision() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local seat="$2"
  local base_ref="${3:-HEAD}"

  ensure_git_exclude "$repo_dir"
  local slug
  slug="$(state_read_slug "$repo_dir")"

  local wt_root
  wt_root="$(worktree_pool_root "$repo_dir")"
  local wt="$wt_root/$seat"
  local branch="army/$slug/$seat"

  if [ -d "$wt" ] && git -C "$repo_dir" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
    :
  elif [ -d "$wt" ] && [ ! -e "$wt/.git" ]; then
    rm -rf "$wt"
    mkdir -p "$wt_root"
    git -C "$repo_dir" worktree add -b "$branch" "$wt" "$base_ref" >/dev/null
  elif git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    mkdir -p "$wt_root"
    git -C "$repo_dir" worktree add "$wt" "$branch" >/dev/null
  else
    mkdir -p "$wt_root"
    git -C "$repo_dir" worktree add -b "$branch" "$wt" "$base_ref" >/dev/null
  fi

  mkdir -p "$wt/.agent-army/briefs" "$wt/.agent-army/anchors"
  printf '%s\n' "$(cd "$wt" && pwd -P)"
}

# worktree_snapshot <repo_dir> <seat>
# Copies status, uncommitted diff, and untracked files (excluding .agent-army/)
# into <repo_dir>/.agent-army/snapshots/<epoch>-<pid>/<seat>/ and prints the path.
worktree_snapshot() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local seat="$2"
  local wt_root
  wt_root="$(worktree_pool_root "$repo_dir")"
  local wt="$wt_root/$seat"
  if [ ! -d "$wt" ]; then
    log_error "worktree_snapshot: no worktree for seat '$seat'"
    return 1
  fi

  local dest
  dest="$repo_dir/.agent-army/snapshots/$(date +%s)-$$/$seat"
  mkdir -p "$dest"

  git -C "$wt" status --porcelain > "$dest/status.porcelain"
  if ! git -C "$wt" diff HEAD > "$dest/diff.patch" 2>/dev/null; then
    : > "$dest/diff.patch"
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$dest/untracked/$(dirname "$f")"
    cp "$wt/$f" "$dest/untracked/$f"
  done < <(git -C "$wt" ls-files --others --exclude-standard)

  printf '%s\n' "$dest"
}

# worktree_sync_pool <repo_dir> <target_ref> [busy_seats_csv]
# Advances every idle seat worktree to <target_ref>. Skips arbiter-* worktrees,
# seats listed in <busy_seats_csv>, seats with a .agent-army/.active_task marker,
# and seats whose HEAD is detached or whose branch no longer exists. Fails if an
# idle worktree has uncommitted changes. Rebases the seat branch onto the target
# and falls back to `git reset --hard` when the rebase cannot complete.
worktree_sync_pool() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local target_ref="$2"
  local busy_csv="${3:-}"

  local slug
  slug="$(state_read_slug "$repo_dir")"
  local wt_root
  wt_root="$(worktree_pool_root "$repo_dir")"
  [ -d "$wt_root" ] || return 0

  local target_sha
  target_sha="$(git -C "$repo_dir" rev-parse "$target_ref")"

  local wt seat branch porcelain
  for wt in "$wt_root"/*; do
    [ -d "$wt" ] || continue
    seat="$(basename "$wt")"
    case "$seat" in
      arbiter-*) continue ;;
    esac
    if [ -n "$busy_csv" ] && printf ',%s,' "$busy_csv" | grep -qF ",$seat,"; then
      continue
    fi
    if [ -e "$wt/.agent-army/.active_task" ]; then
      continue
    fi
    branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -z "$branch" ]; then
      continue
    fi
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
      continue
    fi
    porcelain="$(git -C "$wt" status --porcelain)"
    if [ -n "$porcelain" ]; then
      log_error "worktree_sync_pool: idle seat '$seat' has uncommitted changes; refusing to sync"
      return 1
    fi
    if ! git -C "$wt" rebase "$target_sha" >/dev/null 2>&1; then
      git -C "$wt" rebase --abort >/dev/null 2>&1 || true
      git -C "$wt" reset --hard "$target_sha" >/dev/null
    fi
  done
  return 0
}

# worktree_sync_seat <repo_dir> <seat> <target_ref>
# Resets one clean seat worktree's branch to <target_ref> (used to base a
# conflict-resolution task on the integration tip). Refuses when dirty.
worktree_sync_seat() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local seat="$2"
  local target_ref="$3"
  local wt_root
  wt_root="$(worktree_pool_root "$repo_dir")"
  local wt="$wt_root/$seat"
  if [ ! -d "$wt" ]; then
    log_error "worktree_sync_seat: no worktree for seat '$seat'"
    return 1
  fi
  local porcelain
  porcelain="$(git -C "$wt" status --porcelain)"
  if [ -n "$porcelain" ]; then
    log_error "worktree_sync_seat: seat '$seat' is dirty; refusing to sync"
    return 1
  fi
  git -C "$wt" reset --hard "$(git -C "$repo_dir" rev-parse "$target_ref")" >/dev/null
}

# worktree_teardown <repo_dir> <seat>
# Snapshots a dirty worktree before removal so no work is lost.
worktree_teardown() {
  local repo_dir="$1"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
  local seat="$2"
  local wt_root
  wt_root="$(worktree_pool_root "$repo_dir")"
  local wt="$wt_root/$seat"
  if [ ! -d "$wt" ]; then
    return 0
  fi
  local porcelain
  porcelain="$(git -C "$wt" status --porcelain || true)"
  if [ -n "$porcelain" ]; then
    worktree_snapshot "$repo_dir" "$seat" >/dev/null
    git -C "$repo_dir" worktree remove --force "$wt" >/dev/null
  else
    git -C "$repo_dir" worktree remove "$wt" >/dev/null
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    provision)
      shift
      worktree_provision "$@"
      ;;
    snapshot)
      shift
      worktree_snapshot "$@"
      ;;
    sync)
      shift
      worktree_sync_pool "$@"
      ;;
    sync-seat)
      shift
      worktree_sync_seat "$@"
      ;;
    teardown)
      shift
      worktree_teardown "$@"
      ;;
    *)
      echo "Usage: worktree.sh {provision|snapshot|sync|sync-seat|teardown} <args>" >&2
      exit 1
      ;;
  esac
fi
