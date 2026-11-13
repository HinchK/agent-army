#!/bin/bash
set -euo pipefail

_PROVIDERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_PROVIDERS_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_PROVIDERS_DIR/common.sh"

# credential_free_env_prefix
# Prints the env(1) argument prefix that strips ambient credentials and points
# cloud credential files at a missing path. Worker and verifier processes must
# always be launched through this prefix.
credential_free_env_prefix() {
  printf '%s\n' "env -u GITHUB_TOKEN -u GH_TOKEN -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_REGION -u AWS_REGION -u AWS_SECURITY_TOKEN AWS_SHARED_CREDENTIALS_FILE=/nonexistent GOOGLE_APPLICATION_CREDENTIALS=/nonexistent CLOUDSDK_CONFIG=/nonexistent"
}

# providers_prepare_seat <worktree_dir> <kind> <model>
# Writes harness-specific model pinning inside the seat worktree.
providers_prepare_seat() {
  local worktree_dir="$1"
  local kind="$2"
  local model="${3:-}"
  if [ "$kind" = "opencode" ]; then
    mkdir -p "$worktree_dir/.opencode"
    if [ -n "$model" ]; then
      jq -n --arg m "$model" '{"model": $m}' > "$worktree_dir/.opencode/opencode.json"
    fi
    # The pinning config is per-seat tooling state, never a repo change: keep
    # it out of git status so idle seats stay clean for pool sync and gates.
    git_exclude_ensure "$worktree_dir" '.opencode/'
  fi
}

# providers_start_fresh_session <repo_dir> <seat> <pane_id> <kind> <model>
# Clears any previous registration of <seat>-<slug>, returns the pane to its
# shell, and starts a new credential-free session. herdr agent start requires
# an interactive prompt and rejects a name that is already taken. `exit` is
# not used: that closes the shell.
providers_start_fresh_session() {
  local repo_dir="$1"
  local seat="$2"
  local pane_id="$3"
  local kind="$4"
  local model="${5:-}"

  local slug
  slug="$(state_read_slug "$repo_dir")"
  local agent="${seat}-${slug}"

  # Live herdr keeps the name after the first start. Clear it, then leave the
  # TUI so the pane is a shell again. `exit` is not used: that closes the shell.
  herdr agent rename "$agent" --clear >/dev/null 2>&1 || true
  herdr agent send-keys "$pane_id" ctrl+c >/dev/null 2>&1 || true
  if [ -z "${HERDR_MOCK_DIR:-}" ]; then
    sleep 1
  fi

  # shellcheck disable=SC2046
  $(credential_free_env_prefix) herdr agent start "$agent" --kind "$kind" --pane "$pane_id"
}

# providers_submit_prompt <pane_or_agent> <short_prompt>
# Rejects prompts of >= 200 bytes so multi-line XML can never saturate the PTY
# canonical input buffer; delivers via `herdr agent prompt` followed by enter.
providers_submit_prompt() {
  local target="$1"
  local prompt="$2"
  local len
  len=${#prompt}
  if [ "$len" -ge 200 ]; then
    log_error "providers_submit_prompt: prompt is ${len} chars (>=200); deliver a file-path brief instead"
    return 1
  fi
  herdr agent prompt "$target" "$prompt"
  sleep "${ARMY_SUBMIT_DELAY:-1}"
  herdr agent send-keys "$target" enter
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "providers.sh is a sourced library; no CLI entry point." >&2
  exit 1
fi
