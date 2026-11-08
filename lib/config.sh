#!/bin/bash
set -euo pipefail

_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_CONFIG_DIR/pyenv.sh"

config_dump() {
  local toml_path="${1:-}"
  if [ -z "$toml_path" ] || [ ! -f "$toml_path" ]; then
    echo "ERROR: config_dump requires a valid TOML file path (got '$toml_path')" >&2
    return 1
  fi

  resolve_python
  "$PYTHON_BIN" - "$toml_path" <<'PY'
import re
import shlex
import sys
import tomllib

path = sys.argv[1]
with open(path, "rb") as f:
    cfg = tomllib.load(f)

army = cfg.get("army") or {}
cmd = cfg.get("commander") or {}
seats = cfg.get("seats") or {}

def fmt(val, default=""):
    if val is None:
        val = default
    if isinstance(val, bool):
        return "true" if val else "false"
    return str(val)

def emit(key, val):
    print(f"export {key}={shlex.quote(val)}")

emit("ARMY_NAME", fmt(army.get("name"), "project"))
emit("ARMY_BASE_BRANCH", fmt(army.get("base_branch"), "main"))
emit("ARMY_MAX_WAVES", fmt(army.get("max_waves"), "15"))
emit("ARMY_MAX_REPAIRS_PER_TASK", fmt(army.get("max_repairs_per_task"), "1"))
emit("ARMY_TASK_TIMEOUT_SEC", fmt(army.get("task_timeout_sec"), "1800"))
emit(
    "ARMY_CREATE_DRAFT_PR",
    fmt(
        army.get(
            "create_draft_pr_on_complete",
            army.get("create_draft_pr", False),
        ),
        "false",
    ),
)

emit("COMMANDER_HARNESS", fmt(cmd.get("harness"), "pi"))
emit("COMMANDER_MODEL", fmt(cmd.get("model"), "anthropic/claude-sonnet-4-5"))
emit("COMMANDER_THINKING", fmt(cmd.get("thinking"), "high"))
emit("COMMANDER_TIMEOUT_SEC", fmt(cmd.get("timeout_sec"), "600"))

seat_ids = list(seats.keys())
emit("SEAT_IDS", " ".join(seat_ids))

for seat_id, sdata in seats.items():
    if not isinstance(sdata, dict):
        continue
    upper = re.sub(r"[^A-Za-z0-9_]", "_", seat_id).upper()
    emit(f"SEAT_{upper}_KIND", fmt(sdata.get("kind"), "opencode"))
    emit(f"SEAT_{upper}_MODEL", fmt(sdata.get("model"), ""))
    emit(f"SEAT_{upper}_ROLE", fmt(sdata.get("role"), "worker"))
    emit(f"SEAT_{upper}_WORKTREE", fmt(sdata.get("worktree", True), "true"))
    emit(f"SEAT_{upper}_CRITICAL", fmt(sdata.get("critical", False), "false"))
PY
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    dump)
      shift
      config_dump "$@"
      ;;
    *)
      config_dump "$@"
      ;;
  esac
fi
