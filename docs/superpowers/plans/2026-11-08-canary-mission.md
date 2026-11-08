# Canary mission

> Operator runbook. No product code changes. Execute top to bottom. Stop at the first red check and read the handoff before changing `agent-army`.

**Goal:** One live `army run` Promotes a disposable change onto local `main` of a new repo, leaves `origin` untouched, and exits 0.

**Locked decisions:** Ledger, gate, and operator hold trust (`docs/adr/0001-ledger-gate-and-operator.md`). Promote is mechanical and local. Publish is the operator's. The CLI stays as merged on `main`. The target is a new one-test repo. The mission is a Canary. Seats are one worker, one verifier, and a `pi` Commander.

## What a pass is

All of these:

- `bin/army run` exits 0.
- `/Users/hinchk/agent-army-advancement/canary/.agent-army/COMPLETE.md` exists.
- `main` has moved past the seed commit, and `make test` passes on that `main`.
- `git remote` prints nothing.
- `lib/greet.sh` implements `greet` with no args (`hello`) and `greet Ada` (`hello Ada`). The test covers both.

A pass proves seating, one Commander plan wake, one worker commit, the gate, the verifier (the test file changes), Promote, a second Commander wake that declares `mission_complete`, and the final gate. It does not prove a second worker, a draft PR, a security-boundary halt, or any of the parked research work.

## Preconditions found on this machine

- `herdr`, `pi`, `opencode`, `claude`, `gh`, and `jq` are on `PATH`. `pi` accepts `--no-tools` and `--no-context-files`.
- Herdr is running. `herdr workspace list` shows workspace `w1R` (label `~`, one pane). No workspace is bound to the canary path yet. `army up` falls back to `herdr pane split` in the current workspace.
- `pi auth check --provider anthropic` and `--provider google` both return `credentials_not_configured`. The example Commander model `anthropic/claude-sonnet-4-5` will not wake until some provider is ready.

## Out of scope

Fork-and-Flush, a harness evolver, an injection red-team, a second-model critic, a lead-only measurement bench, the eight deferred review nits, packaging for other people, and any edit to `agent-army` before this run has a result. `briefs/commander.sys.md` still says the Commander holds mission truth. That wording disagrees with the glossary and ADR 0001. Leave it until the canary has a result.

---

## 1. Authenticate the Commander

- [ ] Choose a provider and model `pi` can already call. Check it:

```bash
pi auth check --model <provider/model> --json
```

The status has to be ready. Do not start the run on `credentials_not_configured`.

- [ ] Confirm the worker and verifier CLIs can start at all (`opencode`, `claude`). Their auth lives in those tools. If either refuses to start, fix that before `army run`. This plan does not switch kinds.

## 2. Create the target repo

Path: `/Users/hinchk/agent-army-advancement/canary`. It is a sibling of `agent-army`, not a folder inside it. No remote.

- [ ] Create the seed that already passes `make test`.

`lib/greet.sh`:

```bash
#!/bin/bash
greet() {
  printf 'hello\n'
}
```

`tests/test_greet.sh`:

```bash
#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/greet.sh"
got="$(greet)"
if [ "$got" != "hello" ]; then
  echo "FAIL: got '$got'" >&2
  exit 1
fi
echo OK
```

`Makefile`:

```makefile
SHELL := /bin/bash
.PHONY: test
test:
	@/bin/bash tests/test_greet.sh
```

- [ ] Commit it on `main` and prove the gate command:

```bash
git init -b main
git add Makefile lib/greet.sh tests/test_greet.sh
git commit -m "Seed a passing greet test."
make test
git status --porcelain
git remote
```

`make test` prints `OK`. Porcelain is empty. Remote is empty. Record the seed SHA (`git rev-parse HEAD`).

## 3. Write the mission

- [ ] Write `mission.md` in the canary root. Leave it untracked. Preflight allows untracked `mission.md` and `army.config.toml` and rejects any other dirt.

```markdown
# Mission

Teach greet to take a name.

Exit criteria, all required on local main:

- greet with no arguments prints hello.
- greet Ada prints hello Ada.
- tests/test_greet.sh covers both cases, and make test passes.
- The only files that change are lib/greet.sh and tests/test_greet.sh.

When those hold, declare the mission complete.
Do not push and do not open a pull request.
```

Keep those words. The security scanner blocks a task whose text matches a deploy, a secret, an interactive login, or a push to `origin/main`.

## 4. Configure the smallest pool

- [ ] From the `agent-army` repo:

```bash
bin/army setup /Users/hinchk/agent-army-advancement/canary
```

- [ ] Edit the generated `army.config.toml` to this shape. Put the ready model from step 1 in `commander.model`. Drop `worker_2`.

```toml
[army]
name = "canary"
base_branch = "main"
max_waves = 3
max_repairs_per_task = 1
task_timeout_sec = 1800
create_draft_pr_on_complete = false

[commander]
harness = "pi"
model = "<provider/model from step 1>"
thinking = "high"
timeout_sec = 600

[seats.worker_1]
kind = "opencode"
model = "zai-coding-plan/glm-5.3"
role = "worker"
worktree = true
critical = true

[seats.verifier]
kind = "claude"
model = "sonnet"
role = "verifier"
worktree = true
critical = true
```

`max_waves = 3` bounds a confused Commander. One wave of work plus the completion wake fits. `create_draft_pr_on_complete = false` keeps the run from pushing. There is no remote anyway.

- [ ] Preflight only:

```bash
bin/army verify /Users/hinchk/agent-army-advancement/canary
```

Expect failure here if seats are not up yet (`verify` fails closed when critical seats are missing). That failure is fine before `run`. A preflight failure about branch, dirt, or `TEST_CMD` is not fine. Check those with:

```bash
/bin/bash lib/preflight.sh check /Users/hinchk/agent-army-advancement/canary
```

Run that from the `agent-army` repo. It must exit 0 before the mission.

## 5. Run

- [ ] Start the mission and leave it in the foreground:

```bash
bin/army run /Users/hinchk/agent-army-advancement/canary \
  --mission /Users/hinchk/agent-army-advancement/canary/mission.md \
  --commander pi
```

Expect two Commander wakes. The first dispatches one task for `worker_1`. The test file change forces the verifier. After the gate is green, Promote fast-forwards the canary's local `main`. The second wake should be `mission_complete`. Then the final `make test` runs on that `main`.

Watch Herdr. `army up` splits a worker pane and a verifier pane. Pane-id parsing has never been proven against live `herdr pane split` output. A failure there exits 1 before any model work.

## 6. Judge

- [ ] On exit 0, confirm the pass list above. Compare `git rev-parse HEAD` to the seed SHA. Read `.agent-army/COMPLETE.md`. Run `make test` once yourself on `main`.

- [ ] On exit 20, read `.agent-army/handoff.md` and stop. Resume only when the handoff names a step you have actually done. Two waves that Promote nothing also exit 20 (`NO_PROGRESS`).

- [ ] On exit 1, the loop failed mechanically. Likely causes, in order: `pi` auth, `herdr pane split` output that `_parse_pane_id` cannot read, or the worker or verifier CLI not becoming ready. Capture the stderr. Do not patch `agent-army` in the same breath as the failed run. The next change is the one fix that stderr names.

## After a pass

The next product decision is which real repo gets a mission. The Commander brief's "holds mission truth" sentence is the first doc correction, and it is still outside this run.
