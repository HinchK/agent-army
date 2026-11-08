# Agent-Army State Checkpoint (`STATE.md`)

**Updated:** 2026-11-08  
**Phase:** Implementation Complete — Tasks 1–6 landed on `feat/agent-army`; `make check` green  
**Design Spec:** [docs/superpowers/specs/2026-11-07-agent-army-design.md](docs/superpowers/specs/2026-11-07-agent-army-design.md)  
**Implementation Plan:** [docs/superpowers/plans/2026-11-07-agent-army.md](docs/superpowers/plans/2026-11-07-agent-army.md)

---

## 1. Key Decisions Made

1. **Out-of-Swarm Commander Decides; `commander.py` Drains and Promotes:**
   - The Commander (`pi` or `opencode`) runs *outside* the Herdr swarm (`HERDR_PANE_ID` unset) and emits one `<commander_decision>` block. It has no shell (`pi --no-tools --no-context-files`; `opencode --agent commander` with `OPENCODE_CONFIG_PROJECT_DISABLE=1`). When a wave settles with a non-empty GREEN queue, `lib/commander.py` runs `arbiter drain` (combined-tree gate on `refs/heads/army/<slug>/integration`) and, on success, local `arbiter promote --confirm` (fast-forwarding local `main`, followed by automatic worktree pool synchronization) before the Commander is woken to plan.
   - Merging to `origin/main` on GitHub remains a hard security boundary where the army stops (opening a draft PR on mission completion is optional).
2. **Event-Driven Outer Loop (`army run`):**
   - An outer controller (`lib/commander.py` via `bin/army run --commander pi|opencode --mission <file>`) holds an exclusive `fcntl` lock on `.agent-army/army.lock` and wakes a persistent, resumable `pi` or `opencode` session only on state transitions (Wave Plan, Conflict/Red Resolution, Mission Complete, or Security Boundary Halt).
   - Tracks `zero_integrate_waves` in `.agent-army/state.json`; 2 consecutive waves with 0 promoted commits write `.agent-army/handoff.md` and exit `20` (`MISSION_BLOCKED`).
3. **Orchestration Collapse + Standing Worktree Pool with Dynamic LARP Personas:**
   - Stampede's in-swarm `looper` and `pm` middlemen and the `ops` pane are removed. `telemetry.py` appends JSONL only.
   - Herdr hosts a standing pool of isolated git worktrees (`worker-1..N`, `verifier`) launched with credential-free environments. Each task, repair, and timeout retry starts a fresh agent session on the existing pane.
   - `.agent-army/` is added to `.git/info/exclude` before worktree provisioning; anchor files live at `<worktree>/.agent-army/anchors/<task_id>.txt` and `<verifier-worktree>/.agent-army/anchors/<task_id>.verify.txt`.
   - Every `TEST_CMD` runs under `env -i` (`CI=true`), with 1 automatic flake rerun before a red counts, mandatory verifier audits on test-file changes (`test_globs`) or `verify="asymmetric"`, and all-blob secret scanning across `git rev-list --objects <integration>..<sha>`.
   - Arbiter locks reap dead holders and stopped holders (`ps -o state=` starting with `T`).

---

## 2. Open Items / Unresolved Blockers

- None from the implementation plan. All six tasks are implemented and tested
  (`tests/` suites + `tests/test_commander_loop.py`, mocks in `tests/mocks/`).
- Deferred minor from Task 1 review: add a timeout assertion for
  `clean_gate_exec` in `tests/test_config_profile.sh`.

---

## 3. Immediate Next Step

- Review the `feat/agent-army` branch; merge to `main` when ready. Runtime
  validation against a live Herdr workspace + real `pi`/`opencode` harness is
  the first post-merge activity.
