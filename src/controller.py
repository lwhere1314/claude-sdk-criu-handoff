"""CRIU canary for a native Claude Agent SDK session handoff.

The first SDK query exits before the checkpoint. After the PID 1 controller is
restored, a second query resumes the SDK's native session by session ID. No
rendered trajectory is injected into the second prompt.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any, AsyncIterator


WORKSPACE = Path("/workspace")
READY = WORKSPACE / "native-resume.ready"
CONTINUE = WORKSPACE / "native-resume.continue"
EVIDENCE = WORKSPACE / "native-resume-evidence.txt"


def summarize(message: Any) -> str:
    """Return a compact, credential-free SDK event summary."""
    fields = [type(message).__name__]
    subtype = getattr(message, "subtype", None)
    if subtype:
        fields.append(f"subtype={subtype}")

    session_id = getattr(message, "session_id", None)
    data = getattr(message, "data", None)
    if not session_id and isinstance(data, dict):
        session_id = data.get("session_id")
    if session_id:
        fields.append(f"session_id={session_id}")

    content = getattr(message, "content", None)
    if isinstance(content, list):
        blocks: list[str] = []
        for block in content:
            name = getattr(block, "name", None)
            text = getattr(block, "text", None)
            if name:
                blocks.append(f"tool:{name}")
            elif isinstance(text, str):
                blocks.append("text:" + text[:160].replace("\n", " "))
        if blocks:
            fields.append("blocks=" + "|".join(blocks))

    result = getattr(message, "result", None)
    if isinstance(result, str):
        fields.append("result=" + result[:200].replace("\n", " "))
    return " ".join(fields)


async def consume(messages: AsyncIterator[Any], label: str) -> str | None:
    session_id: str | None = None
    async for message in messages:
        print(f"{label} {summarize(message)}", flush=True)
        candidate = getattr(message, "session_id", None)
        data = getattr(message, "data", None)
        if not candidate and isinstance(data, dict):
            candidate = data.get("session_id")
        if candidate:
            session_id = str(candidate)
    return session_id


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


async def main() -> None:
    from claude_agent_sdk import ClaudeAgentOptions, query

    for marker in (READY, CONTINUE, EVIDENCE):
        marker.unlink(missing_ok=True)

    model = os.environ.get("CANARY_MODEL", "kimi-k2.6")
    nonce = os.environ.get("CANARY_NONCE", "NATIVE-RESUME-CANARY")
    common = {
        "allowed_tools": ["Read", "Bash"],
        "permission_mode": "bypassPermissions",
        "cwd": WORKSPACE,
        "max_turns": 5,
        "env": sdk_environment(),
    }

    print(f"NATIVE_CANARY_START model={model} pid={os.getpid()}", flush=True)
    first_session = await consume(
        query(
            prompt=(
                "First turn of a native-session resume canary. Use Read exactly "
                "once on /workspace/run.py, modify nothing, and remember the "
                f"nonce {nonce}. Then reply exactly FIRST_NATIVE_TURN_COMPLETE."
            ),
            options=ClaudeAgentOptions(model=model, **common),
        ),
        "NATIVE_TURN1",
    )
    if not first_session:
        raise RuntimeError("The first SDK query produced no session_id")

    READY.write_text(
        f"session_id={first_session}\ncontroller_pid={os.getpid()}\n",
        encoding="utf-8",
    )
    print(
        f"NATIVE_CANARY_READY session_id={first_session} pid={os.getpid()}",
        flush=True,
    )
    while not CONTINUE.exists():
        await asyncio.sleep(0.2)

    print(
        f"NATIVE_CANARY_RESTORED session_id={first_session} pid={os.getpid()}",
        flush=True,
    )
    second_session = await consume(
        query(
            prompt=(
                "Second turn after CRIU restore. Without using Read, state the "
                "exact nonce from the previous turn. Then use Bash to append the "
                f"exact line 'NATIVE_SESSION_RESUMED {nonce}' to "
                "/workspace/native-resume-evidence.txt and reply exactly "
                "SECOND_NATIVE_TURN_COMPLETE."
            ),
            options=ClaudeAgentOptions(resume=first_session, **common),
        ),
        "NATIVE_TURN2",
    )

    same_session = first_session == second_session
    expected_evidence = f"NATIVE_SESSION_RESUMED {nonce}"
    evidence_ok = (
        EVIDENCE.exists()
        and EVIDENCE.read_text(encoding="utf-8").strip() == expected_evidence
    )
    print(
        "NATIVE_CANARY_COMPLETE "
        f"original_session={first_session} resumed_session={second_session} "
        f"same_session={same_session} evidence_ok={evidence_ok}",
        flush=True,
    )
    if not same_session or not evidence_ok:
        raise RuntimeError("Native session resume validation failed")


if __name__ == "__main__":
    # PidfdChildWatcher leaves anon_inode:[pidfd] descriptors that CRIU 3.18
    # cannot dump. The threaded watcher uses waitpid and is checkpointable.
    asyncio.set_child_watcher(asyncio.ThreadedChildWatcher())
    asyncio.run(main())
