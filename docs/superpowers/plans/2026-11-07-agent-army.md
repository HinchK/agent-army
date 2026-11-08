# Agent-Army Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the self-contained `agent-army` orchestrator (`bin/army`, `lib/*.sh`, `lib/commander.py`) that pairs a shell-less out-of-swarm Commander (`pi` or `opencode`) with a standing Herdr worktree swarm (`worker-1..N`, `verifier`), mechanical exact-SHA test and secret gates, automatic wave `drain`/`promote`, and fail-closed security boundary halts.

**Architecture:** `agent-army` adapts Stampede's battle-tested Git worktree, partition lease, and CAS arbiter primitives into `lib/*.sh` while removing in-swarm `looper`/`pm` middlemen and the `ops` pane. An external Python controller (`lib/commander.py`) holds an exclusive `fcntl` lock on `.agent-army/army.lock`, wakes a tool-restricted `pi` or `opencode` Commander session to emit `<commander_decision>` XML blocks, dispatches at most one LARP XML task per worker seat on fresh Herdr agent sessions, gates commits under `env -i` (`CI=true`) with mandatory verifier audits on test changes and full-blob-range secret scans, and mechanically drains and promotes GREEN waves into local `main` before waking the Commander again.

**Tech Stack:** Bash 3.2+ (`set -euo pipefail`, ShellCheck clean), Python 3.11+ (`tomllib`, `fcntl`, `xml.etree.ElementTree`, `unittest`), `git`, `jq`, `gh`, `herdr`, `pi`, `opencode`.

**Spec:** `docs/superpowers/specs/2026-11-07-agent-army-design.md`

## Global Constraints

