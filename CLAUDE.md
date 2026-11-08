# CLAUDE.md — agent-army engineering conventions

Guidance for agents (and humans) working **on** agent-army itself.

## Non-negotiable safety invariants

Every change must preserve these. The suites in `tests/` encode them; if a
change breaks one, the change is wrong.

1. **The Commander never touches a shell.** `lib/commander.py` parses exactly
   one `<commander_decision>` block and ignores all other model output. It
   never passes model text to a shell — only validated, enum-checked,
   path-checked fields reach the bash libraries. `pi` runs
   `--no-tools --no-context-files`; `opencode` runs `--agent commander` under
   `briefs/commander.opencode.json` with `OPENCODE_CONFIG_PROJECT_DISABLE=1`.
2. **Self-certified green verdicts are impossible.** Only the supervisor's own
   `clean_gate_exec` run of the project `TEST_CMD` on the exact worker SHA
   counts. A changed test file always triggers the verifier; no brief
   attribute can turn that off.
3. **Local-only promotion.** Nothing ever pushes to `origin/main` or runs
   `gh pr merge`. `arbiter_promote` fast-forwards *local* `main` with
   `--ff-only` after a clean-porcelain + branch check; the optional draft PR
   on completion is the only remote write and is never merged.
4. **Secrets are scanned across every new blob**, not the net diff: a secret
   added in an ancestor and deleted in the tip still blocks (`SECRET`).
   Binary blobs are scanned with `grep -a` and never abort `set -e`.
5. **Fail closed.** Unknown harness, non-runnable `TEST_CMD`, dirty root,
   missing critical seat, unparseable decision, invalid `owns`
   (`..`, leading `/`, `.agent-army`), multiple decision blocks → hard error
   or `MISSION_BLOCKED` with `.agent-army/handoff.md` (lowercase — the only
   handoff filename). Exit codes: `0` complete, `1` error, `20` blocked.

## Shell conventions

- `/bin/bash`, **Bash 3.2 floor** (macOS): no associative arrays, no
  `mapfile`, no `${var,,}`. `set -euo pipefail` in every library.
- **ShellCheck clean (0 warnings)** and enforced by `make lint`.
- Libraries are sourced; every `lib/*.sh` also exposes a thin CLI dispatcher
  (`if [ "${BASH_SOURCE[0]}" = "$0" ]`) so `commander.py` shells out to
  `lib/<x>.sh <subcommand>` rather than re-implementing logic.
- Functions print results on stdout and log via `log_info`/`log_warn`/
  `log_error` (stderr). Exit statuses encode outcomes (e.g. drain: `0` ok,
  `2` conflict/integration_red), never prose.
- Timestamps in files are ISO-8601 UTC; `integration.jsonl` rows are compact
  single-line JSON (`jq -nc`), one record per line.

## State & protocol contracts

- **One slug forever**: `[army].name` → `slugify()` → `state.json.slug`. Every
  ref/seat/branch derives from it; nothing re-derives a slug from paths.
- **Anchor protocol**: `<worktree>/.agent-army/anchors/<task_id>.txt` (+`.verify.txt`
  on the verifier). `briefs.sh` deletes the old anchor and writes
  `<task_id>.prompt_ts` (epoch seconds) *before* prompting;
  `supervisor_read_anchor` ignores files older than that timestamp. A line
  that scrolled off the pane is not an anchor; exactly one
  `herdr agent read` is the fallback and only when the file is absent.
- **Seating order** (never reorder): exclude `.agent-army/` →
  `worktree_provision` → `herdr pane split --cwd <wt> --no-focus` →
  credential-free `herdr agent start` → atomic `seats.json` record. No `ops`
  pane exists; `telemetry.py` appends JSONL only.
- **Prompts are < 200 bytes** and always file-path pointers; multi-line XML
  is delivered as `.agent-army/briefs/<wave>-<task>.xml` inside the seat
  worktree (git-excluded, never committed).
- **Gate environment**: every `TEST_CMD` runs under
  `env -i PATH HOME CI=true TMPDIR=<gate-tmp> [+TOOLCHAIN_VARS]` with
  `HERDR_*`, `REPO_DIR`, `STATE_DIR` stripped. One automatic flake rerun
  before a red counts.
- **Locks**: `arbiter_lock` is a `mkdir` lock that reaps holders whose pid is
  dead **or** whose `ps -o state=` starts with `T` (stopped). `army run` holds
  an exclusive `fcntl.flock` on `.agent-army/army.lock`.
- **Worktree safety**: never `git stash`; never `worktree remove --force` a
  dirty tree without snapshot salvage; `main` moves only via
  `merge --ff-only` from the clean root; idle seats rebase (fallback
  `reset --hard`) onto the new `main` after every promote; seats carrying
  `.agent-army/.active_task` are skipped.

## Testing conventions

- Bash suites run under `/bin/bash` with `set -euo pipefail` and clean up
  their `mktemp -d` via an EXIT trap. Fail loudly (`echo "FAIL: …" >&2;
  exit 1`) — a silent skip is a failure.
- Deterministic offline mocks live in `tests/mocks/` (`herdr`, `pi`) and are
  driven by `HERDR_MOCK_DIR` state files; never shell out to real harnesses
  or the network in tests.
- New behaviour lands test-first: suites must fail before the implementation
  and pass after (`make check` = lint + every suite, 0 ShellCheck warnings).
- Python tests use `unittest` and import `lib/commander.py` via importlib so
  the repo stays package-free.

## Repository layout

`lib/` mechanical libraries (bash + `commander.py`/`telemetry.py`), `bin/army`
CLI router, `briefs/` standing prompt contracts, `tests/` suites + mocks,
`docs/superpowers/` the design spec and implementation plan. `STATE.md` tracks
the active build checkpoint; the SDD ledger lives in
`.superpowers/sdd/<date>-<slug>/progress.md`.
