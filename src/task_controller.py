"""Two-phase Claude Agent SDK controller for Terminal-Bench handoffs."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator


WORKSPACE = Path(os.environ.get("TASK_WORKDIR", "/app"))
MARKER_DIR = Path(os.environ.get("HANDOFF_MARKER_DIR", "/tmp/claude-handoff"))
READY = MARKER_DIR / "ready"
CONTINUE = MARKER_DIR / "continue"
EVIDENCE = MARKER_DIR / "evidence.txt"
MANIFEST = MARKER_DIR / "manifest.json"
VERIFIER_COMPLETE = MARKER_DIR / "verifier-complete"
INSTRUCTION = Path(os.environ.get("TASK_INSTRUCTION_PATH", "/opt/task-instruction.md"))


@dataclass
class TurnResult:
    session_id: str | None = None
    observed_model: str | None = None
    first_event_ms: int | None = None
    max_turns_reached: bool = False


def compact_message(message: Any) -> str:
    fields = [type(message).__name__]
    for name in ("subtype", "session_id", "model"):
        value = getattr(message, name, None)
        if value:
            fields.append(f"{name}={value}")
    content = getattr(message, "content", None)
    if isinstance(content, list):
        blocks: list[str] = []
        for block in content:
            tool_name = getattr(block, "name", None)
            text = getattr(block, "text", None)
            if tool_name:
                blocks.append(f"tool:{tool_name}")
            elif isinstance(text, str):
                blocks.append("text:" + text[:200].replace("\n", " "))
        if blocks:
            fields.append("blocks=" + "|".join(blocks))
    result = getattr(message, "result", None)
    if isinstance(result, str):
        fields.append("result=" + result[:240].replace("\n", " "))
    return " ".join(fields)


async def consume(messages: AsyncIterator[Any], label: str) -> TurnResult:
    output = TurnResult()
    started = time.monotonic()
    try:
        async for message in messages:
            if output.first_event_ms is None:
                output.first_event_ms = round((time.monotonic() - started) * 1000)
            print(f"{label} {compact_message(message)}", flush=True)
            if getattr(message, "subtype", None) == "error_max_turns":
                output.max_turns_reached = True
            data = getattr(message, "data", None)
            candidate_session = getattr(message, "session_id", None)
            candidate_model = getattr(message, "model", None)
            if isinstance(data, dict):
                candidate_session = candidate_session or data.get("session_id")
                candidate_model = candidate_model or data.get("model")
            if candidate_session:
                output.session_id = str(candidate_session)
            if candidate_model:
                output.observed_model = str(candidate_model)
    except Exception as exc:
        if output.session_id and (
            output.max_turns_reached or "maximum number of turns" in str(exc).lower()
        ):
            print(
                f"{label}_EXPECTED_CUTOFF session_id={output.session_id} reason=max_turns",
                flush=True,
            )
        else:
            raise
    return output


def sdk_environment() -> dict[str, str]:
    names = (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "CLAUDE_CONFIG_DIR",
        "IS_SANDBOX",
        "MAX_THINKING_TOKENS",
    )
    return {name: os.environ[name] for name in names if os.environ.get(name)}


def child_pids() -> list[int]:
    children: list[int] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit() or entry.name == "1":
            continue
        try:
            fields = (entry / "stat").read_text(encoding="utf-8").split()
            if len(fields) > 3 and int(fields[3]) == 1:
                children.append(int(entry.name))
        except (FileNotFoundError, PermissionError, ValueError):
            continue
    return sorted(children)


def established_tcp_count() -> int:
    owned_inodes: set[str] = set()
    for fd in Path("/proc/1/fd").iterdir():
        try:
            target = os.readlink(fd)
        except (FileNotFoundError, PermissionError, OSError):
            continue
        if target.startswith("socket:[") and target.endswith("]"):
            owned_inodes.add(target[8:-1])
    total = 0
    for path in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()[1:]
        except FileNotFoundError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) > 9 and fields[3] == "01" and fields[9] in owned_inodes:
                total += 1
    return total


def pidfd_count() -> int:
    total = 0
    for fd in Path("/proc/1/fd").iterdir():
        try:
            if "pidfd" in os.readlink(fd):
                total += 1
        except (FileNotFoundError, PermissionError, OSError):
            continue
    return total


async def wait_for_quiescence(stable_ms: int = 2000, timeout_ms: int = 30000) -> dict[str, Any]:
    started = time.monotonic()
    stable_since: float | None = None
    last: dict[str, Any] = {}
    while (time.monotonic() - started) * 1000 < timeout_ms:
        last = {
            "child_processes": len(child_pids()),
            "established_tcp": established_tcp_count(),
            "pidfd": pidfd_count(),
        }
        if all(value == 0 for value in last.values()):
            stable_since = stable_since or time.monotonic()
            stable_for = round((time.monotonic() - stable_since) * 1000)
            if stable_for >= stable_ms:
                last["stable_for_ms"] = stable_for
                last["wait_ms"] = round((time.monotonic() - started) * 1000)
                print("HANDOFF_QUIESCENT " + json.dumps(last, sort_keys=True), flush=True)
                return last
        else:
            stable_since = None
        await asyncio.sleep(0.2)
    raise RuntimeError(f"Controller did not reach a quiescent boundary: {last}")


def session_stats(session_id: str) -> dict[str, Any]:
    config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(WORKSPACE / ".claude")))
    candidates = sorted(config_dir.rglob(f"*{session_id}*.jsonl")) if config_dir.exists() else []
    if not candidates:
        candidates = sorted(config_dir.rglob("*.jsonl")) if config_dir.exists() else []
    if not candidates:
        return {
            "exists": False,
            "path_count": 0,
            "bytes": 0,
            "lines": 0,
            "parseable": False,
            "sha256": None,
        }
    path = candidates[-1]
    payload = path.read_bytes()
    lines = payload.splitlines()
    parseable = True
    for line in lines:
        try:
            json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            parseable = False
            break
    return {
        "exists": True,
        "path_count": len(candidates),
        "bytes": len(payload),
        "lines": len(lines),
        "parseable": parseable,
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def common_options(
    max_turns: int,
    allowed_tools: list[str],
    disallowed_tools: list[str] | None = None,
    max_thinking_tokens: int = 8192,
) -> dict[str, Any]:
    return {
        "tools": allowed_tools,
        "allowed_tools": allowed_tools,
        "disallowed_tools": disallowed_tools or [],
        "permission_mode": "bypassPermissions",
        "cwd": WORKSPACE,
        "max_turns": max_turns,
        "max_thinking_tokens": max_thinking_tokens,
        "env": sdk_environment(),
    }


async def run_first_turn(model: str, nonce: str) -> TurnResult:
    from claude_agent_sdk import ClaudeAgentOptions, query

    task = INSTRUCTION.read_text(encoding="utf-8")
    prompt = f"""You are phase 1 of a two-phase Terminal-Bench run.

