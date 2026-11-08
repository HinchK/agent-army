# Agent-Army — Completion Record

**Updated:** 2026-11-08  
**Repository Root (`main`):** `/Users/hinchk/agent-army-advancement/agent-army` (implementation tip `ff69189`)  
**Design Spec:** [docs/superpowers/specs/2026-11-07-agent-army-design.md](docs/superpowers/specs/2026-11-07-agent-army-design.md)  
**Implementation Plan:** [docs/superpowers/plans/2026-11-07-agent-army.md](docs/superpowers/plans/2026-11-07-agent-army.md)  
**State:** [STATE.md](STATE.md)

> This file was the 2026-11-07 handoff directing execution of Tasks 2–6.
> That work is complete and merged; the handoff is retired and this record
> replaces it. The original handoff text was never committed on `main`.
> The last copy in this clone is `408c139:HANDOFF.md`, a local checkpoint
> and not an ancestor of `main`, so a fresh clone will not have it.

---

## 1. Final State

1. **All six implementation tasks complete and merged to `main`:**
   - Task 1 — config, single-slug state, profile, `clean_gate_exec`, JSONL telemetry.
   - Task 2 — worktree lifecycle, pool base-sync, partition lease engine.
   - Task 3 — credential-free Herdr seat lifecycle, file-path brief dispatcher.
   - Task 4 — supervisor exact-SHA gate, mandatory verifier audit, flake rerun, all-blob secret scanner.
   - Task 5 — arbiter queue, stopped-process lock reaper, clean-env combined gate, local promote.
   - Task 6 — out-of-swarm Commander engine (`lib/commander.py`), `bin/army` CLI, README/CLAUDE docs.
2. **Three review cycles, all findings resolved:**
   - Branch review (`2852f6c..8583c6a`): 2 Critical + 4 Important — fixed (SIGPIPE fail-open secret scan, seat poisoning after terminal RED, queue-write locking, sub-second nonce anchor markers, task-id validation, config→env plumbing).
   - Fix re-review through `d8c2637`: verified; `BUSY:enqueue` keeps lock-contended GREEN tasks alive; Ruling-2 unlocked stub retired.
   - Final independent whole-branch review (`fa83678..462e32d`): 3 Important — fixed RED→GREEN at `946ff94` (fail-closed secret scan on missing integration ref incl. `_ensure_integration_ref` mission guard; preflight/promote parity for untracked `army.config.toml`/`mission.md`; transient verifier-dispatch retry — dispatch functions now fail loudly because `$(…) || rc=$?` suppresses `set -e`).
3. **Verification:** `make check` green on merged `main` — 8 bash suites + 13 python tests, 0 ShellCheck warnings. `bin/army` CLI smoke-tested.
4. **Deferred minor from Task 1 review resolved:** `clean_gate_exec` timeout assertion added (`tests/test_config_profile.sh` Test 4b — hung command killed at deadline, exit 124).
5. **Repository relocated** 2026-11-08 from `~/.gemini/antigravity/scratch/agent-army` to `~/agent-army-advancement/agent-army` (worktree links repaired, then the implementation worktree was removed after merge).

## 2. What Is Deliberately Not Done (deferred, non-blocking)

- Eight review-minor polish items recorded in the SDD ledger rulings
  (pane-fallback anchor staleness, wave-number reuse in resolution dispatch,
  multi-word TOML value truncation in `_load_config`, complete-before-draft-PR
  state ordering, `eval` seat-var expansion in `lifecycle.sh`, one vestigial
  test assert, bare `.github/workflows` owns trap, rebase-vs-reset sync note).
- Anything requiring live infrastructure: real Herdr panes, `pi`/`opencode`
  Commander sessions, and a real target mission.

## 3. Next Step

- **Runtime validation against a live Herdr workspace** with a real
  `pi`/`opencode` Commander: the offline mocks prove every contract, but
  pane-id parsing (`_parse_pane_id`, `find_workspace_by_cwd`,
  `herdr agent list` shapes) is unproven live. Then run a first real mission:
  `army setup <repo>` → `army run <repo> --mission <file> --commander pi`.
  Merging to `origin/main` on GitHub remains the human's boundary.
