#!/usr/bin/env python3
"""Out-of-swarm Commander loop tests for agent-army.

Runs the real lib/commander.py against a scratch git repo with the
deterministic mocks in tests/mocks/ (herdr + pi) on PATH.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

_spec = importlib.util.spec_from_file_location("commander", ROOT / "lib" / "commander.py")
commander = importlib.util.module_from_spec(_spec)
# dataclasses on 3.11/3.12 look up the class module in sys.modules while
# the class body is still executing. Register first or the import crashes.
sys.modules["commander"] = commander
_spec.loader.exec_module(commander)  # type: ignore[union-attr]


def _run(cmd, cwd=None, env=None, check=True):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"command {cmd} failed rc={proc.returncode}\nstdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc


class CommanderHarness(unittest.TestCase):
    """Shared scratch repo + mock PATH setup."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="army-cmdr-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _run(["git", "init", "-q", "-b", "main"], cwd=self.repo)
        _run(["git", "config", "user.email", "test@example.com"], cwd=self.repo)
        _run(["git", "config", "user.name", "Test User"], cwd=self.repo)
        (self.repo / "Makefile").write_text("test:\n\t@echo ok\n")
        shutil.copy(ROOT / "army.config.toml.example", self.repo / "army.config.toml")
        _run(["git", "add", "-A"], cwd=self.repo)
        _run(["git", "commit", "-qm", "initial"], cwd=self.repo)

        self.mock_dir = self.tmp / "mock"
        (self.mock_dir / "worker-mode").mkdir(parents=True)
        (self.mock_dir / "status").mkdir(parents=True)

        # Stub bin: gh (preflight requires it) — real binaries are preferred
        # when present on PATH.
        self.bin_dir = self.tmp / "bin"
        self.bin_dir.mkdir()
        for tool in ("git", "jq", "gh", "make"):
            real = shutil.which(tool)
            if real:
                os.symlink(real, self.bin_dir / tool)
            else:
                (self.bin_dir / tool).write_text("#!/bin/bash\nexit 0\n")
                (self.bin_dir / tool).chmod(0o755)

        self.mission = self.tmp / "mission.md"
        self.mission.write_text("# Mission\nAdd features a, b, c.\n")

        self.env = dict(os.environ)
        self.env["PATH"] = f"{ROOT / 'tests/mocks'}:{self.bin_dir}:{self.env['PATH']}"
        self.env["HERDR_MOCK_DIR"] = str(self.mock_dir)
        self.env["HERDR_MOCK_REPO"] = str(self.repo)
        self.env["ARMY_SUBMIT_DELAY"] = "0"
        self.env["SUPERVISOR_POLL_SEC"] = "0.2"
        self.env["ARMY_TASK_TIMEOUT_SEC"] = "30"
        self.env["ARMY_TEST_COMMANDER_COUNT"] = str(self.tmp / "pi-count")

        self.decisions = self.tmp / "decisions.txt"

    # -- helpers ------------------------------------------------------------

    def set_decisions(self, *chunks: str):
        self.decisions.write_text("\n%%\n".join(chunks) + "\n")
        self.env["ARMY_TEST_COMMANDER_DECISIONS"] = str(self.decisions)
        count_file = Path(self.env["ARMY_TEST_COMMANDER_COUNT"])
        if count_file.exists():
            count_file.unlink()

    def pi_calls(self) -> int:
        log = self.mock_dir / "pi-calls.log"
        if not log.exists():
            return 0
        return len(log.read_text().splitlines())

    def state(self) -> dict:
        return json.loads((self.repo / ".agent-army" / "state.json").read_text())

    def queue_rows(self) -> list:
        q = self.repo / ".agent-army" / "integration.jsonl"
        if not q.exists():
            return []
        return [json.loads(line) for line in q.read_text().splitlines() if line.strip()]

    def run_mission(self, expect_rc: int = 0) -> subprocess.CompletedProcess:
        proc = _run(
            [
                sys.executable,
                str(ROOT / "lib" / "commander.py"),
                "run",
                str(self.repo),
                "--mission",
                str(self.mission),
            ],
            env=self.env,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            expect_rc,
            f"run_mission rc={proc.returncode} (expected {expect_rc})\n"
            f"stdout: {proc.stdout[-3000:]}\nstderr: {proc.stderr[-3000:]}",
        )
        return proc