- macOS and Linux compatible; shell scripts must run under `/bin/bash` (Bash 3.2 compatibility floor, `set -euo pipefail`, 0 ShellCheck warnings).
- Python 3.11+ with `tomllib` (resolved via `lib/pyenv.sh`), `jq`, `git`, `gh`, `timeout(1)` (or `gtimeout`/Python fallback), `herdr`, and `pi` or `opencode`.
- The Commander process runs with `HERDR_PANE_ID` and `HERDR_ENV` unset (or explicitly stripped in the Commander subshell) so it never occupies a worker pane.
- The Commander agent has no shell, no edit, and no write. `commander.py` parses one `<commander_decision>` block and ignores every other line of model output. It never passes model text to a shell.
- `pi` starts with `--no-tools --no-context-files`. `opencode` starts with `--agent commander` (read allowed; bash, shell, edit, and write denied) and `OPENCODE_CONFIG_PROJECT_DISABLE=1`.
- Worker and verifier processes are started without `GITHUB_TOKEN`, `GH_TOKEN`, and `AWS_*`, and with `AWS_SHARED_CREDENTIALS_FILE`, `GOOGLE_APPLICATION_CREDENTIALS`, and `CLOUDSDK_CONFIG` pointed at a missing path.
- Before `worktree_provision`, append `.agent-army/` to the target repo's `.git/info/exclude` if that line is absent. The supervisor rejects any worker commit that touches `.agent-army/`.
- Isolated seats (`worker-1..N`, `verifier`) must always execute in exact order: `exclude .agent-army/` $\rightarrow$ `worktree_provision` $\rightarrow$ `herdr pane split --cwd <worktree_dir> --no-focus` $\rightarrow$ `herdr agent start <seat>-<slug> --kind <kind> --pane <pane_id>` $\rightarrow$ atomic record in `.agent-army/seats.json`.
- Every `TEST_CMD` (the per-commit supervisor gate, the arbiter's combined-tree gate, and the final `MISSION_COMPLETE` gate) runs under `env -i` with `PATH`, `HOME`, `CI=true`, and the toolchain variables the target profile names (`HERDR_*`, `REPO_DIR`, and `STATE_DIR` are never passed through).
- A lock holder whose pid is dead, or whose `ps -o state=` value starts with `T` (stopped, including `T`, `TN`, and `T+`), is stale and is reaped.
- Preflight reads `[army].name` once, runs `slugify()` on it, and stores the result in `.agent-army/state.json` as `slug`. Every ref, seat name, and branch reads that field.
- `army run` takes an exclusive `fcntl` lock on `.agent-army/army.lock` before any other work and exits immediately if the lock is already held.
- `state.json` keeps `zero_integrate_waves`. When it reaches 2, `commander.py` writes `.agent-army/handoff.md` and exits `MISSION_BLOCKED` (`exit 20`).
- `.agent-army/handoff.md` (lowercase) is the only handoff filename. No `ops` pane and no ANSI telemetry stream exist; `telemetry.py` only appends JSONL to `.agent-army/session-verdicts.jsonl`.

## Review Focus

1. **Commander stdout wrapping or multiple `<commander_decision>` blocks:** `parse_decision_xml` in `lib/commander.py` must extract a single `<commander_decision>` block when surrounded by prose or markdown code fences, and raise `DecisionParseError` if stdout contains zero or more than one `<commander_decision>` block (tested in Task 6 `test_parse_decision_xml_fences_and_multiple_blocks`).
2. **Prefix-boundary collisions and traversal in `owns:` paths:** A task owning `src/auth` must not match `src/auth_v2/token.py`, and `owns:` entries containing `..`, leading `/`, or `.agent-army` must be rejected fail-closed (tested in Task 2 `test_partition_leases.sh` and Task 4 `test_supervisor_verifier.sh`).
3. **Non-blob objects and binary blobs in `git rev-list --objects <integration>..<sha>` secret scan:** `supervisor_scan_secrets` must filter to `blob` objects only (skipping commit/tree OIDs) and scan binary blobs with `grep -a` without aborting under `set -euo pipefail` when a clean blob exits 1 (tested in Task 4 `test_security_boundaries.sh`).
4. **Same-second filesystem mtime race on anchor files:** `briefs.sh` deletes the old anchor file and records an epoch timestamp + nonce marker before prompting, and `supervisor_read_anchor` rejects any anchor file older than that marker so stale anchors cannot be re-harvested within the same 1-second mtime tick (tested in Task 4 `test_supervisor_verifier.sh`).
5. **Human commits on local `main` before `army resume`:** When a human resolves a `MISSION_BLOCKED` boundary by committing directly on `main` and runs `army resume`, `commander.py` must fast-forward `refs/heads/army/<slug>/integration` and idle worker/verifier worktrees to the new `main` HEAD and reset `zero_integrate_waves` to `0` (tested in Task 6 `test_resume_advances_integration_ref_after_human_commit`).

---

### Task 1: Foundation — Config, Single-Slug State, Profile, Clean Gate Exec & JSONL Telemetry

**Files:**
- Create: `Makefile`
- Create: `army.config.toml.example`
- Create: `lib/pyenv.sh`
- Create: `lib/common.sh`
- Create: `lib/config.sh`
- Create: `lib/profile.sh`
- Create: `lib/preflight.sh`
- Create: `lib/telemetry.py`
- Test: `tests/test_config_profile.sh`
- Test: `tests/test_preflight.sh`

**Interfaces:**
- Consumes: Target Git repository directory and `<repo>/army.config.toml`.
- Produces:
  - `lib/pyenv.sh`: `resolve_python` (sets `PYTHON_BIN` to a Python 3.11+ interpreter with `tomllib`).
  - `lib/common.sh`:
    - `slugify <string>` $\rightarrow$ prints normalized `[a-z][a-z0-9_-]*` slug.
    - `state_init_slug <repo_dir> <army_name>` $\rightarrow$ creates `<repo_dir>/.agent-army/state.json` with `slug`, `zero_integrate_waves: 0`, `status: "idle"` if `.slug` is not yet set; echoes `slug`.
    - `state_read_slug <repo_dir>` $\rightarrow$ reads `.slug` from `<repo_dir>/.agent-army/state.json` (fails if missing).
    - `ensure_git_exclude <repo_dir>` $\rightarrow$ appends `.agent-army/` to `$(git -C "$repo_dir" rev-parse --git-common-dir)/info/exclude` if absent.
    - `clean_gate_exec <cwd> <profile_env_file> <timeout_sec> <test_cmd>` $\rightarrow$ executes `<test_cmd>` in `<cwd>` under `env -i PATH="$PATH" HOME="$HOME" CI=true TMPDIR="<state_dir>/gate-tmp"` plus any `TOOLCHAIN_VARS` exported by `<profile_env_file>`, with `HERDR_*`, `REPO_DIR`, `STATE_DIR` absent.
    - `find_workspace_by_cwd <repo_dir>` $\rightarrow$ queries `herdr workspace list` / `herdr pane list` and prints the workspace ID whose physical CWD matches `$(cd "$repo_dir" && pwd -P)`.
  - `lib/config.sh`: `config_dump <toml_path>` $\rightarrow$ outputs `shlex.quote`d `export ARMY_NAME=...`, `export ARMY_BASE_BRANCH=...`, `export ARMY_MAX_WAVES=...`, `export ARMY_MAX_REPAIRS_PER_TASK=...`, `export ARMY_TASK_TIMEOUT_SEC=...`, `export ARMY_CREATE_DRAFT_PR=...`, `export COMMANDER_HARNESS=...`, `export COMMANDER_MODEL=...`, `export COMMANDER_THINKING=...`, `export COMMANDER_TIMEOUT_SEC=...`, `export SEAT_IDS="worker_1 worker_2 verifier"`, and per-seat `export SEAT_<UPPER_ID>_KIND/MODEL/ROLE/WORKTREE/CRITICAL=...`.
  - `lib/profile.sh`: `profile_ensure <repo_dir>` and `test_cmd_is_runnable <cmd>` $\rightarrow$ writes `<repo_dir>/.agent-army/profile.env` containing `TEST_CMD`, `TEST_GLOBS` (default `test/**,tests/**,__tests__/**,test_*,*_test.*,*.test.*,*_spec.*`), and `TOOLCHAIN_VARS`. Rejects `""`, `none`, `true`.
  - `lib/preflight.sh`: `preflight_check <repo_dir> <config_path>` $\rightarrow$ validates dependencies, runnable `TEST_CMD`, clean root checkout on `ARMY_BASE_BRANCH`, calls `ensure_git_exclude` and `state_init_slug`.
  - `lib/telemetry.py`: `python3 lib/telemetry.py log <state_dir> <event> <seat> <task_id> <payload_json>` $\rightarrow$ appends `{ts, event, seat, task_id, payload}` to `<state_dir>/session-verdicts.jsonl`.

- [ ] **Step 1: Write the failing tests in `tests/test_config_profile.sh` and `tests/test_preflight.sh`**

```bash
# tests/test_config_profile.sh assertions:
# 1. state_init_slug writes .agent-army/state.json with slug="my-project" from [army].name="My Project!"
#    and a second call with a different name still returns "my-project" (single-slug invariant).
# 2. ensure_git_exclude writes ".agent-army/" to .git/info/exclude idempotently and git status --porcelain
#    remains empty when files are created inside .agent-army/.
# 3. test_cmd_is_runnable rejects "", "none", "true" (exit 1) and accepts "pytest" (exit 0).
# 4. clean_gate_exec runs with CI=true and strips HERDR_PANE_ID, HERDR_ENV, REPO_DIR, STATE_DIR:
#    HERDR_PANE_ID=w1:p1 CI=false clean_gate_exec "$repo" "$profile" 10 \
#      'test "$CI" = "true" && test -z "${HERDR_PANE_ID:-}" && test -z "${REPO_DIR:-}"'

# tests/test_preflight.sh assertions:
# 1. preflight_check succeeds on a clean git repo on main with runnable TEST_CMD and mocked herdr/pi on PATH.
# 2. preflight_check fails closed (exit 1) if working tree has uncommitted tracked changes or wrong branch.
# 3. telemetry.py log appends valid JSONL to .agent-army/session-verdicts.jsonl with no stdout/ANSI output.
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/bin/bash tests/test_config_profile.sh && /bin/bash tests/test_preflight.sh`
Expected: FAIL (`lib/common.sh: No such file or directory`)

- [ ] **Step 3: Implement `Makefile`, `army.config.toml.example`, `lib/pyenv.sh`, `lib/common.sh`, `lib/config.sh`, `lib/profile.sh`, `lib/preflight.sh`, and `lib/telemetry.py`**

Implement the exact functions and CLI contracts specified in **Interfaces** above. In `clean_gate_exec`, resolve `timeout` (`timeout`, `gtimeout`, or `$PYTHON_BIN -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[2:], timeout=int(sys.argv[1])).returncode)'`) so macOS hosts without GNU coreutils `timeout(1)` still enforce gate timeouts cleanly.

- [ ] **Step 4: Run tests and lint to verify they pass**

Run: `make check`
Expected: PASS (`test_config_profile.sh` and `test_preflight.sh` exit 0, `shellcheck` 0 warnings)

- [ ] **Step 5: Commit**

```bash
git add Makefile army.config.toml.example lib/pyenv.sh lib/common.sh lib/config.sh lib/profile.sh lib/preflight.sh lib/telemetry.py tests/test_config_profile.sh tests/test_preflight.sh
git commit -m "feat: add config, single-slug state, profile, clean gate exec, and telemetry"
```

---

### Task 2: Worktree Lifecycle, Pool Base-Sync & Partition Lease Engine

**Files:**
- Create: `lib/worktree.sh`
- Create: `lib/partition.sh`
- Test: `tests/test_worktree_sync.sh`
- Test: `tests/test_partition_leases.sh`

**Interfaces:**
- Consumes: `state_read_slug`, `ensure_git_exclude` from `lib/common.sh`; `PYTHON_BIN` from `lib/pyenv.sh`.
- Produces:
  - `lib/worktree.sh`:
    - `worktree_provision <repo_dir> <seat> [base_ref]` $\rightarrow$ calls `ensure_git_exclude`, provisions `<repo_dir>/.agent-army/worktrees/<seat>` on branch `army/<slug>/<seat>` at `<base_ref>` (default `HEAD`), creates `<worktree>/.agent-army/briefs` and `<worktree>/.agent-army/anchors`, prints physical worktree path.
    - `worktree_snapshot <repo_dir> <seat>` $\rightarrow$ copies `git status --porcelain`, `git diff HEAD`, and untracked files (excluding `.agent-army/`) into `<repo_dir>/.agent-army/snapshots/<epoch>-<pid>/<seat>/`, prints snapshot path.
    - `worktree_sync_pool <repo_dir> <target_ref> [busy_seats_csv]` $\rightarrow$ iterates over `<repo_dir>/.agent-army/worktrees/*` (skipping `arbiter-*` and seats in `busy_seats_csv`); fails if any idle worktree has non-empty `git status --porcelain`; otherwise resets branch `army/<slug>/<seat>` to `<target_ref>`.
    - `worktree_teardown <repo_dir> <seat>` $\rightarrow$ snapshots if dirty, then removes worktree.
  - `lib/partition.sh`:
    - `partition_validate_paths <owns_csv>` $\rightarrow$ exits 1 on empty string, `..` path segment, leading `/`, or `.agent-army` path.
    - `partition_paths_overlap <path_a> <path_b>` $\rightarrow$ exits 0 if identical or one is a directory prefix of the other (`a == b` or `a` starts with `b/` or `b` starts with `a/`); exits 1 otherwise.
    - `partition_acquire_wave <repo_dir> <wave_tasks_json>` $\rightarrow$ takes `[ { "id": "W1-T1", "seat": "worker_1", "owns": ["src/a.py"] }, ... ]`, validates paths, checks pairwise disjointness across the wave and against `<repo_dir>/.agent-army/leases.json`, and atomically writes all new leases or exits 1 leaving `leases.json` unchanged.
    - `partition_release_task <repo_dir> <task_id>` $\rightarrow$ deletes `<task_id>` from `<repo_dir>/.agent-army/leases.json`.
    - `partition_reassign_lease <repo_dir> <old_task_id> <new_task_id> <seat> <owns_csv>` $\rightarrow$ atomically replaces `<old_task_id>` with `<new_task_id>` holding `<owns_csv>` in `leases.json` (used for conflict/integration_red resolution tasks).
    - `partition_check_diff_in_owns <repo_dir> <base_ref> <sha> <owns_csv>` $\rightarrow$ inspects `git -C "$repo_dir" diff --name-only "${base_ref}...${sha}"`; exits 1 if the diff is empty, touches `.agent-army/`, or modifies any path not covered by `<owns_csv>`.

- [ ] **Step 1: Write the failing tests in `tests/test_worktree_sync.sh` and `tests/test_partition_leases.sh`**

```bash
# tests/test_worktree_sync.sh assertions:
# 1. worktree_provision creates .agent-army/worktrees/worker_1 on branch army/<slug>/worker_1,
#    and writing .agent-army/anchors/W1-T1.txt inside that worktree leaves git status --porcelain empty.
# 2. After a new commit lands on main, worktree_sync_pool advances idle worker_1 and verifier worktrees
#    to main HEAD while skipping a seat listed in busy_seats_csv.
# 3. worktree_snapshot captures uncommitted diff and untracked files to .agent-army/snapshots/<ts>/worker_1/.

# tests/test_partition_leases.sh assertions:
# 1. partition_paths_overlap treats "src/auth" and "src/auth/token.py" as overlapping (exit 0),
#    but "src/auth" and "src/auth_v2/token.py" as disjoint (exit 1) [Review Focus #2].
# 2. partition_validate_paths rejects "../secret.txt", "/etc/passwd", and ".agent-army/state.json".
# 3. partition_acquire_wave rejects a wave with overlapping owns and leaves leases.json unmodified.
# 4. partition_check_diff_in_owns passes when commit only edits owned paths and fails when commit
#    touches an unowned file or .agent-army/foo.
# 5. partition_reassign_lease transfers a held lease from #W1-T1 to #W2-RESOLVE-W1-T1.
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/bin/bash tests/test_worktree_sync.sh && /bin/bash tests/test_partition_leases.sh`
Expected: FAIL (`lib/worktree.sh: No such file or directory`)

- [ ] **Step 3: Implement `lib/worktree.sh` and `lib/partition.sh`**

Implement `lib/worktree.sh` and `lib/partition.sh` with the exact functions in **Interfaces**. Use a directory lock (`.agent-army/leases.lock`) around `leases.json` read-modify-write operations.

- [ ] **Step 4: Run tests and lint to verify they pass**

Run: `make check`
Expected: PASS (all suites green, 0 ShellCheck warnings)

- [ ] **Step 5: Commit**

```bash
git add lib/worktree.sh lib/partition.sh tests/test_worktree_sync.sh tests/test_partition_leases.sh
git commit -m "feat: add worktree provisioning, pool base-sync, and partition lease engine"
```

---

### Task 3: Credential-Free Herdr Seat Lifecycle & File-Path Brief Dispatcher

**Files:**
- Create: `briefs/worker.in.md`
- Create: `briefs/verifier.in.md`
- Create: `lib/providers.sh`
- Create: `lib/briefs.sh`
- Create: `lib/lifecycle.sh`
- Modify: `tests/test_worktree_sync.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `lib/config.sh`, `lib/worktree.sh`.
- Produces:
  - `lib/providers.sh`:
    - `providers_prepare_seat <worktree_dir> <kind> <model>` $\rightarrow$ when `<kind>` is `opencode`, writes `<worktree_dir>/.opencode/opencode.json` pinning `"model": "<model>"`.
    - `providers_start_fresh_session <repo_dir> <seat> <pane_id> <kind> <model>` $\rightarrow$ interrupts any active agent process on `<pane_id>` (`herdr agent send-keys <pane_id> ctrl+c` / `herdr pane run <pane_id> "exit"` if needed until shell prompt is ready, or uses `herdr agent start` with `env -u GITHUB_TOKEN -u GH_TOKEN -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE=/nonexistent GOOGLE_APPLICATION_CREDENTIALS=/nonexistent CLOUDSDK_CONFIG=/nonexistent`), starting `<seat>-<slug>` on `<pane_id>`.
    - `providers_submit_prompt <pane_or_agent> <short_prompt>` $\rightarrow$ rejects prompts $\ge 200$ bytes; runs `herdr agent prompt <target> "<short_prompt>"` followed by `sleep "${ARMY_SUBMIT_DELAY:-1}" && herdr agent send-keys <target> enter`.
  - `lib/briefs.sh`:
    - `briefs_dispatch_task <repo_dir> <seat> <wave> <task_id> <xml_file_src>` $\rightarrow$ looks up `<seat>`'s `pane_id`, `worktree_dir`, `kind`, `model` in `.agent-army/seats.json`; calls `providers_start_fresh_session`; copies `<xml_file_src>` to `<worktree_dir>/.agent-army/briefs/<wave>-<task_id>.xml`; deletes `<worktree_dir>/.agent-army/anchors/<task_id>.txt`; writes current epoch seconds to `<worktree_dir>/.agent-army/anchors/<task_id>.prompt_ts`; calls `providers_submit_prompt "<seat>-<slug>" "Read .agent-army/briefs/<wave>-<task_id>.xml, execute the task within scope, commit your work, and write the completion anchor file."`.
    - `briefs_dispatch_verifier <repo_dir> <wave> <task_id> <verify_xml_src>` $\rightarrow$ same flow on the `verifier` seat, deleting `<verifier_wt>/.agent-army/anchors/<task_id>.verify.txt`, writing `<task_id>.verify.prompt_ts`, and prompting `verifier-<slug>` with `"Read .agent-army/briefs/<wave>-<task_id>-verify.xml, audit the commit diff, and write the verifier anchor file."`.
  - `lib/lifecycle.sh`:
    - `swarm_up <repo_dir> <config_path>` $\rightarrow$ runs `ensure_git_exclude`, provisions worktrees first, splits Herdr panes with `--cwd <worktree_dir> --no-focus`, starts credential-free agents (`worker_1..N`, `verifier`; never creates an `ops` pane), and writes `.agent-army/seats.json` (`{workspace_id, seats: {<seat>: {pane_id, agent_name, kind, model, role, worktree_dir, branch, critical}}}`).
    - `swarm_verify_seats <repo_dir> <config_path>` $\rightarrow$ checks configured roster against `seats.json` and `herdr agent list`; fails closed if any `critical = true` seat is missing.
    - `swarm_down <repo_dir>` $\rightarrow$ snapshots any dirty worktrees and closes only panes recorded in `.agent-army/seats.json`.

- [ ] **Step 1: Write the failing tests in `tests/test_worktree_sync.sh` (seat lifecycle & brief dispatch section)**

```bash
# Append to tests/test_worktree_sync.sh with a mock `herdr` script on PATH:
# 1. swarm_up executes in exact order: ensure_git_exclude -> worktree_provision ->
#    herdr pane split --cwd <wt> --no-focus -> herdr agent start <seat>-<slug> -> seats.json record.
# 2. Worker and verifier launches strip GITHUB_TOKEN, GH_TOKEN, AWS_* and set
#    AWS_SHARED_CREDENTIALS_FILE=/nonexistent, GOOGLE_APPLICATION_CREDENTIALS=/nonexistent,
#    CLOUDSDK_CONFIG=/nonexistent.
# 3. No ops pane is created.
# 4. briefs_dispatch_task starts a fresh agent session on the existing pane, deletes any stale
#    anchor file, writes .prompt_ts, writes the brief under <wt>/.agent-army/briefs/, and sends
#    a prompt < 200 bytes.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash tests/test_worktree_sync.sh`
Expected: FAIL (`lib/lifecycle.sh: No such file or directory`)

- [ ] **Step 3: Implement `briefs/worker.in.md`, `briefs/verifier.in.md`, `lib/providers.sh`, `lib/briefs.sh`, and `lib/lifecycle.sh`**

Implement the modules according to **Interfaces**. Ensure `providers_submit_prompt` enforces `${#prompt} -lt 200` so multi-line XML can never be pasted into `herdr agent prompt`.

- [ ] **Step 4: Run tests and lint to verify they pass**

Run: `make check`
Expected: PASS (all tests green, 0 ShellCheck warnings)

- [ ] **Step 5: Commit**

```bash
git add briefs/worker.in.md briefs/verifier.in.md lib/providers.sh lib/briefs.sh lib/lifecycle.sh tests/test_worktree_sync.sh
git commit -m "feat: add credential-free Herdr seat lifecycle and file-path brief dispatcher"
```

---

### Task 4: Supervisor Gate, Mandatory Verifier Audit, Flake Rerun & All-Blob Secret Scanner

**Files:**
- Create: `lib/supervisor.sh`
- Test: `tests/test_supervisor_verifier.sh`
- Test: `tests/test_security_boundaries.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `lib/profile.sh`, `lib/partition.sh`, `lib/briefs.sh`, `lib/worktree.sh`, `lib/telemetry.py`, `lib/arbiter.sh` (`arbiter_enqueue`).
- Produces:
  - `lib/supervisor.sh`:
    - `supervisor_read_anchor <worktree_dir> <anchor_relpath> <prompt_ts_file> <agent_name>` $\rightarrow$ returns anchor line if `<worktree_dir>/<anchor_relpath>` exists and its mtime (via `$PYTHON_BIN -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))'`) is `>=` the integer stored in `<prompt_ts_file>`; if the file does not exist, runs a single `herdr agent read <agent_name> --source recent-unwrapped --lines 40` matching `^[[:space:]]*(WORKER DONE|WORKER BLOCKED|VERIFIER PASS|VERIFIER FAIL) #[A-Za-z0-9_-]+`.
    - `supervisor_needs_verifier <repo_dir> <base_ref> <sha> <verify_attr>` $\rightarrow$ returns 0 if `<verify_attr> == "asymmetric"` OR if any path in `git -C "$repo_dir" diff --name-only "${base_ref}...${sha}"` matches any glob in `TEST_GLOBS` (`fnmatch` via `$PYTHON_BIN`).
    - `supervisor_scan_secrets <repo_dir> <integration_ref> <sha>` $\rightarrow$ enumerates `git -C "$repo_dir" rev-list --objects "${integration_ref}..${sha}"`; returns `20` (and prints the offending path/pattern on stderr) if any object path matches `(^|/)\.env($|\.)` (excluding `.env.example` / `.env.sample` / `.env.template`), `\.pem$`, `\.key$`, or if any `blob` object (`git cat-file -t "$oid" == "blob"`) matches `-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----`, `sk-[A-Za-z0-9]{20,}`, `ghp_[A-Za-z0-9]{20,}`, or `AKIA[0-9A-Z]{16}`. Returns `0` when clean.
    - `supervisor_gate_commit <repo_dir> <wave> <task_id> <seat> <sha> <base_ref> <owns_csv> <verify_attr>` $\rightarrow$
      1. Verifies `<sha>` is a valid commit in `<repo_dir>`, worktree has empty `git status --porcelain`, and `partition_check_diff_in_owns` passes (else returns `RED:owns_or_drift`).
      2. Rejects commits touching `.github/workflows/*` unless `.github/workflows` is explicitly in `<owns_csv>` (`BLOCKED:GITHUB_MAIN:workflow_touch`).
      3. Runs `supervisor_scan_secrets` between `refs/heads/army/<slug>/integration` and `<sha>` (if rc 20, returns `BLOCKED:SECRET:<detail>`).
      4. Runs `TEST_CMD` in `<worktree_dir>` via `clean_gate_exec`. If exit code $\ne 0$, runs `clean_gate_exec` **once more** (flake rerun, does not increment `repairs_used`). If still non-zero, returns `RED:test_failed:<gate_log>`.
      5. If `supervisor_needs_verifier` returns 0, renders `<verifier_brief>` for `<task_id>` at `<sha>`, calls `briefs_dispatch_verifier`, and polls `<verifier_wt>/.agent-army/anchors/<task_id>.verify.txt` (serializing one verifier audit at a time). On `VERIFIER FAIL #<task_id> <sha> <reason>`, returns `RED:verifier_failed:<reason>`.
      6. On pass, logs to `telemetry.py`, calls `arbiter_enqueue "$repo_dir" "$task_id" "$seat" "$sha"`, and returns `GREEN:<sha>`.
    - `supervisor_supervise_wave <repo_dir> <wave_manifest_json>` $\rightarrow$ polls active tasks in the wave until all reach `GREEN`, `RED`, or `BLOCKED`:
      - Checks `herdr agent get <agent_name>` for `agent_status == "blocked"` $\rightarrow$ marks task `BLOCKED:AUTH:herdr_agent_blocked`.
      - On `RED` when `repairs_used < ARMY_MAX_REPAIRS_PER_TASK`, increments `repairs_used`, writes repair brief referencing the failure reason/log, and calls `briefs_dispatch_task` on the same seat.
      - On task clock expiry (`now - prompt_ts > ARMY_TASK_TIMEOUT_SEC`), runs `worktree_snapshot`, and if `timeouts_used == 0`, increments `timeouts_used` and re-dispatches the same brief on a fresh session via `briefs_dispatch_task`; on second expiry, marks task `BLOCKED:TIMEOUT:<snapshot_path>`.
      - Whenever a task finishes as `RED` or `BLOCKED` (not enqueued), calls `partition_release_task "$repo_dir" "$task_id"`.
      - Outputs JSON wave receipt `{ "wave": N, "tasks": { "<task_id>": { "status": "GREEN|RED|BLOCKED", "sha": "...", "boundary": "...", "reason": "...", "snapshot": "..." } } }`.

