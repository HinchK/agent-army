# Agent-Army

An autonomous, mission-oriented agent organization that unifies single-agent
context coherence with multi-agent parallelism:

- **Out-of-Swarm Commander** (`pi` or `opencode`) — one long-horizon,
  high-reasoning agent *outside* the worker swarm. It has no shell, no edit,
  and no write tools; it emits exactly one `<commander_decision>` XML block
  per wake. `lib/commander.py` parses that block and mechanically runs
  everything else (git, herdr, gates, drain, promote).
- **Zero-Trust Herdr Worker Swarm** — a standing pool of isolated git worktree
  seats (`worker-1..N` + one independent `verifier`), launched credential-free,
  each task on a fresh agent session, briefed via short file-path prompts that
  reference dynamic LARP XML briefs.
- **Mechanical gates everywhere** — the supervisor independently re-runs the
  project's own `TEST_CMD` on the exact worker commit SHA under
  `env -i CI=true`, mandates an adversarial verifier audit whenever a test
  file changes (or `verify="asymmetric"`), scans **every new blob** between
  the integration tip and the SHA for secrets, and hard-rejects commits
  touching `.agent-army/` or unowned paths.
- **Mission-complete or security-boundary halt** — merging on GitHub, real
  secrets, interactive logins, and production deployments are hard boundaries:
  the army halts fail-closed, writes `.agent-army/handoff.md`, and waits for a
  human + `army resume`.

## Quickstart

```bash
# 1. Configure a target git repository (writes army.config.toml).
bin/army setup /path/to/repo

# 2. Run a mission.
bin/army run /path/to/repo --mission mission.md

# 3. When a security boundary halts the mission, do the privileged step
#    yourself, then:
bin/army resume /path/to/repo
```

Requirements: bash 3.2+, Python 3.11+ (`tomllib`), `git`, `jq`, `gh`,
`timeout(1)` (or the built-in Python fallback), `herdr`, and `pi` or
`opencode`.

## Architecture

```
Human ──army run──▶ lib/commander.py (fcntl lock on .agent-army/army.lock)
                      │  wake ◀──────── Commander agent (no shell; XML only)
                      │  briefs ──────▶ worker seats (one task per seat/wave)
                      │  anchors ◀──── supervisor.sh (exact-SHA gate, verifier,
                      │                 flake rerun, all-blob secret scan)
                      │  GREEN shas ──▶ .agent-army/integration.jsonl
                      │  drain ───────▶ detached arbiter worktree
                      │                   (combined-tree gate, CAS ref update)
                      │  promote ─────▶ local main --ff-only + pool sync
                      └─ boundary ────▶ .agent-army/handoff.md (exit 20)
```

Between waves the queue is drained and promoted **before** the Commander is
woken again, so wave *N+1* always branches from the newly integrated local
`main`. Two consecutive zero-integrate waves end the mission as
`MISSION_BLOCKED` (`NO_PROGRESS`), as does reaching `max_waves`.

### Wave lifecycle

1. `PREFLIGHT_AND_SEAT` — profile (runnable `TEST_CMD`), slug state, Herdr
   seats, `refs/heads/army/<slug>/integration` initialized at `main`.
2. `WAKE_COMMANDER_PLAN` — the Commander returns `dispatch_wave`,
   `mission_complete`, or `mission_blocked`. Extra tasks beyond the idle seat
   count are kept and dispatched first on the next wave.
3. `SUPERVISE_WAVE` — anchors (mtime-guarded) + `TEST_CMD` + verifier + secret
   scan; one automatic flake rerun before a red counts; one repair turn per
   task; task-clock timeout re-dispatches once, then blocks with a snapshot.
4. `ARBITER_DRAIN_AND_PROMOTE` — merge queued SHAs onto the integration
   ref in a detached worktree, gate the combined tree under `env -i CI=true`,
   CAS-update the ref, fast-forward **local** `main`, release leases, and
   sync idle worktrees. Conflicts/integration-red wake the Commander for
   exactly one resolution task whose `owns` equals the failed record's paths.

## Configuration (`<repo>/army.config.toml`)

See [`army.config.toml.example`](army.config.toml.example): `[army]` holds the
mission name (one slug, forever), wave/repair/timeout budgets, and the
optional draft-PR switch; `[commander]` selects `pi` or `opencode` with model
and thinking level; `[seats.*]` adds workers (`worker_3..N` are pure TOML
additions — nothing hardcodes seat counts).

## Security boundaries

| Code | Trigger | Enforcement |
| :--- | :--- | :--- |
| `GITHUB_MAIN` | `gh pr merge`, push to `origin/main`, force-push, workflow edits | only local `--ff-only` promote; supervisor blocks `.github/workflows/*` unless explicitly owned |
| `SECRET` | `.env*` (minus `.env.example/sample/template`), `*.pem`, `*.key`, private-key headers, `sk-…`, `ghp_…`, `AKIA…` | all-blob scan of `git rev-list --objects integration..sha` — a secret deleted in the tip still blocks |
| `AUTH` | interactive logins, OAuth/2FA, Herdr trust dialogs | worker `WORKER BLOCKED … AUTH` anchors + `herdr agent get` blocked status halt the wave |
| `DEPLOY` | `terraform/kubectl apply`, `fly deploy`, `vercel --prod`, `npm publish` | Commander pre-dispatch scan refuses to dispatch; workers must block |

Halts write `.agent-army/handoff.md` (boundary, progress, the exact human
action, and the `army resume` command) and exit `20`.

## CLI reference

| Command | Purpose |
| :--- | :--- |
| `army setup <repo>` | write `army.config.toml` from detected harnesses |
| `army up <repo>` | preflight + seat the standing pool (+ verify) |
| `army down <repo>` | snapshot dirty worktrees, close recorded panes |
| `army status <repo>` | state, seats, integration queue |
| `army verify <repo>` | fail closed when critical seats are missing |
| `army run <repo> --mission f.md` | full mission loop (exclusive `army.lock`) |
| `army resume <repo>` | fast-forward integration/pool to a human-advanced `main`, then run |
| `army arbiter {init-ref\|enqueue\|drain\|promote}` | direct arbiter primitives |

Exit codes: `0` mission complete, `1` error, `20` `MISSION_BLOCKED`
(handoff written).

## Development

```bash
make lint   # shellcheck (0 warnings) + python py_compile
make test   # all tests/test_*.sh + python unittest discover
make check  # lint + test
```

The bash suites and `tests/test_commander_loop.py` run fully offline against
the deterministic mocks in `tests/mocks/` (`herdr`, `pi`). See
[`CLAUDE.md`](CLAUDE.md) for the engineering conventions and safety invariants
that every change must preserve.