DISPATCH_ABC = """<commander_decision action="dispatch_wave">
  <summary>Wave 1: three independent features.</summary>
  <task id="W1-T1" seat="worker_1" verify="none">
    <role>Feature engineer.</role>
    <objective>Implement feature A in src/a.py.</objective>
    <scope><read>README.md</read><owns>src/a.py</owns></scope>
    <gates><done_criteria>src/a.py exists.</done_criteria></gates>
  </task>
  <task id="W1-T2" seat="worker_2" verify="none">
    <role>Feature engineer.</role>
    <objective>Implement feature B in src/b.py.</objective>
    <scope><read>README.md</read><owns>src/b.py</owns></scope>
    <gates><done_criteria>src/b.py exists.</done_criteria></gates>
  </task>
  <task id="W1-T3" seat="worker_2" verify="none">
    <role>Feature engineer.</role>
    <objective>Implement feature C in src/c.py.</objective>
    <scope><read>README.md</read><owns>src/c.py</owns></scope>
    <gates><done_criteria>src/c.py exists.</done_criteria></gates>
  </task>
</commander_decision>"""

COMPLETE = """<commander_decision action="mission_complete">
  <summary>All exit criteria hold.</summary>
</commander_decision>"""


class TestCommanderUnit(CommanderHarness):
    def test_commander_prompt_shows_tracked_file_bodies(self):
        greet = self.repo / "lib" / "greet.sh"
        greet.parent.mkdir()
        greet.write_text("greet() { printf 'hello\\n'; }\n")
        _run(["git", "add", "lib/greet.sh"], cwd=self.repo)
        _run(["git", "commit", "-qm", "greet"], cwd=self.repo)
        prompt = commander._build_commander_prompt(
            self.repo, {}, {"status": "running"}, self.mission
        )
        self.assertIn("### lib/greet.sh", prompt)
        self.assertIn("printf 'hello\\n'", prompt)

    def test_commander_invocation_flags_no_shell(self):
        cfg = {
            "commander_harness": "pi",
            "commander_model": "anthropic/claude-sonnet-4-5",
            "commander_thinking": "high",
            "slug": "proj",
        }
        os.environ["HERDR_PANE_ID"] = "ws1:p9"
        os.environ["HERDR_ENV"] = "1"
        try:
            cmd, env = commander.build_commander_cmd(
                ROOT, self.repo, cfg, self.repo / ".agent-army" / "commander-prompt.md"
            )
        finally:
            del os.environ["HERDR_PANE_ID"]
            del os.environ["HERDR_ENV"]
        self.assertEqual(cmd[0], "pi")
        for flag in ("-p", "--no-tools", "--no-context-files"):
            self.assertIn(flag, cmd)
        self.assertIn("--session", cmd)
        self.assertIn("Emit only the <commander_decision> block.", cmd)
        self.assertNotIn("HERDR_PANE_ID", env)
        self.assertNotIn("HERDR_ENV", env)

        cfg["commander_harness"] = "opencode"
        cmd, env = commander.build_commander_cmd(
            ROOT, self.repo, cfg, self.repo / ".agent-army" / "commander-prompt.md"
        )
        self.assertEqual(cmd[0], "opencode")
        self.assertIn("run", cmd)
        self.assertIn("--agent", cmd)
        i = cmd.index("--agent")
        self.assertEqual(cmd[i + 1], "commander")
        self.assertNotIn("--prompt", cmd)
        self.assertTrue(cmd[-1].startswith("Read "))
        self.assertEqual(
            env.get("OPENCODE_CONFIG"), str(ROOT / "briefs" / "commander.opencode.json")
        )
        self.assertEqual(env.get("OPENCODE_CONFIG_PROJECT_DISABLE"), "1")
        self.assertNotIn("HERDR_PANE_ID", env)

    def test_parse_decision_xml_fences_and_multiple_blocks(self):
        stdout = (
            "Preamble chatter.\n```xml\n"
            "<commander_decision action=\"mission_complete\">\n"
            "  <summary>done</summary>\n"
            "</commander_decision>\n"
            "```\nTrailing chatter.\n"
        )
        decision = commander.parse_decision_xml(stdout)
        self.assertEqual(decision.action, "mission_complete")
        self.assertEqual(decision.summary, "done")

        with self.assertRaises(commander.DecisionParseError):
            commander.parse_decision_xml("no decision here at all")
        two = DISPATCH_ABC.replace("</commander_decision>", "</commander_decision>") + "\n" + COMPLETE
        with self.assertRaises(commander.DecisionParseError):
            commander.parse_decision_xml(two)

        decision = commander.parse_decision_xml(DISPATCH_ABC)
        self.assertEqual(decision.action, "dispatch_wave")
        self.assertEqual(len(decision.tasks), 3)
        self.assertEqual(decision.tasks[0].owns, ["src/a.py"])
        self.assertEqual(decision.tasks[0].verify, "none")

        bad_action = '<commander_decision action="self_destruct"><summary>x</summary></commander_decision>'
        with self.assertRaises(commander.DecisionParseError):
            commander.parse_decision_xml(bad_action)

        traversal = DISPATCH_ABC.replace("<owns>src/a.py</owns>", "<owns>../escape.py</owns>")
        with self.assertRaises(commander.DecisionParseError):
            commander.parse_decision_xml(traversal)

    def test_parse_decision_xml_rejects_unsafe_task_ids(self):
        # task ids are interpolated into anchor/brief paths on the bash side.
        for bad_id in ("1-../../state", "a/b", ".hidden", "-lead", "x y", "z" * 65):
            xml = DISPATCH_ABC.replace('<task id="W1-T1"', f'<task id="{bad_id}"')
            with self.assertRaises(
                commander.DecisionParseError, msg=f"id {bad_id!r} must be rejected"
            ):
                commander.parse_decision_xml(xml)
        good = DISPATCH_ABC.replace('<task id="W1-T1"', '<task id="W1-T1_ok"')
        decision = commander.parse_decision_xml(good)
        self.assertEqual(decision.tasks[0].id, "W1-T1_ok")
        self.assertTrue(all(commander._TASK_ID_RE.fullmatch(t.id) for t in decision.tasks))

    def test_config_env_plumbs_toml_into_subprocess_env(self):
        # Values already in the environment (tests, operators) keep precedence;
        # missing ones are filled from the parsed TOML config.
        env = commander._config_env(
            {"army_task_timeout_sec": "77", "army_max_repairs_per_task": "3"},
            {"PATH": "/bin", "ARMY_TASK_TIMEOUT_SEC": "5"},
        )
        self.assertEqual(env["ARMY_TASK_TIMEOUT_SEC"], "5")
        self.assertEqual(env["ARMY_MAX_REPAIRS_PER_TASK"], "3")
        env = commander._config_env(
            {"army_task_timeout_sec": "", "army_max_repairs_per_task": None}, {}
        )
        self.assertNotIn("ARMY_TASK_TIMEOUT_SEC", env)
        self.assertNotIn("ARMY_MAX_REPAIRS_PER_TASK", env)

    def test_ensure_integration_ref_fails_closed(self):
        # run_mission must not swallow an init-ref failure: with the
        # integration ref absent, the supervisor's secret scan runs
        # rev-list against a missing ref and would pass vacuously.
        env = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp")}
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "r"
            repo.mkdir()
            _run(["git", "init", "-q", "-b", "main"], cwd=repo)
            _run(["git", "config", "user.email", "t@example.com"], cwd=repo)
            _run(["git", "config", "user.name", "T"], cwd=repo)
            # Unborn HEAD: init-ref cannot resolve a base commit and the ref
            # cannot exist -> the guard must fail closed.
            self.assertFalse(commander._ensure_integration_ref(repo, env))
            # With a commit + slug state the guard creates the ref, and then
            # tolerates init-ref's "already exists" refusal on a second call.
            (repo / "README.md").write_text("x\n")
            _run(["git", "add", "-A"], cwd=repo)
            _run(["git", "commit", "-qm", "initial"], cwd=repo)
            state_dir = repo / ".agent-army"
            state_dir.mkdir()
            (state_dir / "state.json").write_text(
                json.dumps({"slug": "guardref", "zero_integrate_waves": 0})
            )
            self.assertTrue(commander._ensure_integration_ref(repo, env))
            probe = _run(
                ["git", "-C", str(repo), "show-ref", "--verify", "--quiet",
                 "refs/heads/army/guardref/integration"],
                check=False, env=env,
            )
            self.assertEqual(probe.returncode, 0)
            self.assertTrue(commander._ensure_integration_ref(repo, env))

    def test_scan_task_security_boundaries(self):
        task = commander.TaskSpec(
            id="T", objective="run gh pr merge 123", owns=["src/a.py"]
        )
        self.assertEqual(commander.scan_task_security_boundaries(task)[0], "GITHUB_MAIN")
        task = commander.TaskSpec(id="T", objective="deploy with vercel --prod", owns=["x"])
        self.assertEqual(commander.scan_task_security_boundaries(task)[0], "DEPLOY")
        task = commander.TaskSpec(id="T", objective="add tests for auth", owns=["tests/x.py"])
        self.assertIsNone(commander.scan_task_security_boundaries(task))

    def test_exclusive_fcntl_army_lock(self):
        state_dir = self.repo / ".agent-army"
        fd = commander.acquire_army_lock(state_dir)
        try:
            with self.assertRaises(commander.ArmyLockError):
                commander.acquire_army_lock(state_dir)
        finally:
            fd.close()
        # After release a second acquisition succeeds.
        fd2 = commander.acquire_army_lock(state_dir)
        fd2.close()