- [ ] **Step 1: Write the failing tests in `tests/test_supervisor_verifier.sh` and `tests/test_security_boundaries.sh`**

```bash
# tests/test_supervisor_verifier.sh assertions:
# 1. Stale anchor file with mtime < prompt_ts is ignored; fresh anchor file is read [Review Focus #4].
# 2. Flake rerun: a TEST_CMD that fails on attempt 1 and passes on attempt 2 yields GREEN:<sha>
#    with repairs_used == 0.
# 3. Mandatory verifier on test file change: a task with verify="none" that modifies tests/test_app.py
#    still triggers supervisor_needs_verifier (exit 0) and runs the verifier seat.
# 4. Verifier FAIL triggers 1 repair turn on a fresh session; if the repair fails again, the task
#    ends RED and its lease in .agent-army/leases.json is released.
# 5. Task timeout: first expiry snapshots worktree and re-dispatches once; second expiry marks
#    BLOCKED:TIMEOUT:<snapshot_path> and releases lease.

# tests/test_security_boundaries.sh assertions:
# 1. Secret added in an intermediate commit and deleted in the tip commit is still caught by
#    supervisor_scan_secrets walking git rev-list --objects <integration>..<sha> -> BLOCKED:SECRET.
# 2. Binary blob in commit range does not crash supervisor_scan_secrets under set -euo pipefail [Review Focus #3].
# 3. Worker writing "WORKER BLOCKED #W1-T1 AUTH gh login required" or Herdr reporting
#    agent_status="blocked" halts the task as BLOCKED:AUTH.
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/bin/bash tests/test_supervisor_verifier.sh && /bin/bash tests/test_security_boundaries.sh`
Expected: FAIL (`lib/supervisor.sh: No such file or directory`)

