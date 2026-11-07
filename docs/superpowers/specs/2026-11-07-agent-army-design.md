# Agent-Army Design Specification

- **Date:** 2026-11-07
- **Repository:** `/Users/hinchk/.gemini/antigravity/scratch/agent-army`
- **Status:** Builder Check Passed — Awaiting User Approval

---

## 1. Intent and Why

Single-agent coding harnesses ("Single-Supertroop") preserve end-to-end context coherence and eliminate handoff loss, but suffer from context window saturation on multi-slice missions, self-justification bias during verification, and high frontier token burn on routine implementation tasks. Conversely, traditional multi-agent swarms ("Multi-Swarm") isolate context and enable parallel execution and model-cost arbitrage, but frequently degrade due to middle-manager "Frankenprompts" or stall at human-only integration gates between waves.

**Agent-Army** unifies both paradigms into an autonomous, mission-oriented agent organization:

1. **Out-of-Swarm "Special Forces" Commander (`pi` or `opencode`):** A single long-horizon, high-reasoning agent sitting *outside* the Herdr worker swarm (`HERDR_PANE_ID` unset). Driven by an event-based outer loop (`army run`), the Commander holds mission truth, decomposes work into non-overlapping waves, authors dynamic role-play ("LARP") XML briefs for workers, and acts as the automated arbiter operator—running `arbiter drain` and local `arbiter promote --confirm` to fast-forward local `main` between waves.
2. **Zero-Trust Herdr Worker Swarm (`worker-1..N`, `verifier`, `ops`):** A standing pool of isolated Git worktree seats inside a Herdr workspace, stripped of redundant in-swarm `looper` and `pm` middlemen ("Orchestration Collapse"). Workers execute bounded tasks under dynamic XML personas, while an independent `verifier` seat and mechanical exact-SHA test runner gate every commit before integration.
3. **Mission-Complete or Security-Boundary Halt:** Agent-Army works a target repository across waves autonomously until the mission exit criteria pass or a **hard security boundary** (secrets/credentials, interactive logins/auth, deployments/external mutations, or merging to `origin/main` on GitHub) is encountered, at which point it halts fail-closed with a structured, resumable handoff receipt.

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
- **Event-Driven Outer Commander Loop (`army run`):** Run the Commander in a persistent, resumable `pi` (`pi -p --session ...`) or `opencode` (`opencode run --session ...`) session outside Herdr that wakes only on state transitions (Wave Planning, Wave Verdict Arbitration, Repair Triage, Mission Completion, or Security-Boundary Halt).
- **Orchestration Collapse (Standing Worktree Pool):** Replace Stampede's in-swarm `looper` and `pm` seats with the external Commander. Maintain a standing Herdr pool of isolated git worktree seats (`worker-1..N` on cost-fitted coding models + 1 independent `verifier` seat + 1 model-free `ops` telemetry pane).
- **Dynamic LARP XML Briefing:** Parameterize each delegated task with a file-based XML brief (`<role>`, `<objective>`, `<scope>`, `<owns>`, `<gates>`, `<security_boundaries>`, `<comms>`) tailored to the task's domain persona and delivered via short file-path prompts.
- **Zero-Trust Mechanical + Asymmetric Verification:** Require every worker task to pass both (a) the supervisor's independent execution of the project's `TEST_CMD` on the exact worker commit SHA and (b) when flagged by the Commander (`verify="asymmetric"`), an adversarial review by the detached `verifier` seat.
- **Commander-Driven Arbiter Drain & Local Promotion:** Empower the external Commander to run `arbiter drain` (merging gated SHAs onto `refs/heads/army/<slug>/integration` in a detached worktree and gating the combined tree) and local `arbiter promote --confirm` (fast-forwarding local `main`), followed by automatic worktree pool synchronization so Wave $N+1$ branches from the newly integrated local `main`.
- **Fail-Closed Security Boundaries & Resumable Handoff:** Detect and halt immediately before crossing security boundaries, pausing active tasks and writing `.agent-army/handoff.md` and `.agent-army/state.json` so a human can perform the privileged action and run `army resume`.

