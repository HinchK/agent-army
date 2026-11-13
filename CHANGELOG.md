# Changelog

All notable changes to Agent Army are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-13

First release. `army version` prints `1.0.0`.

### Added

- `army setup`, `up`, `down`, `status`, `verify`, `run`, `resume`, `score`,
  `version`, and `arbiter`.
- An out-of-swarm Commander (`pi` or `opencode`) that emits one
  `<commander_decision>` block per wake and never receives a shell.
- A standing pool of credential-free Herdr seats: workers plus one
  independent verifier. Each task starts a fresh agent session.
- A supervisor gate that re-runs the project's `TEST_CMD` on the exact worker
  SHA in a clean environment, requires a verifier audit when a test file
  changes, allows one automatic flake rerun, and scans every new blob for
  secrets.
- An arbiter that drains the green queue in a detached worktree and
  fast-forwards local `main` only after the combined tree passes the same gate.
- Fail-closed halts for a push or merge to `origin/main`, a secret, an
  interactive login, or a production deploy. The halt writes
  `.agent-army/handoff.md` and exits `20`.
- `army score`, a read-only Stampede session report. It counts `integrated`
  and `promoted` rows, accepts pretty-printed JSON objects, and marks the
  report `degraded` when a ledger cannot be parsed.
- Exit codes: `0` complete, `1` error, `20` blocked.

### Fixed

- Seat startup passes `--direction` to `herdr pane split` and reads the new
  pane id from `.result.pane.pane_id`.
- A fresh seat leaves the new pane's shell running so `herdr agent start`
  can find an interactive prompt.
- Seat reuse and the AUTH check read `agent_status` from the live herdr
  envelope.
- A fresh task session clears the previous herdr agent name before starting
  again, so the second start is not rejected as `agent_name_taken`. A new
  pane is left alone until its shell is ready.
- Re-seating one agent no longer copies the previous seat's worktree onto
  the next seat.
- The prompt marker is written before the agent session starts, so a verdict
  written before `herdr agent start` returns is not treated as stale.
- `mission_complete` on an unchanged `main` with nothing promoted is refused.
  A second such declaration stops the mission as `UNCHANGED_MAIN`.

### Compatibility

These stay compatible until 2.0.0: the commands and flags in `army --help`,
the exit codes above, the keys in `army.config.toml.example`, the handoff
path `.agent-army/handoff.md`, and the safety invariants in `CLAUDE.md`.

[1.0.0]: https://github.com/HinchK/agent-army/releases/tag/v1.0.0