- [ ] **Step 3: Implement `lib/supervisor.sh`**

Implement `lib/supervisor.sh` with all functions specified in **Interfaces**. Ensure `supervisor_scan_secrets` uses `if git -C "$repo_dir" cat-file -p "$oid" | grep -a -q -E "$SECRET_REGEX"; then ...` inside an `if` condition so `grep` exit code 1 (no match) never triggers `set -e`.

- [ ] **Step 4: Run tests and lint to verify they pass**

Run: `make check`
Expected: PASS (all tests green, 0 ShellCheck warnings)

- [ ] **Step 5: Commit**

```bash
git add lib/supervisor.sh tests/test_supervisor_verifier.sh tests/test_security_boundaries.sh
git commit -m "feat: add supervisor exact-SHA gate, mandatory verifier audit, flake rerun, and blob secret scan"
```

---

### Task 5: Arbiter Queue, Stopped-Process Lock Reaper, Clean-Env Combined Gate & Local Promote

**Files:**
- Create: `lib/arbiter.sh`
- Test: `tests/test_arbiter_promote.sh`

**Interfaces:**
- Consumes: `state_read_slug`, `clean_gate_exec` from `lib/common.sh`; `partition_release_task` from `lib/partition.sh`; `worktree_sync_pool` from `lib/worktree.sh`; `lib/telemetry.py`.
- Produces:
  - `lib/arbiter.sh`:
    - `arbiter_lock <state_dir> [lock_name]` / `arbiter_unlock <state_dir> [lock_name]` $\rightarrow$ atomic `mkdir` lock recording holder PID. Reaps existing lock if holder PID is dead (`! kill -0 "$pid"`) OR if `ps -o state= -p "$pid" 2>/dev/null | awk '{print substr($1,1,1)}'` equals `"T"` (stopped process: `T`, `TN`, `T+`).
    - `arbiter_init_ref <repo_dir> [base_commit]` $\rightarrow$ reads `slug` via `state_read_slug "$repo_dir"`, initializes `refs/heads/army/<slug>/integration` at `<base_commit>` (default `HEAD`). Refuses if ref already exists.
    - `arbiter_enqueue <repo_dir> <task_id> <seat> <sha> [priority] [supersedes_task_id]` $\rightarrow$ appends `{ts, ticket: task_id, seat, sha, status: "queued", priority: "normal"|"front", supersedes: supersedes_task_id}` to `<repo_dir>/.agent-army/integration.jsonl`.
    - `arbiter_drain <repo_dir>` $\rightarrow$
      1. Acquires `arbiter_lock`. Selects next `queued` record (`priority == "front"` first, then oldest `ts`).
      2. Prepares detached worktree `<repo_dir>/.agent-army/worktrees/arbiter-<slug>` at `i0 = $(git rev-parse refs/heads/army/<slug>/integration)`.
      3. Merges `<sha>` (`--no-ff` if not fast-forwardable). On merge conflict, aborts merge, resets arbiter worktree to `i0`, writes `<repo_dir>/.agent-army/drain-failure.json` (`{status: "conflict", ticket: R.ticket, seat: R.seat, sha: R.sha, integration_tip: i0, owns: <all paths modified in R.sha>}`), leaves `R` and all subsequent records `queued`, releases lock, and returns `2`.
      4. Runs `TEST_CMD` on the combined tree in the arbiter worktree via `clean_gate_exec` (`env -i` with `CI=true`). On non-zero exit, resets arbiter worktree to `i0`, writes `<repo_dir>/.agent-army/drain-failure.json` (`{status: "integration_red", ticket: R.ticket, seat: R.seat, sha: R.sha, integration_tip: i0, gate_log: "...", owns: <all paths modified in R.sha>}`), leaves `R` and all subsequent records `queued`, releases lock, and returns `2`.
      5. On green gate, CAS-updates `git update-ref refs/heads/army/<slug>/integration "$candidate" "$i0"`, marks record `integrated`, and if `R.supersedes` is non-empty, marks the superseded queued record `superseded`. Repeats until no `queued` records remain, removes any stale `drain-failure.json`, releases lock, and returns `0`.
    - `arbiter_promote <repo_dir> --confirm` $\rightarrow$
      1. Runs `_arb_promote_pane_check`: refuses if `HERDR_PANE_ID` is set to a pane occupied by a live Herdr agent.
      2. Verifies root checkout is on `base_branch` (`main`) and `git -C "$repo_dir" status --porcelain` is empty.
      3. Runs `git -C "$repo_dir" merge --ff-only "army/${slug}/integration"`.
      4. Marks all `integrated` records in `integration.jsonl` as `promoted`, calls `partition_release_task` for each promoted ticket (and any `superseded` ticket it resolved), and calls `worktree_sync_pool "$repo_dir" "HEAD" ""` so all idle worker and verifier worktrees advance to the new `main`.

