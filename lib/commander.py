#!/usr/bin/env python3
"""Out-of-swarm Commander engine for agent-army.

The Commander agent (pi or opencode) runs outside the Herdr swarm with
HERDR_PANE_ID/HERDR_ENV stripped and no shell/edit/write tools. It emits one
<commander_decision> XML block; this module parses that block, dispatches
LARP XML briefs to worker seats, supervises waves mechanically, and owns the
drain -> promote -> worktree-sync integration cycle between waves. Model text
is never passed to a shell: only the parsed decision's validated fields drive
the bash libraries in lib/.
"""

from __future__ import annotations

import argparse
import datetime
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ARMY_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = ARMY_ROOT / "lib"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_MISSION_BLOCKED = 20

BOUNDARY_CODES = ("GITHUB_MAIN", "SECRET", "AUTH", "DEPLOY")


class ArmyLockError(RuntimeError):
    """Another army run already holds .agent-army/army.lock."""


class DecisionParseError(ValueError):
    """Commander stdout did not contain exactly one valid decision block."""


@dataclass
class TaskSpec:
    id: str
    seat: str = ""
    verify: str = "none"
    role: str = ""
    objective: str = ""
    read: List[str] = field(default_factory=list)
    owns: List[str] = field(default_factory=list)
    forbidden: str = ""
    done_criteria: str = ""


@dataclass
class CommanderDecision:
    action: str
    summary: str = ""
    boundary: str = ""
    reason: str = ""
    tasks: List[TaskSpec] = field(default_factory=list)


# --- lock -------------------------------------------------------------------


def acquire_army_lock(state_dir: Path):
    """Takes an exclusive fcntl lock on <state_dir>/army.lock (macOS has no
    flock(1)); raises ArmyLockError when another run holds it."""
    state_dir.mkdir(parents=True, exist_ok=True)
    fd = open(state_dir / "army.lock", "a+")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        fd.close()
        raise ArmyLockError(
            f"another army run already holds {state_dir / 'army.lock'}"
        ) from exc
    return fd


# --- commander invocation ---------------------------------------------------


def _slug_from_state(repo_dir: Path) -> str:
    state_file = repo_dir / ".agent-army" / "state.json"
    data = json.loads(state_file.read_text())
    slug = data.get("slug")
    if not slug:
        raise RuntimeError(f"missing slug in {state_file}")
    return slug


def build_commander_cmd(
    army_root: Path,
    repo_dir: Path,
    cfg: Dict[str, Any],
    prompt_file: Path,
    base_env: Optional[Dict[str, str]] = None,
) -> Tuple[List[str], Dict[str, str]]:
    """Builds the harness command line + env for one Commander wake.

    The Commander process runs with HERDR_PANE_ID and HERDR_ENV stripped so it
    never occupies a worker pane. pi runs --no-tools --no-context-files;
    opencode runs --agent commander under a config that denies every tool but
    read, with project config loading disabled so the target repo cannot hand
    tools back.
    """
    source_env = base_env if base_env is not None else os.environ
    env = {k: v for k, v in source_env.items() if k not in ("HERDR_PANE_ID", "HERDR_ENV")}
    state_dir = repo_dir / ".agent-army"
    harness = cfg.get("commander_harness", "pi")
    if harness == "pi":
        cmd = [
            "pi",
            "-p",
            "--no-tools",
            "--no-context-files",
            "--session",
            str(state_dir / "commander-session.jsonl"),
            "--model",
            str(cfg.get("commander_model", "")),
            "--thinking",
            str(cfg.get("commander_thinking", "high")),
            "--append-system-prompt",
            str(prompt_file),
            "Emit only the <commander_decision> block.",
        ]
    elif harness == "opencode":
        env["OPENCODE_CONFIG"] = str(army_root / "briefs" / "commander.opencode.json")
        env["OPENCODE_CONFIG_PROJECT_DISABLE"] = "1"
        session_id = f"commander-{cfg.get('slug', 'army')}"
        cmd = [
            "opencode",
            "run",
            "--session",
            session_id,
            "--agent",
            "commander",
            f"Read {prompt_file} and emit only the <commander_decision> block.",
        ]
    else:
        raise ValueError(f"unsupported commander harness: {harness!r}")
    return cmd, env


# --- decision parsing -------------------------------------------------------

_DECISION_RE = re.compile(r"<commander_decision\b.*?</commander_decision>", re.DOTALL)
_ENUM_ACTIONS = ("dispatch_wave", "mission_complete", "mission_blocked")
_ENUM_VERIFY = ("none", "asymmetric")
# Task ids are interpolated into anchor/brief file paths on the bash side
# (briefs.sh, supervisor.sh): a '/' or '..' would escape those directories.
_TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")


def _csv_list(raw: Optional[str]) -> List[str]:
    return [part.strip() for part in (raw or "").split(",") if part.strip()]


def _valid_own(path: str) -> bool:
    if not path or path == ".." or path.startswith("../") or "/../" in f"/{path}/":
        return False
    if path.startswith("/") or path == ".agent-army" or path.startswith(".agent-army/"):
        return False
    return True


