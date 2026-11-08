#!/bin/bash
set -euo pipefail

_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_PREFLIGHT_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_PREFLIGHT_DIR/common.sh"
# shellcheck source=lib/config.sh disable=SC1091
source "$_PREFLIGHT_DIR/config.sh"
# shellcheck source=lib/profile.sh disable=SC1091
source "$_PREFLIGHT_DIR/profile.sh"

preflight_check() {
  local repo_dir="${1:-}"
  local config_path="${2:-}"

  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ]; then
    log_error "Preflight failed: invalid repo_dir '$repo_dir'"
    return 1
  fi

  if [ -z "$config_path" ]; then
    config_path="$repo_dir/army.config.toml"
  fi
  if [ ! -f "$config_path" ]; then
    log_error "Preflight failed: config file not found at '$config_path'"
    return 1
  fi

  resolve_python

  local dep
  for dep in git jq gh herdr; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log_error "Preflight failed: missing required dependency '$dep' on PATH"
      return 1
    fi
  done

  if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Preflight failed: '$repo_dir' is not a Git repository"
    return 1
  fi

  eval "$(config_dump "$config_path")"

  local harness="${COMMANDER_HARNESS:-pi}"
  case "$harness" in
    pi|opencode) ;;
    *)
      log_error "Preflight failed: unsupported commander harness '$harness' (expected 'pi' or 'opencode')"
      return 1
      ;;
  esac
  if ! command -v "$harness" >/dev/null 2>&1; then
    log_error "Preflight failed: configured commander harness '$harness' not found on PATH"
    return 1
  fi

  ensure_git_exclude "$repo_dir"

  local base_branch="${ARMY_BASE_BRANCH:-main}"
  local current_branch
  current_branch="$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$current_branch" != "$base_branch" ]; then
    log_error "Preflight failed: repository is on branch '$current_branch', expected '$base_branch'"
    return 1
  fi

  local porcelain
  porcelain="$(git -C "$repo_dir" status --porcelain | grep -vE '^\?\? (army\.config\.toml|mission\.md)$' || true)"
  if [ -n "$porcelain" ]; then
    log_error "Preflight failed: working tree has uncommitted changes"
    return 1
  fi

  if ! profile_ensure "$repo_dir"; then
    log_error "Preflight failed: repository does not have a runnable TEST_CMD"
    return 1
  fi

  state_init_slug "$repo_dir" "${ARMY_NAME:-project}" >/dev/null
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    check)
      shift
      preflight_check "$@"
      ;;
    *)
      preflight_check "$@"
      ;;
  esac
fi