- [ ] **Step 1: Write the failing tests in `tests/test_arbiter_promote.sh`**

```bash
# tests/test_arbiter_promote.sh assertions:
# 1. Stopped lock holder reaping: spawn a background `sleep 60`, write its PID into
#    .agent-army/arbiter.lock/pid, send `kill -STOP $pid`, and verify `arbiter_lock`
#    detects state `T*`, reaps the lock, and acquires it (cleanup: kill -9 $pid).
# 2. Clean-env combined gate: arbiter_drain runs TEST_CMD with CI=true and HERDR_PANE_ID unset,
#    CAS-advances refs/heads/army/<slug>/integration, and arbiter_promote --confirm fast-forwards
#    local main, releases leases in leases.json, and syncs worker_1/verifier worktrees to new main.
# 3. Conflict / integration_red queue preservation: enqueue T1 (clean), T2 (conflicts with T1),
#    and T3 (clean). arbiter_drain integrates T1, stops at T2 with exit code 2, writes
#    drain-failure.json with T2's paths in `owns`, and leaves BOTH T2 and T3 in status="queued".
# 4. Resolution task drainage: enqueue T2-RESOLVE with priority="front" and supersedes="T2";
#    arbiter_drain integrates T2-RESOLVE first, marks T2 status="superseded", and then integrates
#    T3 in the same drain pass.
# 5. _arb_promote_pane_check refuses promote when HERDR_PANE_ID matches a live Herdr agent pane.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash tests/test_arbiter_promote.sh`
Expected: FAIL (`lib/arbiter.sh: No such file or directory`)

