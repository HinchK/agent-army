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
# shellcheck source=lib/preflight.sh disable=SC1091
source "$ROOT_DIR/lib/preflight.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/bin"
mkdir -p "$MOCK_BIN"

REPO_DIR="$TMP_ROOT/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test User"

cat > "$REPO_DIR/Makefile" <<'EOF'
test:
	@echo "ok"
EOF
git -C "$REPO_DIR" add Makefile
git -C "$REPO_DIR" commit -q -m "initial"

REPO_PHYS="$(cd "$REPO_DIR" && pwd -P)"

cat > "$MOCK_BIN/herdr" <<EOF
#!/bin/bash
if [ "\$1" = "workspace" ] && [ "\$2" = "list" ]; then
  printf '[{"id":"ws-test-1","cwd":"%s"}]\n' "$REPO_PHYS"
  exit 0
fi
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then
  printf '[{"id":"ws-test-1:p1","workspace_id":"ws-test-1","cwd":"%s"}]\n' "$REPO_PHYS"
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/herdr"

for tool in pi opencode claude; do
  cat > "$MOCK_BIN/$tool" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$MOCK_BIN/$tool"
done

export PATH="$MOCK_BIN:$PATH"

cp "$ROOT_DIR/army.config.toml.example" "$REPO_DIR/army.config.toml"

echo "=== Test 1: preflight_check succeeds on clean repo on main with runnable TEST_CMD ==="
preflight_check "$REPO_DIR" "$REPO_DIR/army.config.toml"

SLUG="$(state_read_slug "$REPO_DIR")"
if [ "$SLUG" != "my-project" ]; then
  echo "FAIL: expected slug 'my-project' after preflight, got '$SLUG'" >&2
  exit 1
fi

WS_ID="$(find_workspace_by_cwd "$REPO_DIR")"
if [ "$WS_ID" != "ws-test-1" ]; then
  echo "FAIL: expected workspace id 'ws-test-1', got '$WS_ID'" >&2
  exit 1
fi

echo "=== Test 2: preflight_check fails closed on uncommitted tracked changes or wrong branch ==="
echo "dirty" >> "$REPO_DIR/Makefile"
if preflight_check "$REPO_DIR" "$REPO_DIR/army.config.toml" >/dev/null 2>&1; then
  echo "FAIL: preflight_check should fail when working tree has uncommitted tracked changes" >&2
  exit 1
fi
git -C "$REPO_DIR" checkout -- Makefile

git -C "$REPO_DIR" checkout -q -b feature-branch
if preflight_check "$REPO_DIR" "$REPO_DIR/army.config.toml" >/dev/null 2>&1; then
  echo "FAIL: preflight_check should fail when repo is not on base_branch" >&2
  exit 1
fi
git -C "$REPO_DIR" checkout -q main

sed -E 's/^harness = "pi"/harness = "unsupported_harness"/' "$REPO_DIR/army.config.toml" > "$TMP_ROOT/bad_harness.toml"
if preflight_check "$REPO_DIR" "$TMP_ROOT/bad_harness.toml" >/dev/null 2>&1; then
  echo "FAIL: preflight_check should fail when COMMANDER_HARNESS is unsupported" >&2
  exit 1
fi

rm -f "$MOCK_BIN/pi"
for sys_dep in git jq gh; do
  ln -sf "$(command -v "$sys_dep")" "$MOCK_BIN/$sys_dep"
done
ERR_OUT="$(PATH="$MOCK_BIN:/usr/bin:/bin" preflight_check "$REPO_DIR" "$REPO_DIR/army.config.toml" 2>&1 || true)"
if ! printf '%s' "$ERR_OUT" | grep -q "configured commander harness 'pi' not found on PATH"; then
  echo "FAIL: expected missing harness error for 'pi', got: $ERR_OUT" >&2
  exit 1
fi
cat > "$MOCK_BIN/pi" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$MOCK_BIN/pi"

echo "=== Test 3: telemetry.py log appends valid JSONL with no stdout/ANSI output ==="
resolve_python
TELEM_OUT="$("$PYTHON_BIN" "$ROOT_DIR/lib/telemetry.py" log "$REPO_DIR/.agent-army" "gate_pass" "worker_1" "W1-T1" '{"sha":"abc1234"}')"
if [ -n "$TELEM_OUT" ]; then
  echo "FAIL: telemetry.py should produce no stdout output, got: '$TELEM_OUT'" >&2
  exit 1
fi

VERDICTS_FILE="$REPO_DIR/.agent-army/session-verdicts.jsonl"
if [ ! -f "$VERDICTS_FILE" ]; then
  echo "FAIL: session-verdicts.jsonl was not created" >&2
  exit 1
fi

EVENT_VAL="$(jq -r '.event' "$VERDICTS_FILE")"
SEAT_VAL="$(jq -r '.seat' "$VERDICTS_FILE")"
TASK_VAL="$(jq -r '.task_id' "$VERDICTS_FILE")"
SHA_VAL="$(jq -r '.payload.sha' "$VERDICTS_FILE")"
TS_VAL="$(jq -r '.ts' "$VERDICTS_FILE")"

if [ "$EVENT_VAL" != "gate_pass" ] || [ "$SEAT_VAL" != "worker_1" ] || [ "$TASK_VAL" != "W1-T1" ] || [ "$SHA_VAL" != "abc1234" ] || [ -z "$TS_VAL" ]; then
  echo "FAIL: unexpected telemetry JSONL row: $(cat "$VERDICTS_FILE")" >&2
  exit 1
fi

echo "PASS: test_preflight.sh"