Task instruction:
{task}

Inspect the task workspace and relevant inputs using only Read, Glob, and Grep. Bash, Write, and Edit are intentionally unavailable in this phase. Diagnose the task and form a concrete implementation plan, but do not modify files or start any commands or training. Remember this nonce exactly: {nonce}

Finish with a concise handoff summary and the exact marker PHASE1_COMPLETE.
"""
    return await consume(
        query(
            prompt=prompt,
            options=ClaudeAgentOptions(
                model=model,
                **common_options(
                    int(os.environ.get("PHASE1_MAX_TURNS", "3")),
                    ["Read", "Glob", "Grep"],
                    [
                        "Agent", "Skill", "Task", "Bash", "Write", "Edit",
                        "NotebookEdit", "WebFetch", "WebSearch",
                    ],
                    int(os.environ.get("PHASE1_MAX_THINKING_TOKENS", "2048")),
                ),
            ),
        ),
        "TASK_TURN1",
    )


async def run_second_turn(session_id: str, model: str, nonce: str) -> TurnResult:
    from claude_agent_sdk import ClaudeAgentOptions, query

    prompt = f"""You are phase 2 after a native-session handoff.

First state the exact nonce remembered from phase 1. Immediately use Bash to write exactly this one line to {EVIDENCE}:
NATIVE_SESSION_RESUMED {nonce}

After recording that continuity evidence, implement the Terminal-Bench task completely in {WORKSPACE}. Use tools, run appropriate checks, and leave the required final files in place. Do not merely explain a solution.