### Non-Goals
- **Custom Model Training / Soft-Token Projectors in v1:** Concepts from the exploration notes requiring neural weight training or frozen-LLM embedding projection (e.g., Memorilla soft memory tokens or Recursive Self-Improvement weight updates) are out of scope for v1. Long-horizon memory in v1 is handled via durable state checkpoints (`MISSION_STATE.md`, `.agent-army/state.json`) and native `pi`/`opencode` session persistence.
- **Replacing Herdr:** Herdr remains the terminal workspace, pane, and agent lifecycle manager.
- **Gate-less Repositories:** Target repositories without Git or without a runnable `TEST_CMD` (`""`, `none`, `true`) are rejected fail-closed at preflight.

### Anti-Goals (Failure Conditions Even If Code Runs)
- **Crossing Security Boundaries Autonomously:** Merging a PR into `origin/main` on GitHub, force-pushing, reading/modifying production `.env` secrets or cloud credentials, running production deployments, or auto-approving interactive login/trust dialogs.
- **Self-Certified Green Verdicts:** Accepting a worker's or Commander's claim that tests passed without the supervisor independently executing `TEST_CMD` against the exact commit SHA and verifying zero working-tree drift.
- **Continuous Commander Polling:** Keeping the Commander LLM in an active tool-call polling loop while workers execute, burning frontier tokens on `sleep`/status checks.
- **Raw Prompt Stuffing:** Pasting multi-line XML briefs directly into `herdr agent prompt`, which saturates the PTY canonical input buffer on macOS and silently truncates instructions.
- **Stale Worktree Base Drift:** Promoting integrated commits to local `main` without advancing idle worker worktrees to the new `main` before the next wave is dispatched.

---

## 3. Constraints & Invariants

1. **Platform & Toolchain Floor:**
   - macOS and Linux compatible; shell scripts must run under `/bin/bash` (Bash 3.2 compatibility floor, `set -euo pipefail`, 0 ShellCheck warnings).
   - Python 3.11+ with `tomllib` (resolved via `lib/pyenv.sh`), `jq`, `git`, `gh`, `timeout(1)` (or `gtimeout`/Python fallback), `herdr`, and `pi` or `opencode`.
2. **Commander External Context Invariant:**
   - The Commander process runs with `HERDR_PANE_ID` and `HERDR_ENV` unset (or explicitly stripped in the Commander subshell) so it never occupies a worker pane.
   - `_arb_promote_pane_check` in `lib/arbiter.sh` continues to block any recognized Herdr agent pane (`HERDR_PANE_ID` occupied by a live Herdr agent) from running `promote`, while permitting the external Commander process.
   - When `army` control commands (`army up`, `army status`, `supervisor.sh`) talk to Herdr from the outer loop, they target the explicit Herdr workspace ID recorded in `.agent-army/seats.json` (discovered by strict physical CWD match of the target repo), never relying on ambient `$HERDR_WORKSPACE_ID` or `--current`.
3. **Seating Order Invariant:**
   - `herdr agent start` inherits the pane's CWD fixed at `herdr pane split --cwd`. Isolated seats (`worker-1..N`, `verifier`) must always execute in exact order:
     `worktree_provision` $\rightarrow$ `herdr pane split --cwd <worktree_dir> --no-focus` $\rightarrow$ `herdr agent start <seat>-<slug> --kind <kind> --pane <pane_id>` $\rightarrow$ atomic record in `.agent-army/seats.json`.
4. **Git Worktree Safety Rules:**
   - Never run `git stash` (stash stack is global across worktrees).
   - Never run `git worktree remove --force` on a dirty worktree without first salvaging uncommitted diffs and untracked files to `.agent-army/snapshots/<timestamp>/<seat>/`.
   - Never move a checked-out branch from outside its worktree (`main` is only fast-forwarded via `git -C <repo_root> merge --ff-only army/<slug>/integration` after verifying the root worktree is on `main` and clean).

---

## 4. Approaches Considered

