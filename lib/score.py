#!/usr/bin/env python3
"""Read-only scorer for a Stampede checkout.

Reads `.herdr-swarm` traces, session-verdicts, and integration.jsonl.
Prints a report. Does not drain, promote, or write.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


DEFINITION = "verified integrated tickets per measured token"

PROXY_MISSING = {
    "prompt_bytes": ["prompt byte length"],
    "gates_per_ticket": [
        "suite exit_code on integration.jsonl",
        "reviewer suite runs",
    ],
    "re_verdict_rate": ["a second suite gate on the same ticket"],
    "dispatches_per_integration": ["integration cycle id"],
    "wall_clock_per_ticket": ["active versus idle marker"],
}


def _load_jsonl(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not path.is_file():
        return [], []
    rows: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as exc:
                errors.append({"file": path.name, "line": number, "error": str(exc)})
                continue
            if isinstance(parsed, dict):
                rows.append(parsed)
            else:
                errors.append({"file": path.name, "line": number, "error": "row is not an object"})
    return rows, errors


def _session_ids(rows: list[dict[str, Any]]) -> tuple[list[str], int]:
    found: list[str] = []
    absent = 0
    for row in rows:
        sid = row.get("session_id")
        if isinstance(sid, str) and sid:
            if sid not in found:
                found.append(sid)
        else:
            absent += 1
    return found, absent


def _event_ticket(event: dict[str, Any]) -> str:
    ticket = event.get("ticket_num")
    if ticket is None:
        payload = event.get("payload")
        if isinstance(payload, dict):
            ticket = payload.get("ticket")
    return "" if ticket is None else str(ticket)


def _event_sha(event: dict[str, Any]) -> str:
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return ""
    sha = payload.get("sha") or payload.get("merge_sha") or ""
    return str(sha) if sha else ""


def _overlap(
    events: list[dict[str, Any]],
    verdicts: list[dict[str, Any]],
    integration: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    pairs: list[tuple[str, str]] = []
    for row in verdicts + integration:
        ticket = str(row.get("ticket") or "")
        sha = str(row.get("sha") or "")
        if ticket and sha and (ticket, sha) not in pairs:
            pairs.append((ticket, sha))
    found: list[dict[str, Any]] = []
    for ticket, sha in pairs:
        sessions: list[str] = []
        for event in events:
            if _event_ticket(event) != ticket or _event_sha(event) != sha:
                continue
            sid = event.get("session_id")
            if isinstance(sid, str) and sid and sid not in sessions:
                sessions.append(sid)
        if sessions:
            found.append({"ticket": ticket, "sha": sha, "trace_sessions": sessions})
    return found


def _verified_tickets(
    verdicts: list[dict[str, Any]], integration: list[dict[str, Any]]
) -> int:
    green: dict[str, set[str]] = {}
    for row in verdicts:
        if row.get("suite") == "green" and row.get("exit_code") == 0:
            ticket = str(row.get("ticket") or "")
            sha = str(row.get("sha") or "")
            if ticket and sha:
                green.setdefault(ticket, set()).add(sha)
    seen: set[str] = set()
    for row in integration:
        if row.get("status") != "integrated":
            continue
        ticket = str(row.get("ticket") or "")
        sha = str(row.get("sha") or "")
        if ticket in green and sha in green[ticket]:
            seen.add(ticket)
    return len(seen)


def _usage_tokens(usage: Any) -> int | None:
    if not isinstance(usage, dict):
        return None
    parts = [usage.get("input_tokens"), usage.get("output_tokens")]
    if any(isinstance(part, (int, float)) for part in parts):
        total = 0
        for part in parts:
            if isinstance(part, (int, float)):
                total += int(part)
        return total
    total_tokens = usage.get("total_tokens")
    if isinstance(total_tokens, (int, float)):
        return int(total_tokens)
    return None


def _looper_tokens(rows: list[dict[str, Any]]) -> int | None:
    found = False
    total = 0
    for row in rows:
        counted = _usage_tokens(row.get("usage"))
        if counted is None:
            continue
        found = True
        total += counted
    return total if found else None


def _prompt_bytes(events: list[dict[str, Any]]) -> dict[str, Any]:
    values: list[int] = []
    for event in events:
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue
        raw = payload.get("prompt_bytes")
        if isinstance(raw, (int, float)):
            values.append(int(raw))
    if not values:
        return {"supported": False, "missing": list(PROXY_MISSING["prompt_bytes"])}
    return {"supported": True, "value": {"min": min(values), "max": max(values), "n": len(values)}}


def _unsupported(name: str) -> dict[str, Any]:
    return {"supported": False, "missing": list(PROXY_MISSING[name])}


def score_repo(repo_dir: Path) -> dict[str, Any]:
    state = Path(repo_dir) / ".herdr-swarm"
    traces_dir = state / "traces"
    events: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    if traces_dir.is_dir():
        for path in sorted(traces_dir.glob("*.jsonl")):
            loaded, failed = _load_jsonl(path)
            events.extend(loaded)
            errors.extend(failed)
    else:
        errors.append({"file": "traces", "error": "missing"})

    verdicts, verdict_errors = _load_jsonl(state / "session-verdicts.jsonl")
    integration, integration_errors = _load_jsonl(state / "integration.jsonl")
    looper_path = state / "looper-usage.jsonl"
    looper_rows, looper_errors = _load_jsonl(looper_path)
    errors.extend(verdict_errors + integration_errors + looper_errors)

    trace_sessions, _trace_absent = _session_ids(events)
    verdict_sessions, verdict_absent = _session_ids(verdicts)
    integration_sessions, integration_absent = _session_ids(integration)

    one_session = len(trace_sessions) == 1
    ledgers_complete = bool(verdicts) and bool(integration) and verdict_absent == 0 and integration_absent == 0
    same = (
        one_session
        and ledgers_complete
        and verdict_sessions == trace_sessions
        and integration_sessions == trace_sessions
    )

    missing: list[str] = []
    if not (state / "session-verdicts.jsonl").is_file() or verdict_absent:
        missing.append("session_id on session-verdicts.jsonl")
    if not (state / "integration.jsonl").is_file() or integration_absent:
        missing.append("session_id on integration.jsonl")
    missing.append("measured token count for worker seats")
    if not looper_path.is_file():
        missing.append("looper-usage.jsonl")

    proxies = {
        "prompt_bytes": _prompt_bytes(events),
        "gates_per_ticket": _unsupported("gates_per_ticket"),
        "re_verdict_rate": _unsupported("re_verdict_rate"),
        "dispatches_per_integration": _unsupported("dispatches_per_integration"),
        "wall_clock_per_ticket": _unsupported("wall_clock_per_ticket"),
    }
    for proxy in proxies.values():
        if proxy.get("supported"):
            continue
        for field in proxy.get("missing", []):
            if field not in missing:
                missing.append(field)

    looper_tokens = _looper_tokens(looper_rows)
    token: dict[str, Any] = {
        "definition": DEFINITION,
        "numerator": _verified_tickets(verdicts, integration),
        "numerator_scope": (
            "session" if same else "ledger ticket and sha match, not session-scoped"
        ),
        "denominator": None,
        "value": None,
        "worker_denominator": "missing",
        "looper_usage_file": "present" if looper_path.is_file() else "absent",
    }
    if looper_tokens is not None:
        token["looper_tokens"] = looper_tokens

    if same:
        reason = f"trace, verdicts, and integration share session_id {trace_sessions[0]}"
    elif verdict_absent or integration_absent:
        reason = "session_id is absent on session-verdicts.jsonl and integration.jsonl"
    else:
        reason = "the three sources do not share one session_id"

    return {
        "same_session": same,
        "session_scored": same,
        "join": {
            "trace_sessions": trace_sessions,
            "verdict_sessions": verdict_sessions,
            "integration_sessions": integration_sessions,
            "reason": reason,
            "overlap": _overlap(events, verdicts, integration),
        },
        "proxies": proxies,
        "token_effectiveness": token,
        "missing_fields": missing,
        "errors": errors,
        "counts": {
            "trace_events": len(events),
            "verdicts": len(verdicts),
            "integration": len(integration),
        },
    }


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("usage: score.py <repo>", file=sys.stderr)
        return 1
    repo = Path(args[0])
    state = repo / ".herdr-swarm"
    if not state.is_dir():
        print(f"score: no .herdr-swarm in {repo}", file=sys.stderr)
        return 1
    json.dump(score_repo(repo), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