def parse_decision_xml(stdout: str) -> CommanderDecision:
    """Extracts exactly one <commander_decision> block from raw model stdout.

    Markdown fences and surrounding chatter are tolerated because the tags are
    located directly; zero or multiple blocks raise DecisionParseError.
    """
    matches = _DECISION_RE.findall(stdout or "")
    if len(matches) != 1:
        raise DecisionParseError(
            f"expected exactly 1 <commander_decision> block, found {len(matches)}"
        )
    try:
        root = ET.fromstring(matches[0])
    except ET.ParseError as exc:
        raise DecisionParseError(f"decision block is not well-formed XML: {exc}") from exc

    action = root.get("action", "")
    if action not in _ENUM_ACTIONS:
        raise DecisionParseError(f"invalid action {action!r} (expected one of {_ENUM_ACTIONS})")

    decision = CommanderDecision(
        action=action,
        summary=(root.findtext("summary") or "").strip(),
        boundary=(root.findtext("boundary") or "").strip(),
        reason=(root.findtext("reason") or "").strip(),
    )

    for node in root.findall("task"):
        spec = TaskSpec(
            id=(node.get("id") or "").strip(),
            seat=(node.get("seat") or "").strip(),
            verify=(node.get("verify") or "none").strip(),
            role=(node.findtext("role") or "").strip(),
            objective=(node.findtext("objective") or "").strip(),
            read=_csv_list(node.findtext("scope/read")),
            owns=_csv_list(node.findtext("scope/owns")),
            forbidden=(node.findtext("scope/forbidden") or "").strip(),
            done_criteria=(node.findtext("gates/done_criteria") or "").strip(),
        )
        if not spec.id:
            raise DecisionParseError("task element missing id")
        if not _TASK_ID_RE.fullmatch(spec.id):
            raise DecisionParseError(
                f"task id {spec.id!r} must be 1-64 chars of [A-Za-z0-9_-] "
                "starting with an alphanumeric (it is used in file paths)"
            )
        if not spec.owns:
            raise DecisionParseError(f"task {spec.id} has an empty scope/owns")
        if spec.verify not in _ENUM_VERIFY:
            raise DecisionParseError(
                f"task {spec.id} has invalid verify {spec.verify!r} (expected one of {_ENUM_VERIFY})"
            )
        for own in spec.owns:
            if not _valid_own(own):
                raise DecisionParseError(f"task {spec.id} has invalid owns path {own!r}")
        decision.tasks.append(spec)

    if action == "dispatch_wave" and not decision.tasks:
        raise DecisionParseError("dispatch_wave decision carries no tasks")
    return decision


# --- security boundaries ----------------------------------------------------

_BOUNDARY_PATTERNS: List[Tuple[str, str]] = [
    ("GITHUB_MAIN", r"gh pr merge|git push origin (?:main|master)|push --force|force[- ]push"),
    ("SECRET", r"\.env\b|\.env\.|private key|\.pem\b|\.aws\b|credential"),
    ("AUTH", r"auth login|oauth|\bsso\b|\b2fa\b|two[- ]factor"),
    ("DEPLOY", r"terraform apply|kubectl apply|fly deploy|vercel --prod|npm publish"),
]


def scan_task_security_boundaries(task: TaskSpec) -> Optional[Tuple[str, str]]:
    """Returns (boundary, evidence) when a task asks a worker to cross one."""
    text = " ".join(
        [task.objective, " ".join(task.read), " ".join(task.owns), task.forbidden, task.done_criteria]
    ).lower()
    for boundary, pattern in _BOUNDARY_PATTERNS:
        match = re.search(pattern, text)
        if match:
            return boundary, match.group(0)
    return None


# --- handoff ----------------------------------------------------------------


def write_handoff(
    repo_dir: Path,
    boundary: str,
    reason: str,
    required_action: str,
    state: Dict[str, Any],
) -> Path:
    state_dir = repo_dir / ".agent-army"
    state_dir.mkdir(parents=True, exist_ok=True)
    path = state_dir / "handoff.md"
    slug = state.get("slug", "unknown")
    lines = [
        "# Agent-Army Handoff (MISSION_BLOCKED)",
        "",
        f"**Boundary Triggered:** `{boundary}`",
        "",
        "**Reason:**",
        "",
        reason or "(none recorded)",
        "",
        "**Progress So Far:**",
        "",
        f"- Waves supervised: {state.get('wave', 0)}",
        f"- Integration ref: `refs/heads/army/{slug}/integration`",
        f"- zero_integrate_waves: {state.get('zero_integrate_waves', 0)}",
        "",
        "**Exact Action Required from Human:**",
        "",
        required_action or "(inspect the repository state and decide)",
        "",
        "**How to Resume:**",
        "",
        f"    army resume {repo_dir}",
        "",
    ]
    path.write_text("\n".join(lines))
    state["status"] = "blocked"
    state["boundary"] = boundary
    state["blocked_reason"] = reason
    return path


# --- state ------------------------------------------------------------------


def _load_state(state_dir: Path) -> Dict[str, Any]:
    state_file = state_dir / "state.json"
    data = json.loads(state_file.read_text())
    data.setdefault("wave", 0)
    data.setdefault("zero_integrate_waves", 0)
    data.setdefault("pending_tasks", [])
    data.setdefault("receipts", [])
    data.setdefault("status", "idle")
    return data


def _save_state(state_dir: Path, state: Dict[str, Any]) -> None:
    state_file = state_dir / "state.json"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = state_file.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    tmp.replace(state_file)