### Approach 1 (Selected): Self-Contained `agent-army` Repo Porting Stampede's Mechanical Core + Python Commander Engine
- **Description:** Vendor and adapt Stampede's proven Bash/Python mechanical libraries (`arbiter.sh`, `worktree.sh`, `partition.sh`, `profile.sh`, `providers.sh`, `lifecycle.sh`, `telemetry.py`) into `agent-army/lib/`, removing `looper` and `pm`. Add a dedicated Python Commander & Wave Controller (`lib/commander.py`) and unified `bin/army` CLI that drives `pi`/`opencode` in an event-driven outer loop, generates LARP XML briefs, enforces security boundaries, and runs the `drain` $\rightarrow$ `promote` $\rightarrow$ worktree-sync cycle between waves.
- **Trade-offs:** Copies ~6 core library modules from Stampede, but keeps `agent-army` 100% self-contained while preserving all battle-tested git CAS ref locks, TOCTOU drift checks, OpenCode `.opencode/opencode.json` model pinning, and PTY-safe file briefing.

### Approach 2: Greenfield Pure-Python Orchestrator
- **Description:** Build a brand-new Python package from scratch using `wt`-style file mailboxes and custom `subprocess` wrappers around `git` and `herdr`.
- **Trade-offs:** Single language, but re-invents CAS ref integration, detached worktree gating, lock reaping, and Herdr TUI readiness workarounds that Stampede already hardened across 27 test suites.

### Approach 3: Thin Wrapper Over an External `stampede` Checkout
- **Description:** Keep `stampede` as an external runtime dependency and write a wrapper script that invokes `stampede` CLI commands.
- **Trade-offs:** Minimal new code, but conflicts with Stampede's core assumptions (mandatory root `looper` seat, fixed `arch`/`pm` roles instead of dynamic LARP XML personas, and no mid-mission worktree base advancement after `promote`).

**Decision:** **Approach 1** was selected because it preserves every git/Herdr safety invariant from Stampede while cleanly re-architecting orchestration around the out-of-swarm Commander and LARP wave loop.

---

## 5. System Architecture ("The How")

```mermaid
flowchart TB
    Human["Human Operator"]
    subgraph OuterLoop["Out-of-Swarm Commander Harness (HERDR_PANE_ID unset)"]
        ArmyCLI["bin/army run (lib/commander.py)"]
        CmdSession["Commander Agent (pi -p --session | opencode run --session)"]
        SecGuard["Security Boundary Guard & Handoff Generator"]
    end

    subgraph TargetRepo["Target Git Repository (.agent-army/)"]
        State["MISSION_STATE.md & state.json"]
        Briefs[".agent-army/briefs/<wave>-<task>.xml"]
        Leases[".agent-army/leases.json (owns: partitions)"]
        Verdicts[".agent-army/session-verdicts.jsonl"]
        Queue[".agent-army/integration.jsonl"]
        ArbiterWT["Detached Arbiter Worktree (refs/heads/army/<slug>/integration)"]
        LocalMain["Root Checkout (local main branch)"]
    end

    subgraph HerdrWS["Herdr Workspace (Standing Worktree Pool)"]
        Sup["lib/supervisor.sh (Exact-SHA TEST_CMD Gate)"]
        W1["worker-1-<slug> (Isolated Worktree)"]
        W2["worker-2-<slug> (Isolated Worktree)"]
        WN["worker-N-<slug> (Isolated Worktree)"]
        Ver["verifier-<slug> (Asymmetric Red-Team Worktree)"]
        Ops["ops-<slug> (ANSI Telemetry Stream)"]
    end

    Human -->|"army run --mission mission.md"| ArmyCLI
    ArmyCLI <-->|"Wake on State Transition"| CmdSession
    CmdSession -->|"1. Emit Wave Plan + LARP XML"| Briefs
    ArmyCLI -->|"2. Acquire Leases & Dispatch File Paths"| W1 & W2 & WN
    W1 & W2 & WN -->|"3. WORKER DONE #<id> <sha>"| Sup
    Sup -->|"4a. Run TEST_CMD on <sha>"| Verdicts
    Sup -->|"4b. Optional Asymmetric Audit"| Ver
    Ver -->|"VERIFIER PASS/FAIL"| Sup
    Sup -->|"5. Enqueue GREEN SHAs"| Queue
    Queue -->|"6. Wave Settled -> Wake Commander"| ArmyCLI
    CmdSession -->|"7. army arbiter drain"| ArbiterWT
    CmdSession -->|"8. army arbiter promote --confirm"| LocalMain
    LocalMain -->|"9. Fast-Forward Idle Worktrees"| W1 & W2 & WN & Ver
    CmdSession -->|"Halt on Boundary / Done"| SecGuard
    SecGuard -->|"HANDOFF.md / Draft PR"| Human
```