- [ ] **Step 3: Implement `lib/arbiter.sh`**

Implement `lib/arbiter.sh` satisfying all behaviors in **Interfaces**. Update `tests/test_supervisor_verifier.sh` if it used a stub `arbiter.sh` so both suites call the real `lib/arbiter.sh`.

- [ ] **Step 4: Run tests and lint to verify they pass**

Run: `make check`
Expected: PASS (all test suites green, 0 ShellCheck warnings)

- [ ] **Step 5: Commit**

```bash
git add lib/arbiter.sh tests/test_arbiter_promote.sh
git commit -m "feat: add arbiter queue, stopped-process lock reaper, clean-env gate, and promote sync"
```

---

### Task 6: Out-of-Swarm Commander Engine (`lib/commander.py`) & `bin/army` CLI

**Files:**
- Create: `briefs/commander.sys.md`
- Create: `briefs/commander.opencode.json`
- Create: `lib/commander.py`
- Create: `bin/army`
- Create: `README.md`
- Create: `CLAUDE.md`
- Modify: `STATE.md`
- Test: `tests/test_commander_loop.py`

**Interfaces:**
- Consumes: `lib/preflight.sh`, `lib/config.sh`, `lib/profile.sh`, `lib/lifecycle.sh`, `lib/partition.sh`, `lib/briefs.sh`, `lib/supervisor.sh`, `lib/arbiter.sh`, `lib/worktree.sh`.
- Produces:
  - `briefs/commander.opencode.json`:
    ```json
    {
      "$schema": "https://opencode.ai/config.json",
      "agent": {
        "commander": {
          "permission": {
            "*": "deny",
            "read": "allow",
            "bash": "deny",
            "shell": "deny",
            "edit": "deny",
            "write": "deny"
          }
        }
      }
    }
    ```
  - `briefs/commander.sys.md`: System prompt defining the `<commander_decision action="dispatch_wave|mission_complete|mission_blocked">` XML output schema and security boundary rules.
  - `lib/commander.py`:
    - `acquire_army_lock(state_dir: Path) -> IO[str]`: acquires `fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)` on `<state_dir>/army.lock`; raises `ArmyLockError` (exit 1) if already locked.
    - `build_commander_cmd(army_root: Path, repo_dir: Path, cfg: dict, prompt_file: Path) -> Tuple[List[str], Dict[str, str]]`:
      - Strips `HERDR_PANE_ID` and `HERDR_ENV` from env.
      - For `pi`: `["pi", "-p", "--no-tools", "--no-context-files", "--session", str(state_dir / "commander-session.jsonl"), "--model", cfg["commander_model"], "--thinking", cfg["commander_thinking"], "--append-system-prompt", str(prompt_file), "Emit only the <commander_decision> block."]`.
      - For `opencode`: sets `OPENCODE_CONFIG=str(army_root / "briefs/commander.opencode.json")` and `OPENCODE_CONFIG_PROJECT_DISABLE="1"`, returns `["opencode", "run", "--session", session_id, "--agent", "commander", f"Read {prompt_file} and emit only the <commander_decision> block."]`.
    - `parse_decision_xml(stdout: str) -> CommanderDecision`: regex-locates `<commander_decision\b.*?</commander_decision>` across `stdout` (`re.DOTALL`); raises `DecisionParseError` if `len(matches) != 1`; parses with `xml.etree.ElementTree.fromstring` into `CommanderDecision(action, summary, boundary, reason, tasks: List[TaskSpec])`.
    - `scan_task_security_boundaries(task: TaskSpec) -> Optional[Tuple[str, str]]`: inspects `objective`, `scope`, `done_criteria` for `GITHUB_MAIN` (`gh pr merge`, `git push origin main`, `git push --force`), `SECRET` (`.env`, private keys, credentials), `AUTH` (`auth login`, `oauth`, `2fa`), and `DEPLOY` (`terraform apply`, `kubectl apply`, `fly deploy`, `vercel --prod`, `npm publish`).
    - `write_handoff(repo_dir: Path, boundary: str, reason: str, required_action: str, state: dict) -> Path`: writes `<repo_dir>/.agent-army/handoff.md` (lowercase) and sets `state["status"] = "blocked"`, `state["boundary"] = boundary`.
    - `run_mission(repo_dir: Path, mission_file: Path, config_path: Path, overrides: dict) -> int`:
      - Acquires `.agent-army/army.lock`.
      - Runs `preflight_check`, `swarm_up`, `arbiter_init_ref` (if ref absent).
      - Loops across waves up to `max_waves`:
        1. **Drain & Promote Settled Queue Before Wake:** If `.agent-army/integration.jsonl` has `queued` records, runs `arbiter_drain`.
           - If `arbiter_drain` returns `2` (`conflict` or `integration_red`), reads `.agent-army/drain-failure.json` for record `R`, wakes Commander with a conflict/red resolution prompt requiring **exactly 1 task** whose `owns` equals `R.owns`. Validates the returned decision has `len(tasks) == 1` and `set(tasks[0].owns) == set(R.owns)` (refusing otherwise), calls `partition_reassign_lease`, dispatches that single resolution task to an idle worker seat, supervises it, enqueues its GREEN SHA with `priority="front"` and `supersedes=R.ticket`, and loops back to `arbiter_drain` to drain the resolution SHA + remaining queued records before normal planning!
           - If `arbiter_drain` returns `0`, runs `arbiter_promote --confirm` (which fast-forwards local `main`, releases leases, and syncs the worktree pool).
        2. **Zero-Integrate Wave Accounting:** After a wave settles and drain/promote runs, if 0 commits were promoted in that wave, increments `state["zero_integrate_waves"]`; otherwise resets `state["zero_integrate_waves"] = 0`. If `state["zero_integrate_waves"] >= 2`, calls `write_handoff(repo_dir, "NO_PROGRESS", ...)` and returns `20`.
        3. **Overflow Task Queue vs. Commander Wake:** If `state["pending_tasks"]` has tasks held back from a prior decision that exceeded worker seat count, pops up to `len(idle_worker_seats)` tasks from `state["pending_tasks"]` ahead of waking the Commander; otherwise wakes the Commander (`WAKE_COMMANDER_PLAN`) to get a `<commander_decision>`.
        4. **Decision Dispatch:**
           - `mission_blocked`: calls `write_handoff` and returns `20`.
           - `mission_complete`: if any `queued` records exist, drains and promotes them first; runs final `TEST_CMD` on local `main` via `clean_gate_exec`; writes `.agent-army/COMPLETE.md` and updates `MISSION_STATE.md`; if `create_draft_pr_on_complete` is true, pushes `army/<slug>/integration` and runs `gh pr create --draft`; returns `0`.
           - `dispatch_wave`: assigns at most 1 task per idle worker seat, stores any excess tasks in `state["pending_tasks"]`, runs `scan_task_security_boundaries` (halting with `handoff.md` + `exit 20` on violation), acquires partition leases (`partition_acquire_wave`), writes `.agent-army/briefs/<wave>-<task_id>.xml` (without `<test_cmd>` in `<gates>`), dispatches via `briefs_dispatch_task`, and runs `supervisor_supervise_wave`. If any task in the wave receipt returned `BLOCKED:<BOUNDARY>`, calls `write_handoff` and returns `20`.
    - `resume_mission(repo_dir: Path, config_path: Path) -> int`: loads `.agent-army/state.json`, checks if local `main` HEAD moved ahead of `refs/heads/army/<slug>/integration` (e.g., human committed a fix while paused) and if so updates `refs/heads/army/<slug>/integration` to `main` HEAD and runs `worktree_sync_pool`, resets `zero_integrate_waves = 0` and `status = "running"`, and enters `run_mission`.
  - `bin/army`: Executable CLI router (`army setup|up|down|status|verify|run|resume|arbiter`).

