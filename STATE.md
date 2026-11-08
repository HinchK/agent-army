# Agent-Army State Checkpoint (`STATE.md`)

**Updated:** 2026-11-07  
**Phase:** Implementation Plan Complete — Awaiting Execution Method Selection  
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

- User review of [docs/superpowers/plans/2026-11-07-agent-army.md](docs/superpowers/plans/2026-11-07-agent-army.md) and selection of execution approach (`Subagent-driven` vs. `Native`).

---

## 3. Immediate Next Step

- Execute Tasks 1–6 of [docs/superpowers/plans/2026-11-07-agent-army.md](docs/superpowers/plans/2026-11-07-agent-army.md) once the user selects the execution approach.