### 5.1 Repository Structure (`/Users/hinchk/.gemini/antigravity/scratch/agent-army`)

```text
agent-army/
├── Makefile                        # make check (lint + all test suites), make test, make lint
├── README.md                       # Quickstart, architecture, security boundaries, CLI reference
├── CLAUDE.md                       # Agent engineering conventions & safety invariants
├── STATE.md                        # Active build checkpoint
├── army.config.toml.example        # Default configuration template
├── bin/
│   └── army                        # Main CLI entry point
├── briefs/
│   ├── commander.sys.md            # Commander system prompt & XML output contract
│   ├── worker.in.md                # Standing worker bootstrap brief template
│   └── verifier.in.md              # Standing asymmetric verifier bootstrap brief template
├── lib/
│   ├── common.sh                   # Logging, slugify(), evidence hashing, workspace CWD lookup
│   ├── pyenv.sh                    # Python 3.11+ (tomllib) resolver
│   ├── preflight.sh                # Dependency, harness, model, and Herdr session preflight
│   ├── config.sh                   # Parses army.config.toml -> shell exports
│   ├── profile.sh                  # Fail-closed target repo & TEST_CMD detection
│   ├── worktree.sh                 # Worktree provisioning, pool base-sync, snapshot salvage
│   ├── partition.sh                # `owns:` file-path overlap checker & lease manager
│   ├── providers.sh                # Harness launch (pi, opencode, claude, agy, codex) & model pinning
│   ├── briefs.sh                   # File-path brief renderer & nonce delivery
│   ├── lifecycle.sh                # Herdr workspace/pane seating, verify, selective teardown
│   ├── supervisor.sh               # Harvests worker/verifier anchors, runs TEST_CMD, enqueues SHAs
│   ├── arbiter.sh                  # Detached combined-tree gate, CAS ref update, local main promote
│   ├── telemetry.py                # JSONL event logger & ANSI badge streamer for ops pane
│   └── commander.py                # Outer event loop, pi/opencode session driver, LARP XML & boundary engine
└── tests/
    ├── test_preflight.sh
    ├── test_config_profile.sh
    ├── test_worktree_sync.sh
    ├── test_partition_leases.sh
    ├── test_supervisor_verifier.sh
    ├── test_arbiter_promote.sh
    ├── test_security_boundaries.sh
    └── test_commander_loop.py
```

### 5.2 Configuration Schema (`<target_repo>/army.config.toml`)

`army setup <target_repo>` inspects installed harnesses (`pi`, `opencode`, `claude`, `agy`, `codex`) and writes `<target_repo>/army.config.toml`:

```toml
[army]
name = "my-project"
base_branch = "main"
max_waves = 15
max_repairs_per_task = 1
create_draft_pr_on_complete = false

[commander]
harness = "pi"                      # "pi" or "opencode"
model = "anthropic/claude-sonnet-4-5"
thinking = "high"                   # Passed to pi --thinking when harness = "pi"
timeout_sec = 600

[seats.worker_1]
kind = "opencode"
model = "zai-coding-plan/glm-5.3"
role = "worker"
worktree = true
critical = true

[seats.worker_2]
kind = "opencode"
model = "zai-coding-plan/glm-5.3"
role = "worker"
worktree = true
critical = false

[seats.verifier]
kind = "claude"
model = "sonnet"
role = "verifier"
worktree = true
critical = true
```

Adding `worker_3..N` is a TOML table addition only; no shell scripts hardcode seat counts.

### 5.3 Event-Driven Commander State Machine (`lib/commander.py`)

When the user runs:
```bash
army run <target_repo> --mission <mission_file.md> [--commander pi|opencode] [--model <model>]
```

`lib/commander.py` executes the following state machine outside Herdr (explicitly unsetting `HERDR_PANE_ID` and `HERDR_ENV` in its own process and any `arbiter` / `commander` subprocesses, while passing explicit `--workspace <ws_id>` when calling `herdr` for worker panes):