- [ ] **Step 1: Write the failing tests in `tests/test_commander_loop.py`**

```python
# tests/test_commander_loop.py (unittest):
# 1. test_commander_invocation_flags_no_shell:
#    Verifies `pi` command includes `--no-tools --no-context-files` and `opencode` command
#    sets `OPENCODE_CONFIG=.../commander.opencode.json`, `OPENCODE_CONFIG_PROJECT_DISABLE=1`,
#    and `--agent commander` with positional prompt (no `--prompt` flag), and `HERDR_PANE_ID` stripped.
# 2. test_parse_decision_xml_fences_and_multiple_blocks [Review Focus #1]:
#    Extracts `<commander_decision>` when wrapped in ```xml fences + extra chatter; raises
#    DecisionParseError when 0 or 2 `<commander_decision>` blocks appear in stdout.
# 3. test_one_task_per_seat_and_overflow_queue:
#    With 2 worker seats (`worker_1`, `worker_2`) and a Commander decision containing 3 tasks,
#    Wave 1 dispatches 2 tasks (1 per seat) and holds the 3rd in `state.json["pending_tasks"]`,
#    which dispatches first on Wave 2 before waking the Commander.
# 4. test_mechanical_drain_promote_and_conflict_resolution:
#    Simulates a wave settling with GREEN queued commits -> verifies `commander.py` runs
#    `arbiter drain` + `arbiter promote --confirm` BEFORE waking Commander. Simulates a drain
#    conflict on record R -> verifies Commander is woken for 1 resolution task with exact `R.owns`,
#    rejects a decision with mismatched `owns` or >1 task, drains resolution task at front of queue,
#    marks R superseded, and drains remaining queued tasks.
# 5. test_zero_integrate_waves_halts_at_two:
#    Two consecutive settled waves that promote 0 commits write `.agent-army/handoff.md` and return 20.
# 6. test_exclusive_fcntl_army_lock:
#    A second concurrent `acquire_army_lock` or `army run` on the same repo exits immediately with error.
# 7. test_resume_advances_integration_ref_after_human_commit [Review Focus #5]:
#    After a MISSION_BLOCKED halt (exit 20), creating a human commit on `main` and calling
#    `resume_mission` advances `refs/heads/army/<slug>/integration` and worker worktrees to the
#    new `main` HEAD and completes the mission (exit 0).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: FAIL (`ModuleNotFoundError: No module named 'lib.commander'`)

- [ ] **Step 3: Implement `briefs/commander.sys.md`, `briefs/commander.opencode.json`, `lib/commander.py`, `bin/army`, `README.md`, `CLAUDE.md`, and update `Makefile` & `STATE.md`**

Implement the files according to **Interfaces** above. Ensure `Makefile` `make test` runs all `tests/test_*.sh` under `/bin/bash` plus `python3 -m unittest discover -s tests -p "test_*.py" -v`, and `make lint` runs `shellcheck bin/army lib/*.sh tests/*.sh` plus `python3 -m py_compile lib/telemetry.py lib/commander.py tests/test_commander_loop.py`.

- [ ] **Step 4: Run full verification suite (`make check`)**

Run: `make check`
Expected: PASS (all shell suites + Python unit tests pass, 0 ShellCheck warnings)

- [ ] **Step 5: Commit**

```bash
git add Makefile README.md CLAUDE.md STATE.md bin/army briefs/commander.sys.md briefs/commander.opencode.json lib/commander.py tests/test_commander_loop.py
git commit -m "feat: add out-of-swarm commander loop, security boundary handoff, and army CLI"
```
