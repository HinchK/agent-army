# Agent-Army State Checkpoint (`STATE.md`)

**Updated:** 2026-11-07  
**Phase:** Design Spec Complete (Builder Check Passed — Awaiting User Approval)  
**Design Spec:** [docs/superpowers/specs/2026-11-07-agent-army-design.md](docs/superpowers/specs/2026-11-07-agent-army-design.md)

---

## 1. Key Decisions Made

1. **Out-of-Swarm Commander Owns Arbiter Drain & Local Promotion:**
   - The Commander (`pi` or `opencode`) runs *outside* the Herdr swarm (`HERDR_PANE_ID` unset) and owns `arbiter drain` (combined-tree gate on `refs/heads/army/<slug>/integration`) and local `arbiter promote --confirm` (fast-forwarding local `main` across waves, followed by automatic worktree pool synchronization).
   - Merging to `origin/main` on GitHub remains a hard security boundary where the army stops (opening a draft PR on mission completion is optional).
2. **Event-Driven Outer Loop (`army run`):**
   - An outer controller (`lib/commander.py` via `bin/army run --commander pi|opencode --mission <file>`) wakes a persistent, resumable `pi` (`pi -p --session`) or `opencode` (`opencode run --session`) session only on state transitions (Wave Plan, Wave Settled / Arbitration, Mission Complete, or Security Boundary Halt), keeping Commander token burn near zero while workers execute.
3. **Orchestration Collapse + Standing Worktree Pool with Dynamic LARP Personas:**
   - Stampede's in-swarm `looper` and `pm` middlemen are removed.
   - Herdr hosts a standing pool of isolated git worktrees (`worker-1..N`, `verifier`, `ops`).
   - For each wave task, the Commander writes a dynamic XML persona brief (`<role>`, `<objective>`, `<scope>`, `<owns>`, `<gates>`, `<security_boundaries>`, `<comms>`) to `.agent-army/briefs/`.
4. **Build Approach (Approach 1 Selected):**
   - Self-contained `agent-army` repository that ports and adapts Stampede's proven mechanical core (`arbiter.sh`, `worktree.sh`, `partition.sh`, `profile.sh`, `providers.sh`, `lifecycle.sh`, `telemetry.py`) and layers a Python Commander & Wave Controller (`lib/commander.py` + `bin/army`) on top.

---

## 2. Open Items / Unresolved Blockers

- Builder check review on [docs/superpowers/specs/2026-11-07-agent-army-design.md](docs/superpowers/specs/2026-11-07-agent-army-design.md).
- Final user approval of the design specification before invoking `writing-plans`.

---

## 3. Immediate Next Step

- Run the builder-check subagent against `docs/superpowers/specs/2026-11-07-agent-army-design.md`, resolve any builder questions, present the final spec to the user for approval, and then transition to `superpowers:writing-plans`.