1. **`PREFLIGHT_AND_SEAT`:**
   - Validates target repo profile (`lib/profile.sh ensure`), ensuring a runnable `TEST_CMD` and clean root checkout on `base_branch` (`main`).
   - Ensures the Herdr workspace and standing seats (`worker-1..N`, `verifier`, `ops`) are seated and idle (`army up <target_repo> --seat-only`), and initializes `refs/heads/army/<slug>/integration` at `main` HEAD if not yet present (`arbiter.sh init-ref`).
   - Creates or loads `.agent-army/state.json` and `.agent-army/MISSION_STATE.md`.

2. **`WAKE_COMMANDER_PLAN`:**
   - Invokes the Commander harness non-interactively with session persistence:
     - **`pi`:** `pi -p --session .agent-army/commander-session.jsonl --model <model> --thinking <level> "Read .agent-army/commander-prompt.md and emit your decision block."`
     - **`opencode`:** `opencode run --session <session_id> --prompt "Read .agent-army/commander-prompt.md and emit your decision block."`
   - The prompt file `.agent-army/commander-prompt.md` contains:
     - Mission specification path and contents summary
     - Current `MISSION_STATE.md` (completed waves, integrated commits, open items)
     - Current repo status (`git log -n 10 --oneline`, directory tree summary, idle worker seats)
     - Latest wave receipts (if waking after a wave)
   - The Commander responds with a deterministic `<commander_decision>` XML block (written to `.agent-army/decision.xml` or extracted from stdout) choosing one of four actions:
     - `action="dispatch_wave"`: Defines 1..N tasks for the next wave.
     - `action="drain_and_promote"`: Triggers `arbiter drain` + `arbiter promote --confirm` for GREEN queued tasks, then immediately re-wakes Commander to plan the next wave or finish.
     - `action="mission_complete"`: Declares all mission exit criteria satisfied after running a final full-repo verification gate.
     - `action="mission_blocked"`: Declares a security boundary or unresolvable blocker.

3. **`DISPATCH_WAVE`:**
   - For each task in the wave:
     - **Security Boundary Pre-Check:** Scans the task's `<objective>`, `<scope>`, and `<gates>` against the Security Boundary rules (§5.6). If a task asks a worker to cross a boundary, halts immediately as `MISSION_BLOCKED`.
     - **Partition Lease Check:** Calls `lib/partition.sh` to verify that the comma-separated `owns:` file paths of all tasks in the wave are mutually disjoint. Acquires leases in `.agent-army/leases.json`.
     - **LARP XML Brief Rendering:** Writes `.agent-army/briefs/<wave>-<task_id>.xml` (schema in §5.4) into the assigned worker's worktree (`.agent-army/worktrees/<seat>/.agent-army/briefs/<wave>-<task_id>.xml`).
     - **Short Prompt Delivery:** Sends a <200-byte prompt to `<seat>-<slug>` via `herdr agent prompt`:
       `Read .agent-army/briefs/<wave>-<task_id>.xml, execute the task within scope, commit your work, and emit the exact completion anchor.`

4. **`SUPERVISE_WAVE` (Commander Asleep — Zero Commander Token Burn):**
   - `lib/supervisor.sh` polls the active Herdr worker panes until all dispatched tasks in the wave reach a terminal state (`GREEN`, `RED`, `BLOCKED`, or timeout):
     - When a worker emits `WORKER DONE #<task_id> <sha>`, the supervisor verifies `<sha>` exists in git and has no uncommitted worktree drift, then runs `TEST_CMD` inside that worktree.
     - If `TEST_CMD` is GREEN and the task brief specifies `verify="asymmetric"`, the supervisor dispatches `.agent-army/briefs/<wave>-<task_id>-verify.xml` to `verifier-<slug>`. The verifier inspects `git diff <base>..<sha>` and emits `VERIFIER PASS #<task_id> <sha>` or `VERIFIER FAIL #<task_id> <sha> <reason>`.
     - Tasks passing all gates are enqueued via `arbiter.sh enqueue <task_id> <seat> <sha>`.
     - If a task fails `TEST_CMD` or `VERIFIER FAIL` once and `repairs_used < max_repairs_per_task`, the supervisor sends the gate log path back to the *same* worker seat for one bounded repair turn.
     - If a worker emits `WORKER BLOCKED #<task_id> <boundary_type> <reason>` or Herdr reports `agent_status == "blocked"`, the supervisor records the block and stops waiting on that seat.

