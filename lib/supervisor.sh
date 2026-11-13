#!/bin/bash
set -euo pipefail

_SUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/pyenv.sh disable=SC1091
source "$_SUP_DIR/pyenv.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$_SUP_DIR/common.sh"
# shellcheck source=lib/profile.sh disable=SC1091
source "$_SUP_DIR/profile.sh"
# shellcheck source=lib/worktree.sh disable=SC1091
source "$_SUP_DIR/worktree.sh"
# shellcheck source=lib/partition.sh disable=SC1091
source "$_SUP_DIR/partition.sh"
# shellcheck source=lib/briefs.sh disable=SC1091
source "$_SUP_DIR/briefs.sh"

# lib/arbiter.sh always ships alongside this file now; the SDD Ruling 2
# standalone fallback stub is retired so every queue mutation is locked.
# shellcheck source=lib/arbiter.sh disable=SC1091
source "$_SUP_DIR/arbiter.sh"

ANCHOR_LINE_RE='^[[:space:]]*(WORKER DONE|WORKER BLOCKED|VERIFIER PASS|VERIFIER FAIL) #[A-Za-z0-9_-]+'

# supervisor_read_anchor <worktree_dir> <anchor_relpath> <prompt_ts_file> <agent_name>
# Prints the harvested anchor line. Ignores the file when it is missing or its
# mtime is older than the marker that started the attempt; a missing file gets
# exactly one `herdr agent read` fallback. The marker file holds
# "<epoch-seconds[.fraction]> <nonce>": the nonce uniquifies each attempt and
# the sub-second precision is what rejects a stale anchor written back within
# the same 1-second mtime tick. Integer-only markers from older runs still
# parse.
supervisor_read_anchor() {
  local worktree_dir="$1"
  local anchor_relpath="$2"
  local prompt_ts_file="$3"
  local agent_name="$4"

  local anchor="$worktree_dir/$anchor_relpath"
  if [ -e "$anchor" ]; then
    resolve_python
    if ! "$PYTHON_BIN" - "$anchor" "$prompt_ts_file" <<'PY'
import os
import sys

try:
    anchor_mtime = os.stat(sys.argv[1]).st_mtime
except OSError:
    sys.exit(1)
try:
    marker = open(sys.argv[2]).read().split()[0]
    prompt_ts = float(marker)
except (OSError, IndexError, ValueError):
    prompt_ts = 0.0
sys.exit(0 if anchor_mtime >= prompt_ts else 1)
PY
    then
      return 1
    fi
    local line
    line="$(grep -E "$ANCHOR_LINE_RE" "$anchor" | tail -n 1 || true)"
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    return 1
  fi

  local recent line
  recent="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 40 2>/dev/null || true)"
  line="$(printf '%s\n' "$recent" | grep -E "$ANCHOR_LINE_RE" | tail -n 1 || true)"
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  return 1
}

# supervisor_needs_verifier <repo_dir> <base_ref> <sha> <verify_attr>
# Returns 0 when the verifier audit is mandatory: verify="asymmetric" or any
# changed path matches a TEST_GLOBS entry.
supervisor_needs_verifier() {
  local repo_dir="$1"
  local base_ref="$2"
  local sha="$3"
  local verify_attr="$4"

  if [ "$verify_attr" = "asymmetric" ]; then
    return 0
  fi

  local state_dir="$repo_dir/.agent-army"
  local globs=""
  if [ -f "$state_dir/profile.env" ]; then
    globs="$(/bin/bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${TEST_GLOBS:-}"' _ "$state_dir/profile.env")"
  fi
  [ -n "$globs" ] || globs="$DEFAULT_TEST_GLOBS"

  local paths
  paths="$(git -C "$repo_dir" diff --name-only "${base_ref}...${sha}" 2>/dev/null || true)"
  [ -n "$paths" ] || return 1

  resolve_python
  "$PYTHON_BIN" - "$globs" "$paths" <<'PY'
import fnmatch
import sys

globs = [g.strip() for g in sys.argv[1].split(",") if g.strip()]
paths = [p for p in sys.argv[2].splitlines() if p]
for path in paths:
    for glob in globs:
        base = glob.rstrip("/")
        if (
            fnmatch.fnmatch(path, glob)
            or fnmatch.fnmatch(path, base + "/*")
            or path.startswith(base + "/")
        ):
            sys.exit(0)
sys.exit(1)
PY
}

