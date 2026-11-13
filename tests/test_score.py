#!/usr/bin/env python3
"""Read-only Stampede session scorer.

The scorer reports whether a trace, session-verdicts, and integration.jsonl
share one session id. It does not drain, promote, or write into the repo.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SHA = "f7284d0301f687399502e675806981f29a8594cc"
SESSION = "swarm-20260919-114508"


def _load_score():
    spec = importlib.util.spec_from_file_location("score", ROOT / "lib" / "score.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _jsonl(rows: list[dict]) -> str:
    return "".join(json.dumps(row) + "\n" for row in rows)


def _fixture(root: Path, *, session_on_ledgers: bool = False, prompt_bytes: int | None = None, looper: dict | None = None) -> None:
    state = root / ".herdr-swarm"
    traces = state / "traces"
    traces.mkdir(parents=True)
    payload = {"suite": "green", "sha": SHA, "summary": "suite green"}
    if prompt_bytes is not None:
        payload["prompt_bytes"] = prompt_bytes
    trace = {
        "timestamp": 1794216419.0,
        "iso": "2026-11-09T09:26:59Z",
        "session_id": SESSION,
        "event_type": "suite.verdict",
        "agent": "arch-1-stampede",
        "ticket_num": "ELIG-1",
        "payload": payload,
    }
    (traces / "swarm-test.jsonl").write_text(_jsonl([trace]))
    verdicts = [
        {
            "ts": 1794216416,
            "ticket": "ELIG-1",
            "sha": SHA,
            "seat": "arch-1-stampede",
            "suite": "green",
            "exit_code": 0,
        },
        {
            "ts": 1794244158,
            "ticket": "ELIG-1",
            "sha": SHA,
            "seat": "arch-1-stampede",
            "suite": "green",
            "verdict": f"INTEGRATED #ELIG-1 {SHA}",
        },
    ]
    integration = [
        {
            "ts": 1794216515,
            "ticket": "ELIG-1",
            "seat": "arch-1-stampede",
            "sha": SHA,
            "status": "integrated",
            "integration_before": "a3a542382a4bc6c2540a99754ad691c80a512bab",
            "merge_sha": SHA,
        }
    ]
    if session_on_ledgers:
        for row in verdicts + integration:
            row["session_id"] = SESSION
    (state / "session-verdicts.jsonl").write_text(_jsonl(verdicts))
    (state / "integration.jsonl").write_text(_jsonl(integration))
    if looper is not None:
        (state / "looper-usage.jsonl").write_text(_jsonl([looper]))


class ScoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="army-score-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.score = _load_score()

    def test_ledgers_without_session_id_do_not_join(self):
        _fixture(self.tmp)
        before = sorted(p.relative_to(self.tmp).as_posix() for p in self.tmp.rglob("*"))
        report = self.score.score_repo(self.tmp)
        after = sorted(p.relative_to(self.tmp).as_posix() for p in self.tmp.rglob("*"))

        self.assertEqual(before, after)
        self.assertFalse(report["same_session"])
        self.assertFalse(report["session_scored"])
        self.assertFalse(report["degraded"])
        self.assertEqual(report["join"]["trace_sessions"], [SESSION])
        self.assertEqual(report["join"]["verdict_sessions"], [])
        self.assertEqual(report["join"]["integration_sessions"], [])
        self.assertEqual(report["join"]["overlap"][0]["ticket"], "ELIG-1")
        self.assertEqual(report["join"]["overlap"][0]["sha"], SHA)
        self.assertEqual(report["join"]["overlap"][0]["trace_sessions"], [SESSION])
        self.assertIn("session_id on session-verdicts.jsonl", report["missing_fields"])
        self.assertIn("session_id on integration.jsonl", report["missing_fields"])
        self.assertIsNone(report["token_effectiveness"]["value"])
        self.assertEqual(report["token_effectiveness"]["numerator"], 1)
        self.assertEqual(report["token_effectiveness"]["worker_denominator"], "missing")
        self.assertEqual(report["token_effectiveness"]["looper_usage_file"], "absent")
        for name in (
            "prompt_bytes",
            "gates_per_ticket",
            "re_verdict_rate",
            "dispatches_per_integration",
            "wall_clock_per_ticket",
        ):
            self.assertFalse(report["proxies"][name]["supported"])
            self.assertNotIn("value", report["proxies"][name])

    def test_pretty_printed_ledger_rows_are_counted(self):
        _fixture(self.tmp)
        state = self.tmp / ".herdr-swarm"
        rows = [
            {
                "ts": 1794216515,
                "ticket": "ELIG-1",
                "seat": "arch-1-stampede",
                "sha": SHA,
                "status": "integrated",
                "merge_sha": SHA,
            },
            {
                "ts": 1794217000,
                "ticket": "ELIG-2",
                "seat": "arch-1-stampede",
                "sha": SHA,
                "status": "promoted",
                "merge_sha": SHA,
            },
        ]
        text = "".join(json.dumps(row, indent=2) + "\n" for row in rows)
        (state / "integration.jsonl").write_text(text)
        report = self.score.score_repo(self.tmp)
        self.assertEqual(report["counts"]["integration"], 2)
        self.assertEqual(report["token_effectiveness"]["numerator"], 1)
        self.assertEqual(report["errors"], [])
        self.assertFalse(report["degraded"])

    def test_promoted_rows_count_in_the_numerator(self):
        _fixture(self.tmp)
        state = self.tmp / ".herdr-swarm"
        row = {
            "ts": 1794216515,
            "ticket": "ELIG-1",
            "seat": "arch-1-stampede",
            "sha": SHA,
            "status": "promoted",
            "merge_sha": SHA,
        }
        (state / "integration.jsonl").write_text(_jsonl([row]))
        report = self.score.score_repo(self.tmp)
        self.assertEqual(report["token_effectiveness"]["numerator"], 1)
        self.assertIn("promoted", report["token_effectiveness"]["numerator_filter"])

    def test_unparseable_ledger_marks_the_report_degraded(self):
        _fixture(self.tmp)
        state = self.tmp / ".herdr-swarm"
        (state / "integration.jsonl").write_text('{"ts": 1,\n"broken\n')
        report = self.score.score_repo(self.tmp)
        self.assertTrue(report["degraded"])
        self.assertIn("unparsed rows in integration.jsonl", report["missing_fields"])
        self.assertEqual(report["counts"]["integration"], 0)

    def test_shared_session_id_joins(self):
        _fixture(self.tmp, session_on_ledgers=True)
        report = self.score.score_repo(self.tmp)
        self.assertTrue(report["same_session"])
        self.assertTrue(report["session_scored"])
        self.assertEqual(report["join"]["verdict_sessions"], [SESSION])
        self.assertEqual(report["join"]["integration_sessions"], [SESSION])
        self.assertNotIn("session_id on session-verdicts.jsonl", report["missing_fields"])

    def test_prompt_bytes_reported_only_when_present(self):
        _fixture(self.tmp, prompt_bytes=180)
        report = self.score.score_repo(self.tmp)
        proxy = report["proxies"]["prompt_bytes"]
        self.assertTrue(proxy["supported"])
        self.assertEqual(proxy["value"], {"min": 180, "max": 180, "n": 1})
        self.assertFalse(report["proxies"]["wall_clock_per_ticket"]["supported"])

    def test_looper_usage_does_not_supply_the_worker_denominator(self):
        _fixture(
            self.tmp,
            looper={
                "ts": 1,
                "ticket": "ELIG-1",
                "event": "assign",
                "model": "agy",
                "usage": {"input_tokens": 10, "output_tokens": 2},
                "num_turns": 1,
            },
        )
        report = self.score.score_repo(self.tmp)
        self.assertEqual(report["token_effectiveness"]["looper_usage_file"], "present")
        self.assertEqual(report["token_effectiveness"]["looper_tokens"], 12)
        self.assertEqual(report["token_effectiveness"]["worker_denominator"], "missing")
        self.assertIsNone(report["token_effectiveness"]["value"])
        self.assertIn("measured token count for worker seats", report["missing_fields"])

    def test_cli_prints_the_report_and_writes_nothing(self):
        _fixture(self.tmp)
        proc = subprocess.run(
            [str(ROOT / "bin" / "army"), "score", str(self.tmp)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        report = json.loads(proc.stdout)
        self.assertFalse(report["same_session"])
        self.assertFalse((self.tmp / ".agent-army").exists())