def _load_config(repo_dir: Path, config_path: Path, overrides: Dict[str, Any]) -> Dict[str, Any]:
    """Parses army.config.toml via lib/config.sh dump + applies overrides."""
    proc = subprocess.run(
        ["/bin/bash", str(LIB_DIR / "config.sh"), "dump", str(config_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    cfg: Dict[str, Any] = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("export "):
            continue
        key, _, value = line[len("export "):].partition("=")
        try:
            cfg[key.lower()] = shlex.split(value)[0] if value else ""
        except ValueError:
            cfg[key.lower()] = value.strip("\"'")
    cfg.update({k.lower(): v for k, v in (overrides or {}).items()})
    cfg["slug"] = _slug_from_state(repo_dir)
    return cfg


def _config_env(cfg: Dict[str, Any], env: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """Merges operator TOML config into the subprocess environment.

    lib/supervisor.sh and lib/arbiter.sh read ARMY_TASK_TIMEOUT_SEC and
    ARMY_MAX_REPAIRS_PER_TASK from their process env; without this merge the
    `army run` path silently ran every worker task on the hardwired defaults
    no matter what the operator wrote in army.config.toml. Values already
    present in the environment (tests, operators) keep precedence.
    """
    merged = dict(os.environ if env is None else env)
    for cfg_key, env_key in (
        ("army_task_timeout_sec", "ARMY_TASK_TIMEOUT_SEC"),
        ("army_max_repairs_per_task", "ARMY_MAX_REPAIRS_PER_TASK"),
    ):
        value = str(cfg.get(cfg_key, "") or "")
        if value and env_key not in merged:
            merged[env_key] = value
    return merged


def _ensure_integration_ref(repo_dir: Path, env: Dict[str, str]) -> bool:
    """arbiter_init-ref refuses when the ref already exists (rc 1). Any other
    outcome must still leave a resolvable integration ref: with the ref
    absent, supervisor_scan_secrets enumerates a missing range and would
    return a vacuous clean verdict, silently disabling the SECRET boundary —
    so the mission aborts instead of swallowing the failure."""
    init = _bash("arbiter.sh", ["init-ref", str(repo_dir)], env)
    if init.returncode == 0:
        return True
    try:
        state = _load_state(repo_dir / ".agent-army")
    except FileNotFoundError:
        return False
    slug = state.get("slug", "")
    if not slug:
        return False
    probe = subprocess.run(
        [
            "git",
            "-C",
            str(repo_dir),
            "show-ref",
            "--verify",
            "--quiet",
            f"refs/heads/army/{slug}/integration",
        ],
        env=env,
        capture_output=True,
    )
    return probe.returncode == 0


def _bash(script: str, args: List[str], env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/bash", str(LIB_DIR / script)] + args,
        capture_output=True,
        text=True,
        env=env,
    )


def _bash_ok(script: str, args: List[str], env: Optional[Dict[str, str]] = None) -> bool:
    return _bash(script, args, env).returncode == 0


def _git(repo_dir: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo_dir), *args], capture_output=True, text=True, check=True
    )
    return proc.stdout.strip()


def _profile_test_cmd(repo_dir: Path) -> str:
    proc = subprocess.run(
        ["/bin/bash", "-c", 'source "$1" >/dev/null 2>&1; printf "%s" "${TEST_CMD:-}"',
         "_", str(repo_dir / ".agent-army" / "profile.env")],
        capture_output=True,
        text=True,
    )
    return proc.stdout.strip() or "make test"


def _queue_rows(repo_dir: Path) -> List[Dict[str, Any]]:
    q = repo_dir / ".agent-army" / "integration.jsonl"
    if not q.exists():
        return []
    rows = []
    for line in q.read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def _has_queued(repo_dir: Path) -> bool:
    return any(r.get("status") == "queued" for r in _queue_rows(repo_dir))


def _worker_seats(repo_dir: Path) -> List[str]:
    seats_file = repo_dir / ".agent-army" / "seats.json"
    if not seats_file.exists():
        return []
    seats = json.loads(seats_file.read_text()).get("seats", {})
    return [name for name, data in seats.items() if data.get("role") == "worker"]


def _idle_worker_seats(repo_dir: Path) -> List[str]:
    idle = []
    for seat in _worker_seats(repo_dir):
        seats_file = repo_dir / ".agent-army" / "seats.json"
        seats = json.loads(seats_file.read_text()).get("seats", {})
        wt = seats.get(seat, {}).get("worktree_dir", "")
        if wt and Path(wt, ".agent-army", ".active_task").exists():
            continue
        idle.append(seat)
    return idle


# --- briefs & prompt --------------------------------------------------------

from xml.sax.saxutils import escape as _xml_escape  # noqa: E402


def _render_task_brief_xml(wave: int, task: TaskSpec) -> str:
    lines = [
        f'<task_brief id="{_xml_escape(task.id)}" wave="{wave}" seat="{_xml_escape(task.seat)}" verify="{_xml_escape(task.verify)}">',
        f"  <role>{_xml_escape(task.role or 'Feature Engineer')}</role>",
        f"  <objective>{_xml_escape(task.objective)}</objective>",
        "  <scope>",
        f"    <read>{_xml_escape(', '.join(task.read) or 'README.md')}</read>",
        f"    <owns>{_xml_escape(', '.join(task.owns))}</owns>",
        f"    <forbidden>{_xml_escape(task.forbidden or 'Do not modify any file outside owns. Do not install external packages.')}</forbidden>",
        "  </scope>",
        "  <gates>",
        f"    <done_criteria>{_xml_escape(task.done_criteria or 'The objective holds on the current branch.')}</done_criteria>",
        "  </gates>",
        "  <security_boundaries>",
        "STOP IMMEDIATELY and emit WORKER BLOCKED if completing this task requires:",
        "- Real API keys, production secrets, or modifying .env / credential stores",
        "- Interactive login, OAuth, SSO, or 2FA",
        "- Deploying to external services or mutating remote databases",
        "- Pushing to git remotes or merging to main on GitHub",
        "  </security_boundaries>",
        "  <comms>",
        f"Commit your changes on your current branch, then write exactly one line to .agent-army/anchors/{_xml_escape(task.id)}.txt "
        f"in this worktree and print it:",
        f"- On success: WORKER DONE #{_xml_escape(task.id)} &lt;40-char-commit-sha&gt;",
        f"- On boundary or blocker: WORKER BLOCKED #{_xml_escape(task.id)} &lt;SECRET|AUTH|DEPLOY|GITHUB_MAIN|SCOPE&gt; &lt;one-line reason&gt;",
        "  </comms>",
        "</task_brief>",
    ]
    return "\n".join(lines) + "\n"


def _task_from_dict(data: Dict[str, Any]) -> TaskSpec:
    return TaskSpec(
        id=data.get("id", ""),
        seat=data.get("seat", ""),
        verify=data.get("verify", "none"),
        role=data.get("role", ""),
        objective=data.get("objective", ""),
        read=list(data.get("read", [])),
        owns=list(data.get("owns", [])),
        forbidden=data.get("forbidden", ""),
        done_criteria=data.get("done_criteria", ""),
    )


def _task_to_dict(task: TaskSpec) -> Dict[str, Any]:
    return {
        "id": task.id,
        "seat": task.seat,
        "verify": task.verify,
        "role": task.role,
        "objective": task.objective,
        "read": task.read,
        "owns": task.owns,
        "forbidden": task.forbidden,
        "done_criteria": task.done_criteria,
    }


def _repo_snapshot(repo_dir: Path, limit: int = 8000) -> str:
    """Tracked text at HEAD, capped so the Commander can see unmet criteria.

    git log alone does not show whether a mission's exit criteria hold. A
    model with no file bodies will invent a completed change.
    """
    try:
        names = [line for line in _git(repo_dir, "ls-files").splitlines() if line]
    except subprocess.CalledProcessError:
        return "(unavailable)"
    parts: List[str] = []
    used = 0
    for rel in names:
        if rel.startswith(".agent-army/") or rel == "army.config.toml":
            continue
        path = repo_dir / rel
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data:
            piece = f"### {rel}\n(binary)\n"
        else:
            text = data.decode("utf-8", errors="replace")
            if len(text) > 2000:
                text = text[:2000] + "\n…\n"
            piece = f"### {rel}\n```\n{text}\n```\n"
        if used + len(piece) > limit:
            parts.append("(snapshot truncated)\n")
            break
        parts.append(piece)
        used += len(piece)
    return "".join(parts) if parts else "(no tracked files)"


def _build_commander_prompt(
    repo_dir: Path,
    cfg: Dict[str, Any],
    state: Dict[str, Any],
    mission_file: Optional[Path],
    extra_context: str = "",
) -> str:
    sys_prompt = (ARMY_ROOT / "briefs" / "commander.sys.md")
    sections: List[str] = []
    if sys_prompt.exists():
        sections.append(sys_prompt.read_text())
    if mission_file and mission_file.exists():
        mission_text = mission_file.read_text()
        sections.append("## Mission\n\n```\n" + mission_text[:4000] + "\n```\n")
    mission_state = repo_dir / ".agent-army" / "MISSION_STATE.md"
    if mission_state.exists():
        sections.append("## Mission State\n\n```\n" + mission_state.read_text()[:4000] + "\n```\n")
    try:
        log = _git(repo_dir, "log", "-n", "10", "--oneline")
    except subprocess.CalledProcessError:
        log = "(unavailable)"
    sections.append("## Repository Status\n\n```\n" + log + "\n```\n")
    sections.append("## Tree at HEAD\n\n" + _repo_snapshot(repo_dir) + "\n")
    sections.append(
        "## Seats\n\n- worker seats: "
        + ", ".join(_worker_seats(repo_dir))
        + "\n- idle now: "
        + ", ".join(_idle_worker_seats(repo_dir))
        + "\n"
    )
    if state.get("pending_tasks"):
        pending = [t["id"] for t in state["pending_tasks"]]
        sections.append("## Pending Overflow Tasks\n\n" + ", ".join(pending) + "\n")
    if state.get("receipts"):
        latest = state["receipts"][-3:]
        sections.append(
            "## Latest Wave Receipts\n\n```\n"
            + "\n".join(json.dumps(r, sort_keys=True) for r in latest)
            + "\n```\n"
        )
    if extra_context:
        sections.append("## Immediate Context\n\n" + extra_context + "\n")
    return "\n\n".join(sections)


# --- commander wake ---------------------------------------------------------


def _wake_commander(
    repo_dir: Path,
    cfg: Dict[str, Any],
    state: Dict[str, Any],
    mission_file: Optional[Path],
    extra_context: str = "",
    env: Optional[Dict[str, str]] = None,
) -> CommanderDecision:
    state_dir = repo_dir / ".agent-army"
    prompt_file = state_dir / "commander-prompt.md"
    prompt_file.parent.mkdir(parents=True, exist_ok=True)
    prompt_file.write_text(
        _build_commander_prompt(repo_dir, cfg, state, mission_file, extra_context)
    )
    cmd, cmd_env = build_commander_cmd(ARMY_ROOT, repo_dir, cfg, prompt_file, base_env=env)
    timeout = int(cfg.get("commander_timeout_sec", 600) or 600)
    proc = subprocess.run(
        cmd, cwd=str(repo_dir), env=cmd_env, capture_output=True, text=True, timeout=timeout
    )
    (state_dir / "commander-last.stdout").write_text(proc.stdout or "")
    (state_dir / "commander-last.stderr").write_text(proc.stderr or "")
    return parse_decision_xml(proc.stdout)


# --- dispatch & supervise ---------------------------------------------------


def _dispatch_and_supervise(
    repo_dir: Path,
    cfg: Dict[str, Any],
    state: Dict[str, Any],
    tasks: List[TaskSpec],
    wave: int,
    enqueue_priority: str = "normal",
    supersedes: str = "",
    base_override: Optional[str] = None,
    env: Optional[Dict[str, str]] = None,
) -> int:
    """Dispatches <=1 task per idle worker seat, supervises to settlement.

    Returns 0 on settled, 20 when a security boundary was hit (handoff
    written), 1 on mechanical failure.
    """
    state_dir = repo_dir / ".agent-army"
    idle = _idle_worker_seats(repo_dir)

    for task in tasks:
        hit = scan_task_security_boundaries(task)
        if hit:
            write_handoff(
                repo_dir,
                hit[0],
                f"task {task.id} plans to cross a boundary: matched {hit[1]!r}",
                "A human must perform or explicitly re-scope this action, then run army resume.",
                state,
            )
            _save_state(state_dir, state)
            return EXIT_MISSION_BLOCKED

    assigned: List[Tuple[str, TaskSpec]] = []
    overflow: List[TaskSpec] = []
    busy: set = set()
    for task in tasks:
        seat = task.seat if task.seat in idle and task.seat not in busy else None
        if seat is None:
            seat = next((s for s in idle if s not in busy), None)
        if seat is None:
            overflow.append(task)
            continue
        busy.add(seat)
        assigned.append((seat, task))

    if overflow:
        kept = [_task_to_dict(t) for t in overflow]
        state["pending_tasks"] = kept + list(state.get("pending_tasks", []))
        _save_state(state_dir, state)

    if not assigned:
        return EXIT_OK

    slug = cfg["slug"]
    integration_ref = f"refs/heads/army/{slug}/integration"
    try:
        base_ref = base_override or _git(repo_dir, "rev-parse", integration_ref)
    except subprocess.CalledProcessError:
        base_ref = _git(repo_dir, "rev-parse", "HEAD")

    briefs_dir = state_dir / "briefs"
    briefs_dir.mkdir(parents=True, exist_ok=True)
    manifest_tasks = []
    for seat, task in assigned:
        brief_path = briefs_dir / f"{wave}-{task.id}.xml"
        brief_path.write_text(_render_task_brief_xml(wave, task))
        manifest_tasks.append(
            {
                "id": task.id,
                "seat": seat,
                "owns": task.owns,
                "verify": task.verify,
                "brief": str(brief_path),
                "base_ref": base_ref,
                "enqueue_priority": enqueue_priority,
                "supersedes": supersedes,
            }
        )

    manifest = {"wave": wave, "tasks": manifest_tasks}
    manifest_path = state_dir / "waves" / f"{wave}.manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2))

    acquire = json.dumps([{"id": t["id"], "seat": t["seat"], "owns": t["owns"]} for t in manifest_tasks])
    if not _bash_ok("partition.sh", ["acquire-wave", str(repo_dir), acquire], env):
        write_handoff(
            repo_dir,
            "PARTITION_CONFLICT",
            "wave owns overlap with an existing lease",
            "Resolve the overlapping leases or wait for holders to finish, then army resume.",
            state,
        )
        _save_state(state_dir, state)
        return EXIT_MISSION_BLOCKED

    for seat, task in assigned:
        proc = _bash(
            "briefs.sh",
            ["dispatch-task", str(repo_dir), seat, str(wave), task.id,
             str(briefs_dir / f"{wave}-{task.id}.xml")],
            env,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"briefs.sh dispatch-task failed for {seat}/{task.id}: {proc.stderr}"
            )

    proc = _bash("supervisor.sh", ["wave", str(repo_dir), str(manifest_path)], env)
    if proc.returncode != 0:
        raise RuntimeError(f"supervisor wave failed: {proc.stderr}")
    receipt = json.loads(proc.stdout.strip().splitlines()[-1])

    state.setdefault("receipts", []).append(receipt)
    state["receipts"] = state["receipts"][-5:]
    _save_state(state_dir, state)
    _update_mission_state(repo_dir, state)

    for task_receipt in receipt.get("tasks", {}).values():
        boundary = task_receipt.get("boundary", "")
        if task_receipt.get("status") == "BLOCKED" and boundary in BOUNDARY_CODES:
            write_handoff(
                repo_dir,
                boundary,
                f"task blocked: {task_receipt.get('reason', '')}",
                "A human must perform the privileged action, then run army resume.",
                state,
            )
            _save_state(state_dir, state)
            return EXIT_MISSION_BLOCKED
    return EXIT_OK


def _update_mission_state(repo_dir: Path, state: Dict[str, Any]) -> None:
    path = repo_dir / ".agent-army" / "MISSION_STATE.md"
    lines = [
        "# Mission State",
        "",
        f"- status: {state.get('status', 'running')}",
        f"- waves supervised: {state.get('wave', 0)}",
        f"- zero_integrate_waves: {state.get('zero_integrate_waves', 0)}",
        f"- pending overflow tasks: {len(state.get('pending_tasks', []))}",
        "",
    ]
    for receipt in state.get("receipts", [])[-3:]:
        lines.append(f"```json\n{json.dumps(receipt, sort_keys=True)}\n```\n")
    path.write_text("\n".join(lines))


# --- drain & promote --------------------------------------------------------


def drain_and_promote(
    repo_dir: Path,
    cfg: Dict[str, Any],
    state: Dict[str, Any],
    mission_file: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
) -> Tuple[str, Any]:
    """Drains the GREEN queue, resolving conflicts via Commander wakeups.

    Returns ("ok", promoted_count), ("blocked", reason) after a handoff, or
    ("error", message) on mechanical failure.
    """
    state_dir = repo_dir / ".agent-army"
    slug = cfg["slug"]
    while True:
        proc = _bash("arbiter.sh", ["drain", str(repo_dir)], env)
        if proc.returncode == 0:
            promote = _bash("arbiter.sh", ["promote", str(repo_dir), "--confirm"], env)
            if promote.returncode != 0:
                # main may already have fast-forwarded by now; never fail as a
                # bare exit 1 — the operator needs the structured handoff.
                write_handoff(
                    repo_dir,
                    "PROMOTE_FAILED",
                    f"arbiter promote failed: {promote.stderr.strip()}",
                    "Inspect the promote error (often an idle seat worktree left dirty, "
                    "which blocks worktree_sync_pool). Snapshot the seat if it holds work, "
                    "clean it, then run army resume.",
                    state,
                )
                _save_state(state_dir, state)
                return "blocked", "PROMOTE_FAILED"
            count = 0
            for line in promote.stdout.strip().splitlines():
                if line.strip().isdigit():
                    count = int(line.strip())
            return "ok", count
        if proc.returncode != 2:
            return "error", f"arbiter drain rc={proc.returncode}: {proc.stderr.strip()}"

        failure_file = state_dir / "drain-failure.json"
        if not failure_file.exists():
            return "error", "drain returned 2 without drain-failure.json"
        failure = json.loads(failure_file.read_text())
        r_ticket = failure.get("ticket", "")
        r_owns = list(failure.get("owns", []))
        r_status = failure.get("status", "unknown")
        integration_tip = failure.get("integration_tip", "")

        # A drain failure means this wave promoted nothing so far.
        state["zero_integrate_waves"] = int(state.get("zero_integrate_waves", 0)) + 1
        _save_state(state_dir, state)
        if state["zero_integrate_waves"] >= 2:
            write_handoff(
                repo_dir,
                "NO_PROGRESS",
                f"two consecutive zero-integrate cycles; last failure: {r_status} on {r_ticket}",
                "Inspect drain-failure.json and the gate logs, resolve manually, then army resume.",
                state,
            )
            _save_state(state_dir, state)
            return "blocked", "NO_PROGRESS"

        extra = (
            "A drain failure stopped integration:\n\n```json\n"
            + json.dumps(failure, indent=2, sort_keys=True)
            + "\n```\n\nEmit a dispatch_wave decision with EXACTLY ONE task whose owns equals "
            f"{sorted(r_owns)} and whose base is the integration tip. The task resolves this failure."
        )
        decision = _wake_commander(repo_dir, cfg, state, mission_file, extra_context=extra, env=env)
        if decision.action != "dispatch_wave":
            write_handoff(
                repo_dir,
                "CONFLICT_RESOLUTION_INVALID",
                f"resolution wake returned action {decision.action!r}",
                "Resolve the drain failure manually, then army resume.",
                state,
            )
            _save_state(state_dir, state)
            return "blocked", "CONFLICT_RESOLUTION_INVALID"
        tasks = decision.tasks
        if len(tasks) != 1 or sorted(tasks[0].owns) != sorted(r_owns):
            write_handoff(
                repo_dir,
                "CONFLICT_RESOLUTION_INVALID",
                "resolution decision must contain exactly 1 task whose owns equals the failed record's owns",
                "Resolve the drain failure manually, then army resume.",
                state,
            )
            _save_state(state_dir, state)
            return "blocked", "CONFLICT_RESOLUTION_INVALID"

        task = tasks[0]
        idle = _idle_worker_seats(repo_dir)
        seat = task.seat if task.seat in idle else (idle[0] if idle else None)
        if seat is None:
            write_handoff(
                repo_dir,
                "CONFLICT_RESOLUTION_INVALID",
                "no idle worker seat for the resolution task",
                "Wait for a seat to settle or add a worker, then army resume.",
                state,
            )
            _save_state(state_dir, state)
            return "blocked", "CONFLICT_RESOLUTION_INVALID"
        task.seat = seat

        reassign = _bash(
            "partition.sh",
            ["reassign", str(repo_dir), r_ticket, task.id, seat, ", ".join(task.owns)],
            env,
        )
        if reassign.returncode != 0:
            acquire = json.dumps([{"id": task.id, "seat": seat, "owns": task.owns}])
            if not _bash_ok("partition.sh", ["acquire-wave", str(repo_dir), acquire], env):
                return "error", "could not reassign or acquire the resolution lease"

        if integration_tip:
            _bash("worktree.sh", ["sync-seat", str(repo_dir), seat, integration_tip], env)

        rc = _dispatch_and_supervise(
            repo_dir,
            cfg,
            state,
            [task],
            wave=int(state.get("wave", 0)) + 1,
            enqueue_priority="front",
            supersedes=r_ticket,
            base_override=integration_tip or None,
            env=env,
        )
        if rc == EXIT_MISSION_BLOCKED:
            return "blocked", "resolution task hit a boundary"
        if rc != EXIT_OK:
            return "error", "resolution wave failed"
        # Loop back to drain: the resolution SHA is queued at the front with
        # supersedes=<ticket>, so a green drain marks R superseded.


# --- mission lifecycle ------------------------------------------------------


def _finish_mission(
    repo_dir: Path,
    cfg: Dict[str, Any],
    state: Dict[str, Any],
    mission_file: Optional[Path],
    env: Optional[Dict[str, str]] = None,
) -> int:
    state_dir = repo_dir / ".agent-army"
    if _has_queued(repo_dir):
        outcome = drain_and_promote(repo_dir, cfg, state, mission_file, env)
        if outcome[0] != "ok":
            return EXIT_MISSION_BLOCKED

    # Final full-repo gate on local main under the clean environment.
    proc = _bash(
        "common.sh",
        ["gate", str(repo_dir), str(state_dir / "profile.env"),
         str(cfg.get("army_task_timeout_sec", 1800)), _profile_test_cmd(repo_dir)],
        env,
    )
    if proc.returncode != 0:
        write_handoff(
            repo_dir,
            "FINAL_GATE_RED",
            f"final TEST_CMD on main failed (rc={proc.returncode})",
            "Fix the repository so its test suite passes, then army resume.",
            state,
        )
        _save_state(state_dir, state)
        return EXIT_MISSION_BLOCKED

    promoted = [r for r in _queue_rows(repo_dir) if r.get("status") == "promoted"]
    complete = state_dir / "COMPLETE.md"
    lines = [
        "# Mission Complete",
        "",
        f"Finished: {datetime.datetime.now(datetime.timezone.utc).isoformat()}",
        "",
        "## Integrated commits",
        "",
    ]
    for row in promoted:
        lines.append(f"- `{row.get('sha', '')}` — {row.get('ticket', '')} (seat {row.get('seat', '')})")
    lines += ["", "## Test receipts", "", "- Final TEST_CMD green on local main under the clean gate environment.", ""]
    complete.write_text("\n".join(lines))

    state["status"] = "complete"
    _save_state(state_dir, state)
    _update_mission_state(repo_dir, state)

    if str(cfg.get("army_create_draft_pr", "false")).lower() == "true":
        slug = cfg["slug"]
        _git(repo_dir, "push", "origin", f"refs/heads/army/{slug}/integration")
        subprocess.run(
            ["gh", "pr", "create", "--draft", "--head", f"army/{slug}/integration",
             "--title", f"army: {cfg.get('army_name', slug)} mission",
             "--body", "Automated agent-army mission (draft; never auto-merged)."],
            cwd=str(repo_dir),
            capture_output=True,
            text=True,
        )
    return EXIT_OK


def run_mission(
    repo_dir: Path,
    mission_file: Path,
    config_path: Path,
    overrides: Optional[Dict[str, Any]] = None,
    env: Optional[Dict[str, str]] = None,
    allow_unchanged_complete: bool = False,
) -> int:
    repo_dir = repo_dir.resolve()
    state_dir = repo_dir / ".agent-army"
    lock = acquire_army_lock(state_dir)
    try:
        if not _bash_ok("preflight.sh", ["check", str(repo_dir), str(config_path)], env):
            return EXIT_ERROR

        state = _load_state(state_dir)
        state["status"] = "running"
        state["mission_file"] = str(mission_file)
        _save_state(state_dir, state)
        cfg = _load_config(repo_dir, config_path, overrides or {})
        env = _config_env(cfg, env)

        if not _bash_ok("lifecycle.sh", ["up", str(repo_dir), str(config_path)], env):
            return EXIT_ERROR
        if not _ensure_integration_ref(repo_dir, env):
            # init-ref failed and the ref does not resolve: proceeding would
            # disable the supervisor's secret-scan boundary (vacuous range).
            print(
                "error: integration ref missing after arbiter init-ref; "
                "secret-scan boundary would be vacuous — aborting",
                file=sys.stderr,
            )
            return EXIT_ERROR

        max_waves = int(cfg.get("army_max_waves", 15) or 15)
        accounting_pending = False
        start_sha = _git(repo_dir, "rev-parse", "HEAD")
        false_complete = 0
        wake_extra = ""

        while True:
            # 1. Drain & promote the settled queue BEFORE any Commander wake.
            if _has_queued(repo_dir) or accounting_pending:
                outcome = drain_and_promote(repo_dir, cfg, state, mission_file, env)
                if outcome[0] == "blocked":
                    return EXIT_MISSION_BLOCKED
                if outcome[0] == "error":
                    return EXIT_ERROR
                promoted = outcome[1]
                if accounting_pending:
                    accounting_pending = False
                    if promoted > 0:
                        state["zero_integrate_waves"] = 0
                    else:
                        state["zero_integrate_waves"] = int(state.get("zero_integrate_waves", 0)) + 1
                    _save_state(state_dir, state)
                    if state["zero_integrate_waves"] >= 2:
                        write_handoff(
                            repo_dir,
                            "NO_PROGRESS",
                            "two consecutive settled waves promoted 0 commits",
                            "Inspect the wave receipts and re-plan the mission, then army resume.",
                            state,
                        )
                        _save_state(state_dir, state)
                        return EXIT_MISSION_BLOCKED

            # 2. Pending overflow tasks go out before waking the Commander.
            tasks: List[TaskSpec] = []
            if state.get("pending_tasks"):
                seats = _idle_worker_seats(repo_dir)
                while seats and state["pending_tasks"]:
                    tasks.append(_task_from_dict(state["pending_tasks"].pop(0)))
                    seats.pop(0)
                _save_state(state_dir, state)

            if not tasks:
                _update_mission_state(repo_dir, state)
                decision = _wake_commander(
                    repo_dir, cfg, state, mission_file, extra_context=wake_extra, env=env
                )
                wake_extra = ""
                if decision.action == "mission_blocked":
                    write_handoff(
                        repo_dir,
                        decision.boundary or "UNKNOWN",
                        decision.reason or decision.summary,
                        "A human must perform the privileged action, then run army resume.",
                        state,
                    )
                    _save_state(state_dir, state)
                    return EXIT_MISSION_BLOCKED
                if decision.action == "mission_complete":
                    head = _git(repo_dir, "rev-parse", "HEAD")
                    promoted = any(
                        row.get("status") == "promoted" for row in _queue_rows(repo_dir)
                    )
                    if (
                        not allow_unchanged_complete
                        and head == start_sha
                        and not promoted
                    ):
                        false_complete += 1
                        if false_complete >= 2:
                            write_handoff(
                                repo_dir,
                                "UNCHANGED_MAIN",
                                "commander declared mission_complete but local main "
                                f"is still {head} and nothing was promoted",
                                "Dispatch the remaining work, or advance main yourself, "
                                "then army resume.",
                                state,
                            )
                            _save_state(state_dir, state)
                            return EXIT_MISSION_BLOCKED
                        wake_extra = (
                            f"local main is still {head} and nothing has been promoted. "
                            "The mission is not complete. Dispatch the work."
                        )
                        continue
                    return _finish_mission(repo_dir, cfg, state, mission_file, env)
                tasks = decision.tasks

            # 3. Dispatch + supervise the wave.
            wave = int(state.get("wave", 0)) + 1
            rc = _dispatch_and_supervise(repo_dir, cfg, state, tasks, wave=wave, env=env)
            if rc == EXIT_MISSION_BLOCKED:
                return EXIT_MISSION_BLOCKED
            if rc != EXIT_OK:
                return EXIT_ERROR
            accounting_pending = True

            state["wave"] = wave
            _save_state(state_dir, state)
            if wave >= max_waves:
                write_handoff(
                    repo_dir,
                    "MAX_WAVES",
                    f"reached max_waves={max_waves} before exit criteria",
                    "Raise max_waves or re-plan the mission, then army resume.",
                    state,
                )
                _save_state(state_dir, state)
                return EXIT_MISSION_BLOCKED
    finally:
        try:
            lock.close()
        except OSError:
            pass


def resume_mission(repo_dir: Path, config_path: Path) -> int:
    repo_dir = repo_dir.resolve()
    state_dir = repo_dir / ".agent-army"
    state_file = state_dir / "state.json"
    if not state_file.exists():
        print(f"error: no state at {state_file}; run `army run` first", file=sys.stderr)
        return EXIT_ERROR
    state = _load_state(state_dir)
    slug = state.get("slug")
    if not slug:
        print(f"error: state has no slug: {state_file}", file=sys.stderr)
        return EXIT_ERROR

    cfg = _load_config(repo_dir, config_path, {})
    ref = f"refs/heads/army/{slug}/integration"
    base_branch = cfg.get("army_base_branch", "main")
    main_head = _git(repo_dir, "rev-parse", base_branch)
    ref_exists = subprocess.run(
        ["git", "-C", str(repo_dir), "show-ref", "--verify", "--quiet", ref]
    ).returncode == 0
    if not ref_exists:
        _git(repo_dir, "update-ref", ref, main_head)
    else:
        tip = _git(repo_dir, "rev-parse", ref)
        if tip != main_head:
            ancestor = subprocess.run(
                ["git", "-C", str(repo_dir), "merge-base", "--is-ancestor", tip, main_head]
            )
            if ancestor.returncode == 0:
                # A human advanced main while the mission was blocked.
                _git(repo_dir, "update-ref", ref, main_head, tip)

    _bash("worktree.sh", ["sync", str(repo_dir), main_head, ""])
    state["zero_integrate_waves"] = 0
    state["status"] = "running"
    _save_state(state_dir, state)

    mission_file = state.get("mission_file")
    if not mission_file or not Path(mission_file).exists():
        print(f"error: state has no resolvable mission_file: {mission_file!r}", file=sys.stderr)
        return EXIT_ERROR
    return run_mission(
        repo_dir, Path(mission_file), config_path, allow_unchanged_complete=True
    )


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="army-engine", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    run_p = sub.add_parser("run", help="run a mission end to end")
    run_p.add_argument("repo")
    run_p.add_argument("--mission", required=True)
    run_p.add_argument("--config")
    run_p.add_argument("--commander", choices=["pi", "opencode"])
    run_p.add_argument("--model")

    resume_p = sub.add_parser("resume", help="resume a blocked mission")
    resume_p.add_argument("repo")
    resume_p.add_argument("--config")

    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve()
    config = Path(args.config) if args.config else repo / "army.config.toml"

    try:
        if args.cmd == "run":
            overrides: Dict[str, Any] = {}
            if args.commander:
                overrides["commander_harness"] = args.commander
            if args.model:
                overrides["commander_model"] = args.model
            # Resolve now: army resume re-reads this path from state.json from
            # whatever cwd it is launched in.
            return run_mission(repo, Path(args.mission).resolve(), config, overrides)
        return resume_mission(repo, config)
    except ArmyLockError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR
    except DecisionParseError as exc:
        print(f"error: commander decision invalid: {exc}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