5. **`ARBITER_DRAIN_AND_PROMOTE` (Commander-Owned Integration):**
   - Once the wave settles, `lib/commander.py` wakes the Commander with the wave verdict summary.
   - When the Commander issues `action="drain_and_promote"` (or invokes `army arbiter drain` and `army arbiter promote --confirm` directly):
     1. `arbiter_drain` merges each queued GREEN `<sha>` onto `refs/heads/army/<slug>/integration` in the detached `.agent-army/worktrees/arbiter-<slug>` worktree, runs `TEST_CMD` on the combined tree, and CAS-updates `refs/heads/army/<slug>/integration`.
     2. If `arbiter_drain` hits `conflict` or `integration_red`, the Commander receives the conflict file list / gate log and dispatches a conflict-resolution task in the next wave.
     3. If `arbiter_drain` succeeds, the Commander runs `arbiter_promote --confirm`, which verifies the root checkout is on `main` and clean, runs `git -C <repo_root> merge --ff-only army/<slug>/integration`, marks the records `promoted`, and releases their file leases in `.agent-army/leases.json`.
     4. **Worktree Pool Synchronization (`worktree_sync_pool`):** Immediately after local `main` advances, `lib/worktree.sh` iterates over all idle `worker-N` and `verifier` worktrees, verifies they are clean, and resets/fast-forwards their seat branches (`army/<slug>/<seat>`) to the new `main` HEAD.

6. **`MISSION_COMPLETE` vs. `MISSION_BLOCKED`:**
   - **`MISSION_COMPLETE`:** Commander runs a final verification check on local `main`, updates `MISSION_STATE.md`, writes `.agent-army/COMPLETE.md` summarizing all integrated commits and test receipts, and—only if `create_draft_pr_on_complete = true`—pushes `army/<slug>/integration` and opens a **draft** PR (`gh pr create --draft`), stopping strictly before merging to `origin/main`.
   - **`MISSION_BLOCKED`:** Writes `.agent-army/HANDOFF.md` and `.agent-army/state.json` (status `blocked`) detailing the exact security boundary or blocker encountered, the exact human command/action required, and the `army resume <target_repo>` command to continue once resolved.

---

### 5.4 Dynamic LARP XML Briefing & Anchor Protocol

Every task brief written by the Commander to `.agent-army/briefs/<wave>-<task_id>.xml` uses a strict XML structure inspired by Charles Chen's inverted LARP pattern:

```xml
<task_brief id="W1-T1" wave="1" seat="worker_1" verify="asymmetric">
  <role title="Staff Backend Security Engineer">
    You are a Staff Backend Security Engineer specializing in fail-closed authentication middleware and deterministic unit testing. You distrust happy-path assumptions and write minimal, surgical diffs.
  </role>
  <objective>
    Implement token signature validation and expiry checks in `src/auth/token.py` with full unit test coverage in `tests/test_token.py`.
  </objective>
  <scope>
    <read>src/auth/token.py, src/auth/types.py, tests/test_token.py</read>
    <owns>src/auth/token.py, tests/test_token.py</owns>
    <forbidden>Do not modify any file outside &lt;owns&gt;. Do not install external packages.</forbidden>
  </scope>
  <gates>
    <test_cmd>pytest tests/test_token.py</test_cmd>
    <done_criteria>
      1. Expired tokens raise TokenExpiredError.
      2. Tampered signatures raise InvalidSignatureError.
      3. All existing and new tests pass with 0 warnings.
    </done_criteria>
  </gates>
  <security_boundaries>
    STOP IMMEDIATELY and emit WORKER BLOCKED if completing this task requires:
    - Real API keys, production secrets, or modifying .env / credential stores
    - Interactive login, OAuth, SSO, or 2FA
    - Deploying to external services or mutating remote databases
    - Pushing to git remotes or merging to main on GitHub
  </security_boundaries>
  <comms>
    Do not narrate long explanations in terminal output. Commit your changes on your current branch and emit exactly one final line:
    - On success: WORKER DONE #W1-T1 &lt;40-char-commit-sha&gt;
    - On security boundary or blocker: WORKER BLOCKED #W1-T1 &lt;SECRET|AUTH|DEPLOY|GITHUB_MAIN|SCOPE&gt; &lt;one-line reason&gt;
  </comms>
</task_brief>
```

