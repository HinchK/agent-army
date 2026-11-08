#!/bin/bash
set -euo pipefail

resolve_python() {
  if [ -n "${PYTHON_BIN:-}" ] && "$PYTHON_BIN" -c 'import sys, tomllib; assert sys.version_info >= (3, 11)' >/dev/null 2>&1; then
    export PYTHON_BIN
    return 0
  fi

  local cand
  for cand in python3 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
      local resolved
      resolved="$(command -v "$cand")"
      if "$resolved" -c 'import sys, tomllib; assert sys.version_info >= (3, 11)' >/dev/null 2>&1; then
        PYTHON_BIN="$resolved"
        export PYTHON_BIN
        return 0
      fi
    fi
  done

  echo "ERROR: Python 3.11+ with tomllib is required but was not found." >&2
  return 1
}

resolve_python || true
