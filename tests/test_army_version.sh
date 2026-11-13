#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

echo "=== Test 1: army version prints 1.0.0 ==="
if ! got="$("$ROOT_DIR/bin/army" version)"; then
  echo "FAIL: army version exited nonzero" >&2
  exit 1
fi
if [ "$got" != "1.0.0" ]; then
  echo "FAIL: army version printed '$got'" >&2
  exit 1
fi
echo "ok"

echo "=== Test 2: army help lists version ==="
help="$("$ROOT_DIR/bin/army" --help 2>&1)"
case "$help" in
  *"army version"*) ;;
  *)
    echo "FAIL: help does not list army version" >&2
    exit 1
    ;;
esac
echo "ok"