When `verify="asymmetric"` is set (default for architectural, security-sensitive, or multi-file tasks), the `verifier` seat receives a companion `<verifier_brief>` instructing it to roleplay a **Principal Adversarial Code & Security Auditor** whose sole job is to find spec violations, regressions, unowned file touches, or security boundary leaks in `<sha>`, emitting:
- `VERIFIER PASS #<task_id> <sha>`
- `VERIFIER FAIL #<task_id> <sha> <one-line actionable defect>`

---

### 5.5 Hard Security Boundaries & Enforcement

Agent-Army enforces four non-negotiable security boundaries across three layers (Commander pre-dispatch check, Worker/Verifier prompt + Git diff check, and Arbiter/CLI guard):

| Boundary Code | What Triggers a Halt | Mechanical Enforcement Layer |
| :--- | :--- | :--- |
| `GITHUB_MAIN` | Merging a PR on GitHub (`gh pr merge`), pushing directly to `origin/main` or `origin/master`, force-pushing, or modifying repo branch protections/settings. | `arbiter.sh` only fast-forwards *local* `main` (`merge --ff-only`). No script ever invokes `gh pr merge` or `git push origin main`. Worker worktrees have no push permission in briefs; supervisor rejects commits touching `.github/workflows` unless explicitly listed in mission scope. |
| `SECRET` | Reading, generating, rotating, or committing real API keys, `.env` secrets, private SSH/PGP keys, cloud credentials (`~/.aws`, `~/.config/gcloud`), or keychain tokens. | Supervisor pre-gate scans `git diff` of `<sha>` for modified `.env*`, `*.pem`, `*.key`, and high-entropy secret patterns (AWS/GCP/GitHub/API token prefixes), marking the verdict `BLOCKED: SECRET` before `arbiter enqueue`. |
| `AUTH` | Interactive login flows (`gh auth login`, `gcloud auth`, OAuth browser redirects, 2FA/SSO prompts) or Herdr TUI permission/trust dialogs (`agent_status == "blocked"`). | `supervisor.sh` monitors `herdr agent get <seat>` for `blocked` status and harvests `WORKER BLOCKED #<id> AUTH ...`, immediately pausing the task and escalating to Commander $\rightarrow$ Human Handoff. |
| `DEPLOY` | Running production/staging deployments (`terraform apply`, `kubectl apply`, `fly deploy`, `vercel --prod`, `npm publish`), remote DB migrations, or external webhooks. | Commander boundary scanner flags deploy commands in task plans; workers emit `WORKER BLOCKED #<id> DEPLOY ...` when a mission step requires live deployment or external infrastructure mutation. |

When any boundary is triggered:
1. The outer loop stops dispatching new waves and leaves running worktrees intact for inspection.
2. `lib/commander.py` writes `.agent-army/HANDOFF.md` containing:
   - **Boundary Triggered:** (`GITHUB_MAIN` | `SECRET` | `AUTH` | `DEPLOY`)
   - **Progress So Far:** Waves integrated into local `main` (with commit SHAs and test receipts)
   - **Exact Action Required from Human:** Step-by-step instructions or commands for the operator
   - **How to Resume:** `army resume <target_repo>`
3. `army run` exits with a dedicated exit code (`exit 20` for security boundary halt, `exit 0` for mission complete, `exit 1` for error).

---

## 6. What Is Left to the Builder

The following implementation details are intentionally left to the builder during planning and execution:
- Internal Python module decomposition if `lib/commander.py` is split into smaller submodules (e.g., `lib/commander/loop.py`, `lib/commander/larp.py`, `lib/commander/boundaries.py`).
- Exact regex list for the pre-gate secret scanner in `lib/supervisor.sh` (beyond standard `.env*`, private key headers, and common `sk-`/`ghp_`/`AKIA` token prefixes).
- ANSI color formatting and column widths in `lib/telemetry.py` for the `ops` pane stream.
- Exact test fixture construction in `tests/` (mock `herdr`, mock `pi`/`opencode` binaries for deterministic offline CI testing via `make check`).