class TestCommanderLoop(CommanderHarness):
    def test_one_task_per_seat_and_overflow_queue(self):
        self.set_decisions(DISPATCH_ABC, COMPLETE)
        self.run_mission(expect_rc=0)

        # Exactly 2 Commander wakes: wave-1 plan + (pending dispatch needs no
        # wake) + mission_complete after wave 2 settles.
        self.assertEqual(self.pi_calls(), 2)

        rows = self.queue_rows()
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(r["status"] == "promoted" for r in rows), rows)
        for path in ("src/a.py", "src/b.py", "src/c.py"):
            self.assertTrue((self.repo / path).exists(), f"{path} missing on main")
        self.assertTrue((self.repo / ".agent-army" / "COMPLETE.md").exists())
        self.assertEqual(self.state().get("status"), "complete")

        # Overflow task went out on wave 2 without waking the Commander: the
        # third brief landed in a worktree under briefs/2-*.
        briefs = sorted(
            p.name
            for p in (self.repo / ".agent-army" / "worktrees").glob("*/.agent-army/briefs/*.xml")
        )
        self.assertEqual(len(briefs), 3, briefs)
        self.assertTrue(any(name.startswith("2-") for name in briefs), briefs)

    def test_mechanical_drain_promote_before_wake(self):
        # A pre-queued GREEN record is drained and promoted mechanically
        # BEFORE the single planning wake that returns mission_complete.
        _run(["/bin/bash", str(ROOT / "lib" / "preflight.sh"), "check",
              str(self.repo), str(self.repo / "army.config.toml")], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "init-ref", str(self.repo)],
             env=self.env)
        main0 = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        _run(["git", "checkout", "-q", "--detach", main0], cwd=self.repo)
        (self.repo / "src").mkdir()
        (self.repo / "src" / "pre.py").write_text("pre\n")
        _run(["git", "add", "src/pre.py"], cwd=self.repo)
        _run(["git", "commit", "-qm", "pre"], cwd=self.repo)
        pre_sha = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        _run(["git", "checkout", "-q", "main"], cwd=self.repo)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "enqueue",
              str(self.repo), "PRE", "worker_1", pre_sha], env=self.env)

        self.set_decisions(COMPLETE)
        self.run_mission(expect_rc=0)
        self.assertEqual(self.pi_calls(), 1)
        rows = self.queue_rows()
        self.assertEqual([r["status"] for r in rows], ["promoted"], rows)
        self.assertTrue((self.repo / "src" / "pre.py").exists())

    def test_mechanical_drain_promote_and_conflict_resolution(self):
        state_dir = self.repo / ".agent-army"
        # Pre-seat the swarm the way run_mission would.
        self.env.setdefault("ARMY_TEST_COMMANDER_DECISIONS", str(self.decisions))
        _run(["/bin/bash", str(ROOT / "lib" / "preflight.sh"), "check",
              str(self.repo), str(self.repo / "army.config.toml")], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "lifecycle.sh"), "up",
              str(self.repo), str(self.repo / "army.config.toml")], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "init-ref", str(self.repo)],
             env=self.env)

        main0 = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        # t1 edits a.py; t2 edits a.py differently (conflicts); t3 edits b.py.
        def branch(name, path, content):
            _run(["git", "checkout", "-q", "--detach", main0], cwd=self.repo)
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text(content + "\n")
            _run(["git", "add", path], cwd=self.repo)
            _run(["git", "commit", "-qm", name], cwd=self.repo)
            sha = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
            _run(["git", "checkout", "-q", "main"], cwd=self.repo)
            return sha

        t1 = branch("t1", "a.py", "one")
        t2 = branch("t2", "a.py", "two")
        t3 = branch("t3", "b.py", "three")
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "enqueue",
              str(self.repo), "T1", "worker_1", t1], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "enqueue",
              str(self.repo), "T2", "worker_2", t2], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "enqueue",
              str(self.repo), "T3", "worker_1", t3], env=self.env)

        resolution = """<commander_decision action="dispatch_wave">
  <summary>Resolve the a.py conflict.</summary>
  <task id="RES-T2" seat="worker_1" verify="none">
    <role>Integration conflict resolver.</role>
    <objective>Resolve a.py onto the integration tip.</objective>
    <scope><read>a.py</read><owns>a.py</owns></scope>
    <gates><done_criteria>a.py resolves cleanly.</done_criteria></gates>
  </task>
</commander_decision>"""
        self.set_decisions(resolution)

        cfg = commander._load_config(self.repo, self.repo / "army.config.toml", {})
        state = commander._load_state(state_dir)
        outcome = commander.drain_and_promote(self.repo, cfg, state, env=self.env)
        self.assertEqual(outcome[0], "ok", outcome)
        self.assertGreaterEqual(outcome[1], 3)

        rows = {r["ticket"]: r["status"] for r in self.queue_rows()}
        self.assertEqual(rows.get("T2"), "superseded", rows)
        for ticket in ("T1", "T3", "RES-T2"):
            self.assertEqual(rows.get(ticket), "promoted", rows)
        self.assertEqual(self.pi_calls(), 1)

        # An invalid resolution decision (mismatched owns) blocks fail-closed.
        q = self.queue_rows()
        self.assertEqual(len(q), 4)

    def test_invalid_resolution_decision_blocks(self):
        state_dir = self.repo / ".agent-army"
        _run(["/bin/bash", str(ROOT / "lib" / "preflight.sh"), "check",
              str(self.repo), str(self.repo / "army.config.toml")], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "lifecycle.sh"), "up",
              str(self.repo), str(self.repo / "army.config.toml")], env=self.env)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "init-ref", str(self.repo)],
             env=self.env)

        main0 = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        _run(["git", "checkout", "-q", "--detach", main0], cwd=self.repo)
        (self.repo / "a.py").write_text("two\n")
        _run(["git", "add", "a.py"], cwd=self.repo)
        _run(["git", "commit", "-qm", "t2"], cwd=self.repo)
        t2 = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        _run(["git", "checkout", "-q", "main"], cwd=self.repo)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "enqueue",
              str(self.repo), "T2", "worker_2", t2], env=self.env)
        # Integration already contains an a.py change so T2 conflicts.
        _run(["git", "checkout", "-q", "--detach", main0], cwd=self.repo)
        (self.repo / "a.py").write_text("one\n")
        _run(["git", "add", "a.py"], cwd=self.repo)
        _run(["git", "commit", "-qm", "t1"], cwd=self.repo)
        t1 = _run(["git", "rev-parse", "HEAD"], cwd=self.repo).stdout.strip()
        _run(["git", "checkout", "-q", "main"], cwd=self.repo)
        # Same ref convention as arbiter.sh _arbiter_ref (refs/heads/army/<slug>/...).
        _run(["git", "update-ref", f"refs/heads/army/{self.state()['slug']}/integration", t1], cwd=self.repo)
        _run(["/bin/bash", str(ROOT / "lib" / "arbiter.sh"), "enqueue",
              str(self.repo), "T1", "worker_1", t1], env=self.env)

        wrong_owns = """<commander_decision action="dispatch_wave">
  <summary>Resolution with the wrong owns.</summary>
  <task id="RES-X" seat="worker_1" verify="none">
    <role>Resolver.</role>
    <objective>Fix zzz.py.</objective>
    <scope><read>zzz.py</read><owns>zzz.py</owns></scope>
    <gates><done_criteria>resolved</done_criteria></gates>
  </task>
</commander_decision>"""
        self.set_decisions(wrong_owns)

        cfg = commander._load_config(self.repo, self.repo / "army.config.toml", {})
        state = commander._load_state(state_dir)
        outcome = commander.drain_and_promote(self.repo, cfg, state, env=self.env)
        self.assertEqual(outcome[0], "blocked", outcome)
        handoff = self.repo / ".agent-army" / "handoff.md"
        self.assertTrue(handoff.exists())
        self.assertIn("CONFLICT_RESOLUTION_INVALID", handoff.read_text())

    def test_unchanged_main_is_not_mission_complete(self):
        state_dir = self.repo / ".agent-army"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "MISSION_STATE.md").write_text(
            "# Mission State\n\n- status: complete\n- waves supervised: 0\n"
        )
        self.set_decisions(COMPLETE, COMPLETE)
        self.run_mission(expect_rc=20)
        self.assertFalse((state_dir / "COMPLETE.md").exists())
        handoff = (state_dir / "handoff.md").read_text()
        self.assertIn("UNCHANGED_MAIN", handoff)
        prompt = (state_dir / "commander-prompt.md").read_text()
        self.assertNotIn("- status: complete", prompt)
        self.assertIn("- status: running", prompt)
        self.assertEqual(self.pi_calls(), 2)

    def test_zero_integrate_waves_halts_at_two(self):
        no_commit_wave = """<commander_decision action="dispatch_wave">
  <summary>Failing wave.</summary>
  <task id="W{n}-T1" seat="worker_1" verify="none">
    <role>Worker.</role>
    <objective>Do nothing useful.</objective>
    <scope><read>README.md</read><owns>src/f{n}.py</owns></scope>
    <gates><done_criteria>never</done_criteria></gates>
  </task>
</commander_decision>"""
        self.set_decisions(
            no_commit_wave.format(n=1),
            no_commit_wave.format(n=2),
        )
        (self.mock_dir / "worker-mode").mkdir(exist_ok=True)
        for n in (1, 2):
            (self.mock_dir / "worker-mode" / f"W{n}-T1").write_text("no-commit\n")

        self.run_mission(expect_rc=20)
        handoff = self.repo / ".agent-army" / "handoff.md"
        self.assertTrue(handoff.exists())
        self.assertIn("NO_PROGRESS", handoff.read_text())
        self.assertEqual(self.state().get("zero_integrate_waves"), 2)
        self.assertEqual(self.pi_calls(), 2)

    def test_resume_advances_integration_ref_after_human_commit(self):
        blocked = """<commander_decision action="mission_blocked">
  <summary>Auth boundary encountered.</summary>
  <boundary>AUTH</boundary>
  <reason>gh auth login is required to inspect the remote.</reason>
</commander_decision>"""
        self.set_decisions(blocked, COMPLETE)
        self.run_mission(expect_rc=20)
        slug = self.state()["slug"]
        ref = f"refs/heads/army/{slug}/integration"
        old_tip = _run(["git", "rev-parse", ref], cwd=self.repo).stdout.strip()

        # Human resolves the boundary with a direct commit on main.
        (self.repo / "human-fix.txt").write_text("resolved by human\n")
        _run(["git", "add", "human-fix.txt"], cwd=self.repo)
        _run(["git", "commit", "-qm", "human: resolve boundary"], cwd=self.repo)
        new_main = _run(["git", "rev-parse", "main"], cwd=self.repo).stdout.strip()

        proc = _run(
            [
                sys.executable,
                str(ROOT / "lib" / "commander.py"),
                "resume",
                str(self.repo),
            ],
            env=self.env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        new_tip = _run(["git", "rev-parse", ref], cwd=self.repo).stdout.strip()
        self.assertEqual(new_tip, new_main)
        self.assertNotEqual(new_tip, old_tip)
        self.assertEqual(self.state().get("zero_integrate_waves"), 0)
        self.assertTrue((self.repo / ".agent-army" / "COMPLETE.md").exists())
        for seat in ("worker_1", "worker_2", "verifier"):
            wt = self.repo / ".agent-army" / "worktrees" / seat
            head = _run(["git", "rev-parse", "HEAD"], cwd=wt).stdout.strip()
            self.assertEqual(head, new_main, f"{seat} worktree not synced")


if __name__ == "__main__":
    unittest.main()
