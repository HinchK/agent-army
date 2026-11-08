#!/bin/bash
set -euo pipefail

_PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_PROFILE_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_PROFILE_DIR/common.sh"

DEFAULT_TEST_GLOBS="test/**,tests/**,__tests__/**,test_*,*_test.*,*.test.*,*_spec.*"

test_cmd_is_runnable() {
  local raw="${1:-}"
  local trimmed
  trimmed="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -z "$trimmed" ]; then
    return 1
  fi
  local lower
  lower="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    none|true|:|/bin/true|/usr/bin/true|"exit 0")
      return 1
      ;;
  esac
  return 0
}

_detect_repo_test_cmd() {
  local repo_dir="$1"
  local cfg_file="$repo_dir/army.config.toml"
  if [ -f "$cfg_file" ]; then
    resolve_python
    local from_toml
    from_toml="$("$PYTHON_BIN" - "$cfg_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
cmd = (data.get("profile") or {}).get("test_cmd") or (data.get("army") or {}).get("test_cmd") or ""
print(cmd)
PY
)"
    if [ -n "$from_toml" ]; then
      printf '%s\n' "$from_toml"
      return 0
    fi
  fi

  local mk
  for mk in "$repo_dir/Makefile" "$repo_dir/makefile" "$repo_dir/GNUmakefile"; do
    if [ -f "$mk" ] && grep -qE '^test[[:space:]]*:' "$mk"; then
      printf 'make test\n'
      return 0
    fi
  done

  if [ -f "$repo_dir/Cargo.toml" ]; then
    printf 'cargo test\n'
    return 0
  fi

  if [ -f "$repo_dir/go.mod" ]; then
    printf 'go test ./...\n'
    return 0
  fi

  if [ -f "$repo_dir/package.json" ]; then
    local pkg_test
    pkg_test="$(jq -r '.scripts.test // empty' "$repo_dir/package.json" 2>/dev/null || true)"
    if [ -n "$pkg_test" ] && ! printf '%s' "$pkg_test" | grep -qi 'no test specified'; then
      printf 'npm test\n'
      return 0
    fi
  fi

  if [ -f "$repo_dir/pyproject.toml" ] || [ -f "$repo_dir/pytest.ini" ] || [ -f "$repo_dir/setup.py" ]; then
    printf 'pytest\n'
    return 0
  fi

  printf '\n'
}

profile_ensure() {
  local repo_dir="$1"
  if [ ! -d "$repo_dir" ]; then
    log_error "Repository directory not found: $repo_dir"
    return 1
  fi

  local state_dir="$repo_dir/.agent-army"
  local profile_file="$state_dir/profile.env"

  local resolved_cmd=""
  local resolved_globs="${TEST_GLOBS:-}"
  local resolved_tc="${TOOLCHAIN_VARS:-}"

  if [ "${TEST_CMD+x}" = "x" ]; then
    resolved_cmd="$TEST_CMD"
  elif [ -f "$profile_file" ]; then
    local file_cmd=""
    local file_globs=""
    local file_tc=""
    eval "$(
      # shellcheck disable=SC1090
      source "$profile_file"
      printf 'file_cmd=%q\nfile_globs=%q\nfile_tc=%q\n' \
        "${TEST_CMD:-}" "${TEST_GLOBS:-}" "${TOOLCHAIN_VARS:-}"
    )"
    resolved_cmd="$file_cmd"
    if [ -z "$resolved_globs" ]; then
      resolved_globs="$file_globs"
    fi
    if [ -z "$resolved_tc" ]; then
      resolved_tc="$file_tc"
    fi
  else
    resolved_cmd="$(_detect_repo_test_cmd "$repo_dir")"
  fi

  if ! test_cmd_is_runnable "$resolved_cmd"; then
    log_error "Invalid or non-runnable TEST_CMD: '${resolved_cmd}'"
    return 1
  fi

  if [ -z "$resolved_globs" ]; then
    resolved_globs="$DEFAULT_TEST_GLOBS"
  fi

  if [ -z "$resolved_tc" ]; then
    resolved_tc="CARGO_HOME RUSTUP_HOME GOPATH GOCACHE GOMODCACHE VIRTUAL_ENV PYTHONPATH"
  fi

  mkdir -p "$state_dir"
  local tmp_file="$profile_file.tmp.$$"
  {
    printf 'export TEST_CMD=%q\n' "$resolved_cmd"
    printf 'export TEST_GLOBS=%q\n' "$resolved_globs"
    printf 'export TOOLCHAIN_VARS=%q\n' "$resolved_tc"
  } > "$tmp_file"
  mv "$tmp_file" "$profile_file"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    ensure)
      shift
      profile_ensure "$@"
      ;;
    is-runnable)
      shift
      test_cmd_is_runnable "$@"
      ;;
    *)
      profile_ensure "$@"
      ;;
  esac
fi