# supervisor_scan_secrets <repo_dir> <integration_ref> <sha>
# Walks every object introduced between the integration tip and <sha>
# (git rev-list --objects), filters to blobs, and blocks on secret-looking
# paths or blob content. Returns 20 on a hit, 0 when clean, and 21 (fail
# closed) when the range cannot be enumerated — a missing integration ref
# must never produce a vacuous clean verdict. grep -a keeps binary blobs
# from aborting the pipeline; greps live inside `if` so exit 1 (no match)
# never trips set -e.
supervisor_scan_secrets() {
  local repo_dir="$1"
  local integration_ref="$2"
  local sha="$3"

  local secret_regex='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}'

  # Fail closed: rev-list against an unresolvable ref errors into the void
  # and the walk below would pass vacuously, silently disabling the SECRET
  # boundary for every gated commit.
  if ! git -C "$repo_dir" rev-parse --verify --quiet "${integration_ref}^{commit}" >/dev/null 2>&1; then
    printf 'supervisor_scan_secrets: integration ref %s does not resolve\n' "$integration_ref" >&2
    return 21
  fi
  local objects rev_err rev_rc=0
  rev_err="$(mktemp "${TMPDIR:-/tmp}/army-scan-err.XXXXXX")"
  objects="$(git -C "$repo_dir" rev-list --objects "${integration_ref}..${sha}" 2>"$rev_err")" || rev_rc=$?
  if [ "$rev_rc" -ne 0 ]; then
    printf 'supervisor_scan_secrets: rev-list failed for %s..%s: %s\n' \
      "$integration_ref" "$sha" "$(tail -n 1 "$rev_err")" >&2
    rm -f "$rev_err"
    return 21
  fi
  rm -f "$rev_err"

  local line oid path objtype
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    oid="${line%% *}"
    path="${line#* }"
    if [ "$path" = "$line" ]; then
      path=""
    fi
    objtype="$(git -C "$repo_dir" cat-file -t "$oid" 2>/dev/null || true)"
    [ "$objtype" = "blob" ] || continue

    if [ -n "$path" ]; then
      case "$path" in
        .env.example|.env.sample|.env.template|*/.env.example|*/.env.sample|*/.env.template)
          ;;
        *)
          if printf '%s\n' "$path" | grep -qE '(^|/)\.env($|\.)'; then
            printf 'supervisor_scan_secrets: secret path %s\n' "$path" >&2
            return 20
          fi
          ;;
      esac
      if printf '%s\n' "$path" | grep -qE '\.pem$|\.key$'; then
        printf 'supervisor_scan_secrets: secret path %s\n' "$path" >&2
        return 20
      fi
    fi

    # No grep -q here: -q exits at the first match and SIGPIPEs cat-file once
    # the blob exceeds the pipe buffer, which fails OPEN under pipefail. A
    # plain grep with discarded stdout consumes the whole stream instead.
    if git -C "$repo_dir" cat-file -p "$oid" | grep -a -E -e "$secret_regex" >/dev/null; then
      printf 'supervisor_scan_secrets: secret pattern in blob %s (%s)\n' "$oid" "$path" >&2
      return 20
    fi
  done <<< "$objects"

  return 0
}

_supervisor_telemetry() {
  local repo_dir="$1"
  local event="$2"
  local seat="$3"
  local task_id="$4"
  local payload="${5:-{}}"
  resolve_python
  "$PYTHON_BIN" "$_SUP_DIR/telemetry.py" log "$repo_dir/.agent-army" "$event" "$seat" "$task_id" "$payload" >/dev/null 2>&1 || true
}

_supervisor_profile_test_cmd() {
  local repo_dir="$1"
  /bin/bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${TEST_CMD:-}"' _ "$repo_dir/.agent-army/profile.env"
}

