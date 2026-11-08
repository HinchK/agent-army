#!/usr/bin/env python3
"""JSONL-only telemetry logger for agent-army."""

from __future__ import annotations

import datetime
import json
import os
import sys
from typing import Any


def log_event(
    state_dir: str,
    event: str,
    seat: str,
    task_id: str,
    payload: Any = None,
) -> dict[str, Any]:
    os.makedirs(state_dir, exist_ok=True)
    if isinstance(payload, str):
        raw = payload.strip()
        if raw:
            try:
                parsed_payload: Any = json.loads(raw)
            except json.JSONDecodeError:
                parsed_payload = {"raw": payload}
        else:
            parsed_payload = {}
    elif payload is None:
        parsed_payload = {}
    else:
        parsed_payload = payload

    ts = (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    record: dict[str, Any] = {
        "ts": ts,
        "event": event,
        "seat": seat,
        "task_id": task_id,
        "payload": parsed_payload,
    }
    verdicts_path = os.path.join(state_dir, "session-verdicts.jsonl")
    with open(verdicts_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, separators=(",", ":")) + "\n")
    return record


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] != "log":
        sys.stderr.write(
            "Usage: telemetry.py log <state_dir> <event> <seat> <task_id> [payload_json]\n"
        )
        return 1
    if len(argv) < 6:
        sys.stderr.write(
            "Usage: telemetry.py log <state_dir> <event> <seat> <task_id> [payload_json]\n"
        )
        return 1

    state_dir = argv[2]
    event = argv[3]
    seat = argv[4]
    task_id = argv[5]
    payload_raw = argv[6] if len(argv) > 6 else "{}"
    log_event(state_dir, event, seat, task_id, payload_raw)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
