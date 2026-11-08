#!/bin/bash
set -euo pipefail

_PART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_PART_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_PART_DIR/common.sh"

_PARTITION_PY='
import json
import os
import re
import subprocess
import sys


def glob_regex(pat):
    out = []
    i = 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if i + 1 < len(pat) and pat[i + 1] == "*":
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return "^" + "".join(out) + "$"


def covered(path, own):
    if path == own:
        return True
    stripped = own.rstrip("/")
    if stripped and path.startswith(stripped + "/"):
        return True
    return re.search(glob_regex(own), path) is not None


def valid_own(p):
    if not p or p == ".." or p.startswith("../") or "/../" in ("/" + p + "/") or p.startswith("/"):
        return False
    if p == ".agent-army" or p.startswith(".agent-army/"):
        return False
    return True


def overlap(a, b):
    if a == b:
        return True
    for x, y in ((a, b), (b, a)):
        stripped = x.rstrip("/")
        if stripped and y.startswith(stripped + "/"):
            return True
        if re.search(glob_regex(x), y) is not None:
            return True
    return False


def load_leases(repo):
    path = os.path.join(repo, ".agent-army", "leases.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f), path
    return {}, path


def save_leases(leases, path):
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(leases, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def csv_list(raw):
    return [p.strip() for p in raw.split(",") if p.strip()]


cmd = sys.argv[1]
if cmd == "overlap":
    sys.exit(0 if overlap(sys.argv[2], sys.argv[3]) else 1)
elif cmd == "validate":
    owns = csv_list(sys.argv[2])
    if not owns:
        die("partition: owns list is empty")
    for o in owns:
        if not valid_own(o):
            die("partition: invalid owns path: %s" % o)
    sys.exit(0)
elif cmd == "check-diff":
    repo, base, sha, owns_csv = sys.argv[2:6]
    owns = csv_list(owns_csv)
    if not owns:
        die("partition: owns list is empty")
    diff = subprocess.run(
        ["git", "-C", repo, "diff", "--name-only", "%s...%s" % (base, sha)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    paths = [l for l in diff.splitlines() if l]
    if not paths:
        die("partition: empty diff between %s and %s" % (base, sha))
    for p in paths:
        if p == ".agent-army" or p.startswith(".agent-army/"):
            die("partition: commit touches forbidden .agent-army/ path: %s" % p)
    for p in paths:
        if not any(covered(p, o) for o in owns):
            die("partition: path outside owns: %s" % p)
    sys.exit(0)
elif cmd == "acquire":
    repo, wave_json = sys.argv[2], sys.argv[3]
    try:
        tasks = json.loads(wave_json)
    except json.JSONDecodeError as exc:
        die("partition: invalid wave manifest JSON: %s" % exc)
    if not isinstance(tasks, list) or not tasks:
        die("partition: wave manifest must be a non-empty JSON array")
    leases, leases_path = load_leases(repo)
    entries = []
    for t in tasks:
        tid = (t.get("id") or "").strip()
        if not tid:
            die("partition: wave task missing id")
        owns = [str(o).strip() for o in (t.get("owns") or []) if str(o).strip()]
        if not owns:
            die("partition: task %s has empty owns" % tid)
        for o in owns:
            if not valid_own(o):
                die("partition: task %s invalid owns path: %s" % (tid, o))
        entries.append({"id": tid, "seat": t.get("seat", ""), "owns": owns})
    for i in range(len(entries)):
        for j in range(i + 1, len(entries)):
            if entries[i]["id"] == entries[j]["id"]:
                die("partition: duplicate task id %s in wave" % entries[i]["id"])
            for oa in entries[i]["owns"]:
                for ob in entries[j]["owns"]:
                    if overlap(oa, ob):
                        die(
                            "partition: owns overlap in wave between %s:%s and %s:%s"
                            % (entries[i]["id"], oa, entries[j]["id"], ob)
                        )
    for e in entries:
        for lid, ldata in leases.items():
            if lid == e["id"]:
                continue
            lowns = [str(o) for o in (ldata.get("owns") or [])]
            for oa in e["owns"]:
                for ob in lowns:
                    if overlap(oa, ob):
                        die(
                            "partition: owns conflict with existing lease %s:%s vs %s:%s"
                            % (e["id"], oa, lid, ob)
                        )
    for e in entries:
        leases[e["id"]] = {"seat": e["seat"], "owns": e["owns"]}
    save_leases(leases, leases_path)
    sys.exit(0)
elif cmd == "release":
    repo, tid = sys.argv[2], sys.argv[3]
    leases, leases_path = load_leases(repo)
    if tid in leases:
        del leases[tid]
        save_leases(leases, leases_path)
    sys.exit(0)
elif cmd == "reassign":
    repo, old, new, seat, owns_csv = sys.argv[2:7]
    owns = csv_list(owns_csv)
    if not owns:
        die("partition: owns list is empty")
    for o in owns:
        if not valid_own(o):
            die("partition: invalid owns path: %s" % o)
    leases, leases_path = load_leases(repo)
    if old not in leases:
        die("partition: no lease held by %s" % old)
    if new != old and new in leases:
        die("partition: lease id %s already exists" % new)
    del leases[old]
    leases[new] = {"seat": seat, "owns": owns}
    save_leases(leases, leases_path)
    sys.exit(0)
else:
    die("partition: unknown subcommand %s" % cmd)
'

# partition_validate_paths <owns_csv>
# Exits 1 on an empty list, a ".." path segment, a leading "/", or any
# .agent-army path. Globs are allowed anywhere else.
partition_validate_paths() {
  local owns_csv="${1:-}"
  if [ -z "$owns_csv" ]; then
    log_error "partition_validate_paths: owns list is empty"
    return 1
  fi
  resolve_python
  if "$PYTHON_BIN" -c "$_PARTITION_PY" validate "$owns_csv"; then
    return 0
  fi
  return 1
}

# partition_paths_overlap <path_a> <path_b>
# Exits 0 when identical, when one is a directory prefix of the other, or when
# one glob-matches the other; exits 1 otherwise.
partition_paths_overlap() {
  local a="${1:-}"
  local b="${2:-}"
  if [ -z "$a" ] || [ -z "$b" ]; then
    return 1
  fi
  resolve_python
  if "$PYTHON_BIN" -c "$_PARTITION_PY" overlap "$a" "$b"; then
    return 0
  fi
  return 1
}

# partition_check_diff_in_owns <repo_dir> <base_ref> <sha> <owns_csv>
# Exits 1 when the diff is empty, touches .agent-army/, or modifies any path
# not covered by <owns_csv> (exact, directory-prefix, or ** glob coverage).
partition_check_diff_in_owns() {
  local repo_dir="$1"
  local base_ref="$2"
  local sha="$3"
  local owns_csv="$4"
  resolve_python
  "$PYTHON_BIN" -c "$_PARTITION_PY" check-diff "$repo_dir" "$base_ref" "$sha" "$owns_csv"
}

_partition_lock_dir() {
  printf '%s/.agent-army/leases.lock' "$1"
}

_partition_lock() {
  local lock_dir
  lock_dir="$(_partition_lock_dir "$1")"
  mkdir -p "$(dirname "$lock_dir")"
  local tries=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ -f "$lock_dir/pid" ]; then
      local pid
      pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
      if [ -n "$pid" ]; then
        local state=""
        state="$(ps -o state= -p "$pid" 2>/dev/null | awk '{print substr($1,1,1)}' || true)"
        if ! kill -0 "$pid" 2>/dev/null || [ "$state" = "T" ]; then
          rm -rf "$lock_dir"
          continue
        fi
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      log_error "partition: leases lock busy at $lock_dir"
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' $$ > "$lock_dir/pid"
}

_partition_unlock() {
  rm -rf "$(_partition_lock_dir "$1")" 2>/dev/null || true
}

# partition_acquire_wave <repo_dir> <wave_tasks_json>
# Takes [{"id","seat","owns":[...]}], validates paths, checks pairwise
# disjointness across the wave and against existing leases, and atomically
# writes all new leases. Exits 1 leaving leases.json unchanged on any failure.
partition_acquire_wave() {
  local repo_dir="$1"
  local wave_json="$2"
  resolve_python
  _partition_lock "$repo_dir"
  local rc=0
  "$PYTHON_BIN" -c "$_PARTITION_PY" acquire "$repo_dir" "$wave_json" || rc=$?
  _partition_unlock "$repo_dir"
  return "$rc"
}

# partition_release_task <repo_dir> <task_id>
partition_release_task() {
  local repo_dir="$1"
  local task_id="$2"
  resolve_python
  _partition_lock "$repo_dir"
  local rc=0
  "$PYTHON_BIN" -c "$_PARTITION_PY" release "$repo_dir" "$task_id" || rc=$?
  _partition_unlock "$repo_dir"
  return "$rc"
}

# partition_reassign_lease <repo_dir> <old_task_id> <new_task_id> <seat> <owns_csv>
partition_reassign_lease() {
  local repo_dir="$1"
  local old_task_id="$2"
  local new_task_id="$3"
  local seat="$4"
  local owns_csv="$5"
  resolve_python
  _partition_lock "$repo_dir"
  local rc=0
  "$PYTHON_BIN" -c "$_PARTITION_PY" reassign "$repo_dir" "$old_task_id" "$new_task_id" "$seat" "$owns_csv" || rc=$?
  _partition_unlock "$repo_dir"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    validate)
      shift
      partition_validate_paths "$@"
      ;;
    overlap)
      shift
      partition_paths_overlap "$@"
      ;;
    check-diff)
      shift
      partition_check_diff_in_owns "$@"
      ;;
    acquire-wave)
      shift
      partition_acquire_wave "$@"
      ;;
    release)
      shift
      partition_release_task "$@"
      ;;
    reassign)
      shift
      partition_reassign_lease "$@"
      ;;
    *)
      echo "Usage: partition.sh {validate|overlap|check-diff|acquire-wave|release|reassign} <args>" >&2
      exit 1
      ;;
  esac
fi