_supervisor_render_verifier_brief() {
  local out_path="$1"
  local task_id="$2"
  local sha="$3"
  local base_ref="$4"
  cat > "$out_path" <<EOF
<verifier_brief id="$task_id" sha="$sha" base="$base_ref">
  <role title="Principal Adversarial Code &amp; Security Auditor">
    You roleplay a principal adversarial auditor. Your sole job is to find
    spec violations, regressions, unowned file touches, or security boundary
    leaks in commit $sha. You never implement fixes.
  </role>
  <objective>
    Audit commit $sha (base $base_ref). Inspect \`git diff $base_ref..$sha\`
    in this worktree. Assume guilt: check that every changed path stays inside
    the task's owns, nothing under .agent-army/ or .github/workflows/ changed,
    the done criteria hold, and no secret or remote mutation is introduced.
  </objective>
  <gates>
    <done_criteria>Exactly one verdict line is written to the anchor file.</done_criteria>
  </gates>
  <security_boundaries>
    STOP and emit VERIFIER FAIL when the commit itself crosses a boundary.
  </security_boundaries>
  <comms>
    Write exactly one line to .agent-army/anchors/$task_id.verify.txt in this worktree and print it:
    - VERIFIER PASS #$task_id $sha
    - VERIFIER FAIL #$task_id $sha &lt;one-line actionable defect&gt;
  </comms>
</verifier_brief>
EOF
}

_supervisor_render_repair_brief() {
  local out_path="$1"
  local task_id="$2"
  local seat="$3"
  local owns_csv="$4"
  local failure="$5"
  local gate_log="${6:-}"
  local original_brief="${7:-}"
  local read_csv="${8:-}"
  {
    printf '<task_brief id="%s" wave="repair" seat="%s" verify="none" repair="1">\n' "$task_id" "$seat"
    printf '  <role title="Repair Engineer">You are a focused repair engineer. Fix the failed gate without expanding scope.</role>\n'
    printf '  <objective>Task %s failed its gate: %s%s. Read the gate log, fix the root cause strictly inside owns, commit, and write the completion anchor.</objective>\n' \
      "$task_id" "$failure" "${gate_log:+ Gate log: $gate_log}"
    printf '  <scope>\n    <read>%s</read>\n    <owns>%s</owns>\n    <forbidden>Do not modify any file outside owns.</forbidden>\n  </scope>\n' \
      "${read_csv:-README.md}" "$owns_csv"
    printf '  <gates><done_criteria>The previously failing gate now passes.</done_criteria></gates>\n'
    printf '  <security_boundaries>STOP and emit WORKER BLOCKED on any boundary.</security_boundaries>\n'
    printf '  <prior_brief><![CDATA[\n%s\n]]></prior_brief>\n' "$original_brief"
    printf '  <comms>Write exactly one line to .agent-army/anchors/%s.txt: WORKER DONE #%s &lt;sha&gt; or WORKER BLOCKED #%s &lt;TYPE&gt; &lt;reason&gt;</comms>\n' \
      "$task_id" "$task_id" "$task_id"
    printf '</task_brief>\n'
  } > "$out_path"
}

# supervisor_gate_commit <repo_dir> <wave> <task_id> <seat> <sha> <base_ref> <owns_csv> <verify_attr> [enqueue_priority] [supersedes]
# Prints GREEN:<sha> (rc 0), RED:<reason> (rc 1), BLOCKED:<BOUNDARY>:<detail>
# (rc 2), or BUSY:enqueue (rc 3) when the arbiter lock stays busy past
# ARMY_ENQUEUE_WAIT_SEC and the caller should retry later.
supervisor_gate_commit() {
  local repo_dir="$1"
  local wave="$2"
  local task_id="$3"
  local seat="$4"
  local sha="$5"
  local base_ref="$6"
  local owns_csv="$7"
  local verify_attr="${8:-none}"
  local enqueue_priority="${9:-normal}"
  local supersedes="${10:-}"

  local state_dir="$repo_dir/.agent-army"
  local slug
  slug="$(state_read_slug "$repo_dir")"
  local seats_file="$state_dir/seats.json"
  local worktree_dir
  worktree_dir="$(jq -r --arg s "$seat" '.seats[$s].worktree_dir // empty' "$seats_file" 2>/dev/null || true)"
  if [ -z "$worktree_dir" ]; then
    printf 'RED:invalid_seat\n'
    return 1
  fi

  # 1. valid commit + zero worktree drift + owns coverage
  local objtype
  objtype="$(git -C "$repo_dir" cat-file -t "$sha" 2>/dev/null || true)"
  if [ "$objtype" != "commit" ]; then
    printf 'RED:invalid_sha\n'
    return 1
  fi
  local porcelain head_sha
  porcelain="$(git -C "$worktree_dir" status --porcelain)"
  head_sha="$(git -C "$worktree_dir" rev-parse HEAD)"
  if [ -n "$porcelain" ] || [ "$head_sha" != "$sha" ]; then
    printf 'RED:owns_or_drift\n'
    return 1
  fi
  if ! partition_check_diff_in_owns "$repo_dir" "$base_ref" "$sha" "$owns_csv" >/dev/null 2>&1; then
    printf 'RED:owns_or_drift\n'
    return 1
  fi

  # 2. workflow files are a GITHUB_MAIN boundary unless explicitly owned
  if ! printf ',%s,' "$owns_csv" | grep -qF ',.github/workflows,'; then
    # No grep -q on the git pipe: the path list can exceed the pipe buffer on
    # large diffs and SIGPIPE would fail this boundary check OPEN.
    if git -C "$repo_dir" diff --name-only "${base_ref}...${sha}" | grep -E '^\.github/workflows/' >/dev/null; then
      _supervisor_telemetry "$repo_dir" "task_blocked" "$seat" "$task_id" '{"boundary":"GITHUB_MAIN","reason":"workflow_touch"}'
      printf 'BLOCKED:GITHUB_MAIN:workflow_touch\n'
      return 2
    fi
  fi

  # 3. all-blob secret scan from the integration tip to the sha
  local scan_rc=0 scan_err
  # Must match _arbiter_ref's naming (refs/heads/army/<slug>/integration): a
  # mistyped ref makes rev-list fail silently and the scan pass vacuously.
  scan_err="$(supervisor_scan_secrets "$repo_dir" "refs/heads/army/$slug/integration" "$sha" 2>&1 >/dev/null)" || scan_rc=$?
  # Any non-zero scan result blocks: 20 is a hit, 21 means the range could
  # not be enumerated (missing ref) — a vacuous pass must never go GREEN.
  if [ "$scan_rc" -ne 0 ]; then
    _supervisor_telemetry "$repo_dir" "task_blocked" "$seat" "$task_id" "{\"boundary\":\"SECRET\",\"reason\":\"$(printf '%s' "$scan_err" | tail -n 1)\"}"
    printf 'BLOCKED:SECRET:%s\n' "$(printf '%s' "$scan_err" | tail -n 1)"
    return 2
  fi

  # 4. project TEST_CMD on the exact commit, one automatic flake rerun
  local profile_env="$state_dir/profile.env"
  local test_cmd
  test_cmd="$(_supervisor_profile_test_cmd "$repo_dir")"
  if [ -z "$test_cmd" ]; then
    printf 'RED:no_test_cmd\n'
    return 1
  fi
  local gate_timeout="${ARMY_TASK_TIMEOUT_SEC:-1800}"
  local gate_log_dir="$state_dir/gate-logs"
  mkdir -p "$gate_log_dir"
  local gate_rc=0 attempt=1
  if ! clean_gate_exec "$worktree_dir" "$profile_env" "$gate_timeout" "$test_cmd" > "$gate_log_dir/${task_id}-1.log" 2>&1; then
    attempt=2
    if ! clean_gate_exec "$worktree_dir" "$profile_env" "$gate_timeout" "$test_cmd" > "$gate_log_dir/${task_id}-2.log" 2>&1; then
      gate_rc=1
    fi
  fi
  if [ "$gate_rc" -ne 0 ]; then
    _supervisor_telemetry "$repo_dir" "gate_red" "$seat" "$task_id" "{\"sha\":\"$sha\",\"log\":\"$gate_log_dir/${task_id}-${attempt}.log\"}"
    printf 'RED:test_failed:%s\n' "$gate_log_dir/${task_id}-${attempt}.log"
    return 1
  fi

  # 5. mandatory verifier audit (asymmetric attr or test-file change)
  if supervisor_needs_verifier "$repo_dir" "$base_ref" "$sha" "$verify_attr"; then
    local vxml="$state_dir/briefs/${wave}-${task_id}-verify.xml"
    mkdir -p "$state_dir/briefs"
    _supervisor_render_verifier_brief "$vxml" "$task_id" "$sha" "$base_ref"
    # A transient verifier dispatch failure (e.g. herdr hiccup) must not
    # lose the fully gated GREEN commit: retry a bounded number of times,
    # then surface BUSY so the wave keeps the task active and re-gates on
    # the next poll instead of mislabeling it gate_protocol_error.
    local v_tries=0
    until briefs_dispatch_verifier "$repo_dir" "$wave" "$task_id" "$vxml"; do
      v_tries=$((v_tries + 1))
      if [ "$v_tries" -ge "${ARMY_VERIFIER_DISPATCH_TRIES:-3}" ]; then
        printf 'BUSY:verifier_dispatch\n'
        return 3
      fi
      sleep "${SUPERVISOR_POLL_SEC:-2}"
    done

    local v_wt v_ts v_deadline verdict=""
    v_wt="$(jq -r '.seats.verifier.worktree_dir // empty' "$seats_file")"
    v_ts="$v_wt/.agent-army/anchors/${task_id}.verify.prompt_ts"
    v_deadline=$(( $(date +%s) + ${SUPERVISOR_VERIFIER_TIMEOUT_SEC:-$gate_timeout} ))
    while [ "$(date +%s)" -lt "$v_deadline" ]; do
      if verdict="$(supervisor_read_anchor "$v_wt" ".agent-army/anchors/${task_id}.verify.txt" "$v_ts" "verifier-$slug")"; then
        break
      fi
      sleep "${SUPERVISOR_POLL_SEC:-2}"
    done
    briefs_clear_active_task "$v_wt"

    if [ -z "$verdict" ]; then
      _supervisor_telemetry "$repo_dir" "verifier_timeout" "verifier" "$task_id" "{\"sha\":\"$sha\"}"
      printf 'RED:verifier_timeout\n'
      return 1
    fi
    case "$verdict" in
      *'VERIFIER FAIL'*)
        local v_reason
        v_reason="$(printf '%s\n' "$verdict" | sed -nE 's/.*VERIFIER FAIL #[A-Za-z0-9_-]+ [0-9a-f]+ (.*)/\1/p')"
        [ -n "$v_reason" ] || v_reason="$(printf '%s' "$verdict" | tr -d '\n')"
        _supervisor_telemetry "$repo_dir" "verifier_fail" "verifier" "$task_id" "{\"sha\":\"$sha\",\"reason\":\"$v_reason\"}"
        printf 'RED:verifier_failed:%s\n' "$v_reason"
        return 1
        ;;
      *'VERIFIER PASS'*)
        _supervisor_telemetry "$repo_dir" "verifier_pass" "verifier" "$task_id" "{\"sha\":\"$sha\"}"
        ;;
      *)
        _supervisor_telemetry "$repo_dir" "verifier_invalid" "verifier" "$task_id" "{\"verdict\":\"$verdict\"}"
        printf 'RED:verifier_invalid\n'
        return 1
        ;;
    esac
  fi

  # 6. enqueue + GREEN. A lock-busy enqueue (e.g. a manual `arbiter drain`
  # holding the arbiter lock through a long combined gate) must not destroy a
  # fully gated GREEN commit: retry inside a bounded window, then surface
  # BUSY:enqueue so the wave keeps the task active and retries on the next
  # poll instead of mislabeling it gate_protocol_error and recycling the seat.
  _supervisor_telemetry "$repo_dir" "gate_pass" "$seat" "$task_id" "{\"sha\":\"$sha\",\"wave\":\"$wave\"}"
  local enq_deadline=$(( $(date +%s) + ${ARMY_ENQUEUE_WAIT_SEC:-120} ))
  while ! arbiter_enqueue "$repo_dir" "$task_id" "$seat" "$sha" "$enqueue_priority" "$supersedes"; do
    if [ "$(date +%s)" -ge "$enq_deadline" ]; then
      printf 'BUSY:enqueue\n'
      return 3
    fi
    sleep "${SUPERVISOR_POLL_SEC:-2}"
  done
  printf 'GREEN:%s\n' "$sha"
  return 0
}

# --- wave supervision -------------------------------------------------------

_sup_state_file() {
  printf '%s/%s.state.json' "$1" "$2"
}

_sup_get() {
  jq -r --arg k "$2" '.[$k] // ""' "$(_sup_state_file "$1" "$3")" 2>/dev/null || true
}

_sup_set() {
  local f
  f="$(_sup_state_file "$1" "$4")"
  local tmp="$f.tmp.$$"
  jq --arg k "$2" --argjson v "$3" '.[$k] = $v' "$f" > "$tmp"
  mv "$tmp" "$f"
}

_sup_set_str() {
  local f
  f="$(_sup_state_file "$1" "$4")"
  local tmp="$f.tmp.$$"
  jq --arg k "$2" --arg v "$3" '.[$k] = $v' "$f" > "$tmp"
  mv "$tmp" "$f"
}

_sup_terminal() {
  local repo_dir="$1" run_dir="$2" task_id="$3" status="$4" boundary="$5" reason="$6" snapshot="${7:-}"
  _sup_set_str "$run_dir" "status" "$status" "$task_id"
  _sup_set_str "$run_dir" "boundary" "$boundary" "$task_id"
  _sup_set_str "$run_dir" "reason" "$reason" "$task_id"
  if [ -n "$snapshot" ]; then
    _sup_set_str "$run_dir" "snapshot" "$snapshot" "$task_id"
  fi
  local seat
  seat="$(_sup_get "$run_dir" "seat" "$task_id")"
  _supervisor_telemetry "$repo_dir" "task_$status" "$seat" "$task_id" "{\"boundary\":\"$boundary\",\"reason\":\"$reason\"}"
  partition_release_task "$repo_dir" "$task_id" >/dev/null 2>&1 || true
  local wt
  wt="$(jq -r --arg s "$seat" '.seats[$s].worktree_dir // empty' "$repo_dir/.agent-army/seats.json" 2>/dev/null || true)"
  if [ -n "$wt" ]; then
    briefs_clear_active_task "$wt"
    # Recycle the seat so a terminal RED/BLOCKED cannot poison later waves:
    # snapshot any dirt, then hard-reset the seat branch to the integration
    # tip. Without this the failed attempt's commit stays on the seat branch,
    # gets rebased onto the next promote, and makes every later task on the
    # seat fail partition_check_diff_in_owns with RED:owns_or_drift; a dirty
    # seat would likewise make every later worktree_sync_pool (and therefore
    # arbiter_promote) fail.
    local slug tip
    slug="$(state_read_slug "$repo_dir")"
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/army/$slug/integration"; then
      tip="refs/heads/army/$slug/integration"
    else
      tip="HEAD"
    fi
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
      local recycle_snapshot
      recycle_snapshot="$(worktree_snapshot "$repo_dir" "$seat" 2>/dev/null || true)"
      if [ -n "$recycle_snapshot" ] && [ -z "$snapshot" ]; then
        _sup_set_str "$run_dir" "snapshot" "$recycle_snapshot" "$task_id"
      fi
    fi
    git -C "$wt" reset --hard "$(git -C "$repo_dir" rev-parse "$tip")" >/dev/null 2>&1 || true
  fi
}

_supervisor_step_task() {
  local repo_dir="$1"
  local run_dir="$2"
  local task_id="$3"
  local max_repairs="$4"
  local task_timeout="$5"

  local slug seat worktree_dir agent
  slug="$(state_read_slug "$repo_dir")"
  seat="$(_sup_get "$run_dir" "seat" "$task_id")"
  local seats_file="$repo_dir/.agent-army/seats.json"
  worktree_dir="$(jq -r --arg s "$seat" '.seats[$s].worktree_dir // empty' "$seats_file" 2>/dev/null || true)"
  agent="$(jq -r --arg s "$seat" '.seats[$s].agent_name // empty' "$seats_file" 2>/dev/null || true)"
  if [ -z "$worktree_dir" ] || [ -z "$agent" ]; then
    _sup_terminal "$repo_dir" "$run_dir" "$task_id" "red" "" "invalid_seat"
    return 0
  fi

  # Herdr-reported AUTH boundary (trust dialogs, permission prompts).
  local astat
  astat="$(herdr agent get "$agent" 2>/dev/null | herdr_agent_status_json)"
  if [ "$astat" = "blocked" ]; then
    _sup_terminal "$repo_dir" "$run_dir" "$task_id" "blocked" "AUTH" "herdr_agent_blocked"
    return 0
  fi

  local anchor_rel=".agent-army/anchors/${task_id}.txt"
  local ts_file="$worktree_dir/.agent-army/anchors/${task_id}.prompt_ts"
  local line=""
  if line="$(supervisor_read_anchor "$worktree_dir" "$anchor_rel" "$ts_file" "$agent")"; then
    local anchor_id
    anchor_id="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*(WORKER DONE|WORKER BLOCKED|VERIFIER PASS|VERIFIER FAIL) #([A-Za-z0-9_-]+).*/\2/p')"
    if [ "$anchor_id" != "$task_id" ]; then
      line=""
    fi
  fi

  if printf '%s\n' "$line" | grep -qE '^[[:space:]]*WORKER BLOCKED #'; then
    local boundary reason
    boundary="$(printf '%s\n' "$line" | sed -nE 's/.*WORKER BLOCKED #[A-Za-z0-9_-]+ ([A-Z_]+).*/\1/p')"
    reason="$(printf '%s\n' "$line" | sed -nE 's/.*WORKER BLOCKED #[A-Za-z0-9_-]+ [A-Z_]+ (.*)/\1/p')"
    _sup_terminal "$repo_dir" "$run_dir" "$task_id" "blocked" "${boundary:-UNKNOWN}" "${reason:-worker_blocked}"
    return 0
  fi

  if printf '%s\n' "$line" | grep -qE '^[[:space:]]*WORKER DONE #'; then
    local sha wave owns verify
    sha="$(printf '%s\n' "$line" | awk '{print $4}')"
    wave="$(_sup_get "$run_dir" "wave" "$task_id")"
    owns="$(_sup_get "$run_dir" "owns" "$task_id")"
    verify="$(_sup_get "$run_dir" "verify" "$task_id")"
    local prio sup
    prio="$(_sup_get "$run_dir" "enqueue_priority" "$task_id")"
    sup="$(_sup_get "$run_dir" "supersedes" "$task_id")"
    [ -n "$prio" ] || prio="normal"
    local gate_out gate_rc=0
    gate_out="$(supervisor_gate_commit "$repo_dir" "$wave" "$task_id" "$seat" "$sha" "$(_sup_get "$run_dir" "base_ref" "$task_id")" "$owns" "$verify" "$prio" "$sup")" || gate_rc=$?
    case "$gate_out" in
      GREEN:*)
        _sup_set_str "$run_dir" "sha" "$sha" "$task_id"
        _sup_set_str "$run_dir" "status" "green" "$task_id"
        briefs_clear_active_task "$worktree_dir"
        return 0
        ;;
      BLOCKED:*)
        local boundary2 detail
        boundary2="${gate_out#BLOCKED:}"
        boundary2="${boundary2%%:*}"
        detail="${gate_out#BLOCKED:*:}"
        _sup_terminal "$repo_dir" "$run_dir" "$task_id" "blocked" "$boundary2" "$detail"
        return 0
        ;;
      BUSY:*)
        # The arbiter lock is held (manual drain mid-gate: BUSY:enqueue) or
        # the verifier dispatch kept failing (BUSY:verifier_dispatch). Keep
        # the task active: the anchor and gate result stay valid, the next
        # poll re-runs the gate and retries once the transient clears.
        _supervisor_telemetry "$repo_dir" "enqueue_busy" "$seat" "$task_id" "{\"sha\":\"$sha\"}"
        return 0
        ;;
      RED:*)
        local repairs
        repairs="$(_sup_get "$run_dir" "repairs_used" "$task_id")"
        case "$repairs" in ''|*[!0-9]*) repairs=0 ;; esac
        if [ "$repairs" -lt "$max_repairs" ]; then
          repairs=$((repairs + 1))
          _sup_set "$run_dir" "repairs_used" "$repairs" "$task_id"
          local state_dir="$repo_dir/.agent-army"
          mkdir -p "$state_dir/briefs"
          local repair_xml="$state_dir/briefs/${wave}-${task_id}-repair${repairs}.xml"
          local original_brief
          original_brief="$(cat "$(_sup_get "$run_dir" 'brief' "$task_id")" 2>/dev/null || true)"
          local failure="${gate_out#RED:}"
          local gate_log="${failure#test_failed:}"
          [ "$gate_log" != "$failure" ] || gate_log=""
          _supervisor_render_repair_brief "$repair_xml" "$task_id" "$seat" "$owns" "$failure" "$gate_log" "$original_brief" ""
          _supervisor_telemetry "$repo_dir" "repair_dispatched" "$seat" "$task_id" "{\"attempt\":\"$repairs\",\"failure\":\"$failure\"}"
          briefs_dispatch_task "$repo_dir" "$seat" "$wave" "$task_id" "$repair_xml"
          return 0
        fi
        _sup_terminal "$repo_dir" "$run_dir" "$task_id" "red" "" "${gate_out#RED:}"
        return 0
        ;;
      *)
        _sup_terminal "$repo_dir" "$run_dir" "$task_id" "red" "" "gate_protocol_error: $gate_out"
        return 0
        ;;
    esac
  fi

  # Task clock expiry: one re-dispatch, then BLOCKED with a snapshot.
  if [ -f "$ts_file" ]; then
    local now ts
    now="$(date +%s)"
    # Marker is "<epoch[.frac]> <nonce>"; the clock only needs whole seconds.
    ts="$(cat "$ts_file" 2>/dev/null || printf '0')"
    ts="${ts%% *}"
    ts="${ts%%.*}"
    case "$ts" in
      ''|*[!0-9]*) return 0 ;;
    esac
    if [ $((now - ts)) -gt "$task_timeout" ]; then
      local timeouts snapshot
      timeouts="$(_sup_get "$run_dir" "timeouts_used" "$task_id")"
      case "$timeouts" in ''|*[!0-9]*) timeouts=0 ;; esac
      snapshot="$(worktree_snapshot "$repo_dir" "$seat")"
      if [ "$timeouts" = "0" ]; then
        _sup_set "$run_dir" "timeouts_used" 1 "$task_id"
        _supervisor_telemetry "$repo_dir" "timeout_redispatch" "$seat" "$task_id" "{\"snapshot\":\"$snapshot\"}"
        briefs_dispatch_task "$repo_dir" "$seat" "$(_sup_get "$run_dir" "wave" "$task_id")" "$task_id" "$(_sup_get "$run_dir" "brief" "$task_id")"
      else
        _sup_terminal "$repo_dir" "$run_dir" "$task_id" "blocked" "TIMEOUT" "task clock expired twice" "$snapshot"
      fi
    fi
  fi
  return 0
}

# supervisor_supervise_wave <repo_dir> <manifest_path>
# Polls every dispatched task until GREEN/RED/BLOCKED and prints a JSON wave
# receipt {wave, tasks: {id: {status, sha, boundary, reason, snapshot}}}.
supervisor_supervise_wave() {
  local repo_dir="$1"
  local manifest_path="$2"
  repo_dir="$(cd "$repo_dir" && pwd -P)"

  resolve_python
  local run_dir
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/army-supervise.XXXXXX")"

  "$PYTHON_BIN" - "$manifest_path" "$run_dir" <<'PY'
import json
import os
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
run_dir = sys.argv[2]
for task in manifest.get("tasks", []):
    state = {
        "id": task["id"],
        "seat": task.get("seat", ""),
        "wave": str(manifest.get("wave", "")),
        "owns": ",".join(task.get("owns") or []),
        "verify": task.get("verify", "none"),
        "brief": task.get("brief", ""),
        "base_ref": task.get("base_ref", ""),
        "enqueue_priority": task.get("enqueue_priority", "normal") or "normal",
        "supersedes": task.get("supersedes", "") or "",
        "status": "active",
        "sha": "",
        "repairs_used": 0,
        "timeouts_used": 0,
        "boundary": "",
        "reason": "",
        "snapshot": "",
    }
    with open(os.path.join(run_dir, "%s.state.json" % task["id"]), "w", encoding="utf-8") as f:
        json.dump(state, f)
PY

  local poll="${SUPERVISOR_POLL_SEC:-2}"
  local max_repairs="${ARMY_MAX_REPAIRS_PER_TASK:-1}"
  local task_timeout="${ARMY_TASK_TIMEOUT_SEC:-1800}"

  local active=1
  while [ "$active" -eq 1 ]; do
    active=0
    local st_file task_id status
    for st_file in "$run_dir"/*.state.json; do
      [ -e "$st_file" ] || continue
      task_id="$(jq -r '.id' "$st_file")"
      status="$(jq -r '.status' "$st_file")"
      if [ "$status" != "active" ]; then
        continue
      fi
      active=1
      _supervisor_step_task "$repo_dir" "$run_dir" "$task_id" "$max_repairs" "$task_timeout" || true
    done
    if [ "$active" -eq 1 ]; then
      sleep "$poll"
    fi
  done

  "$PYTHON_BIN" - "$run_dir" <<'PY'
import glob
import json
import os
import sys

run_dir = sys.argv[1]
receipt = {"tasks": {}}
wave = None
for path in sorted(glob.glob(os.path.join(run_dir, "*.state.json"))):
    with open(path, encoding="utf-8") as f:
        state = json.load(f)
    try:
        wave = int(state.get("wave") or wave)
    except (TypeError, ValueError):
        pass
    receipt["tasks"][state["id"]] = {
        "status": state["status"].upper(),
        "sha": state.get("sha", ""),
        "boundary": state.get("boundary", ""),
        "reason": state.get("reason", ""),
        "snapshot": state.get("snapshot", ""),
        "repairs_used": state.get("repairs_used", 0),
    }
receipt["wave"] = wave
print(json.dumps(receipt, sort_keys=True))
PY

  rm -rf "$run_dir"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    wave)
      shift
      supervisor_supervise_wave "$@"
      ;;
    gate)
      shift
      supervisor_gate_commit "$@"
      ;;
    scan-secrets)
      shift
      supervisor_scan_secrets "$@"
      ;;
    needs-verifier)
      shift
      supervisor_needs_verifier "$@"
      ;;
    read-anchor)
      shift
      supervisor_read_anchor "$@"
      ;;
    *)
      echo "Usage: supervisor.sh {wave|gate|scan-secrets|needs-verifier|read-anchor} <args>" >&2
      exit 1
      ;;
  esac
fi