Finish with the exact marker PHASE2_COMPLETE.
"""
    return await consume(
        query(
            prompt=prompt,
            options=ClaudeAgentOptions(
                resume=session_id,
                model=model,
                **common_options(
                    int(os.environ.get("PHASE2_MAX_TURNS", "20")),
                    ["Read", "Write", "Edit", "Bash", "Glob", "Grep"],
                    max_thinking_tokens=int(
                        os.environ.get("PHASE2_MAX_THINKING_TOKENS", "8192")
                    ),
                ),
            ),
        ),
        "TASK_TURN2",
    )


async def main() -> None:
    phase = os.environ.get("HANDOFF_PHASE", "both")
    if phase not in {"both", "first", "resume"}:
        raise ValueError(f"Unsupported HANDOFF_PHASE: {phase}")

    MARKER_DIR.mkdir(parents=True, exist_ok=True)
    source_model = os.environ.get("SOURCE_MODEL", "kimi-k2.6")
    target_model = os.environ.get("TARGET_MODEL", source_model)
    nonce = os.environ.get("HANDOFF_NONCE", "TASK-HANDOFF-CANARY")
    controller_epoch = secrets.token_hex(16)
    print(
        "TASK_CONTROLLER_START "
        f"phase={phase} pid={os.getpid()} epoch={controller_epoch} "
        f"source_model={source_model} target_model={target_model}",
        flush=True,
    )

    if phase in {"both", "first"}:
        for marker in (READY, CONTINUE, EVIDENCE, MANIFEST, VERIFIER_COMPLETE):
            marker.unlink(missing_ok=True)
        turn1_started = time.monotonic()
        first = await run_first_turn(source_model, nonce)
        turn1_ms = round((time.monotonic() - turn1_started) * 1000)
        if not first.session_id:
            raise RuntimeError("First turn produced no native session_id")
        quiescence = await wait_for_quiescence()
        stats = session_stats(first.session_id)
        manifest = {
            "session_id": first.session_id,
            "source_model": source_model,
            "target_model": target_model,
            "nonce": nonce,
            "controller_epoch": controller_epoch,
            "turn1_ms": turn1_ms,
            "turn1_first_event_ms": first.first_event_ms,
            "observed_model_turn1": first.observed_model,
            "quiescence": quiescence,
            "jsonl_before": stats,
        }
        MANIFEST.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        READY.write_text(first.session_id + "\n", encoding="utf-8")
        print("TASK_SESSION_BEFORE " + json.dumps(manifest, sort_keys=True), flush=True)
        print(
            f"TASK_HANDOFF_READY session_id={first.session_id} epoch={controller_epoch}",
            flush=True,
        )
        if phase == "first":
            return
    else:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        first = TurnResult(
            session_id=str(manifest["session_id"]),
            observed_model=manifest.get("observed_model_turn1"),
        )
        source_model = str(manifest["source_model"])
        target_model = os.environ.get("TARGET_MODEL", str(manifest["target_model"]))
        nonce = str(manifest["nonce"])

    if phase == "both":
        while not CONTINUE.exists():
            await asyncio.sleep(0.2)

    stats_after_restore = session_stats(str(first.session_id))
    print(
        "TASK_CONTROLLER_RESUMED "
        f"phase={phase} pid={os.getpid()} epoch={controller_epoch} "
        f"session_id={first.session_id}",
        flush=True,
    )
    print("TASK_SESSION_AFTER_RESTORE " + json.dumps(stats_after_restore, sort_keys=True), flush=True)
    turn2_started = time.monotonic()
    second = await run_second_turn(str(first.session_id), target_model, nonce)
    turn2_ms = round((time.monotonic() - turn2_started) * 1000)
    stats_after_turn2 = session_stats(str(first.session_id))
    same_session = first.session_id == second.session_id
    evidence_ok = EVIDENCE.exists() and EVIDENCE.read_text(encoding="utf-8").strip() == (
        f"NATIVE_SESSION_RESUMED {nonce}"
    )
    result = {
        "session_id_before": first.session_id,
        "session_id_after": second.session_id,
        "same_session": same_session,
        "semantic_evidence": evidence_ok,
        "controller_epoch_after": controller_epoch,
        "requested_model_turn1": source_model,
        "requested_model_turn2": target_model,
        "observed_model_turn1": first.observed_model,
        "observed_model_turn2": second.observed_model,
        "turn2_first_event_ms": second.first_event_ms,
        "turn2_ms": turn2_ms,
        "jsonl_after_turn2": stats_after_turn2,
    }
    print("TASK_HANDOFF_COMPLETE " + json.dumps(result, sort_keys=True), flush=True)
    if not same_session or not evidence_ok:
        raise RuntimeError("Native task handoff validation failed")
    if os.environ.get("WAIT_FOR_VERIFIER", "1") == "1":
        print("TASK_WAITING_FOR_VERIFIER", flush=True)
        while not VERIFIER_COMPLETE.exists():
            await asyncio.sleep(0.2)


if __name__ == "__main__":
    asyncio.set_child_watcher(asyncio.ThreadedChildWatcher())
    asyncio.run(main())
