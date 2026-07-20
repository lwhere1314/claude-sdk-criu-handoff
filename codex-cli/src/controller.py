"""CRIU canary for a native Codex CLI session handoff.

Turn one runs ``codex exec`` to completion and the Codex process exits. After
the PID 1 controller is checkpointed and restored, turn two runs
``codex exec resume <session_id>`` so Codex continues its own persisted rollout
under ``$CODEX_HOME/sessions``. No rendered trajectory is injected into the
second prompt; the native session file survives inside the restored container.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any


WORKSPACE = Path("/workspace")
READY = WORKSPACE / "native-resume.ready"
CONTINUE = WORKSPACE / "native-resume.continue"
EVIDENCE = WORKSPACE / "native-resume-evidence.txt"

_UUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
_SESSION_KEYS = ("session_id", "thread_id", "conversation_id")


def codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME", str(WORKSPACE / ".codex")))


def render_config() -> None:
    """Write ``$CODEX_HOME/config.toml`` for the OpenAI-compatible provider.

    The API key is never written here; Codex reads it at runtime from the
    provider's ``env_key`` (``OPENAI_API_KEY``). Only the base URL, model, and
    Chat Completions wire format live in the file.
    """
    base_url = os.environ["OPENAI_BASE_URL"]
    model = os.environ.get("CANARY_MODEL", "gpt-5.5")
    for value in (base_url, model):
        if '"' in value or "\n" in value:
            raise RuntimeError("Provider base_url and model must be plain values")

    home = codex_home()
    home.mkdir(parents=True, exist_ok=True)
    home.chmod(0o700)
    config = (
        f'model = "{model}"\n'
        'model_provider = "coding_plan"\n\n'
        "[model_providers.coding_plan]\n"
        'name = "Coding Plan (OpenAI-compatible)"\n'
        f'base_url = "{base_url}"\n'
        'env_key = "OPENAI_API_KEY"\n'
        'wire_api = "responses"\n'
    )
    (home / "config.toml").write_text(config, encoding="utf-8")


def _find_session_id(value: Any) -> str | None:
    """Recursively pull a UUID session id out of a decoded JSONL event."""
    if isinstance(value, dict):
        for key in _SESSION_KEYS:
            candidate = value.get(key)
            if isinstance(candidate, str) and _UUID.fullmatch(candidate):
                return candidate
        # Newer schemas nest the id, e.g. {"type": "thread.started",
        # "thread": {"id": "<uuid>"}} or {"session": {"id": "<uuid>"}}.
        for nested_key in ("thread", "session"):
            nested = value.get(nested_key)
            if isinstance(nested, dict):
                nested_id = nested.get("id") or nested.get("session_id")
                if isinstance(nested_id, str) and _UUID.fullmatch(nested_id):
                    return nested_id
        for nested in value.values():
            found = _find_session_id(nested)
            if found:
                return found
    elif isinstance(value, list):
        for item in value:
            found = _find_session_id(item)
            if found:
                return found
    return None


def _newest_rollout_session_id() -> str | None:
    """Fall back to the UUID in the newest rollout filename.

    Rollout files are written as
    ``$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl``.
    """
    sessions = codex_home() / "sessions"
    rollouts = sorted(
        sessions.rglob("rollout-*.jsonl"),
        key=lambda path: path.stat().st_mtime,
    )
    for path in reversed(rollouts):
        matches = _UUID.findall(path.stem)
        if matches:
            return matches[-1]
    return None


def run_turn(label: str, subcommand: list[str], prompt: str) -> str | None:
    """Run one ``codex exec`` invocation and return its session id."""
    command = [
        "codex",
        *subcommand,
        "--json",
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        prompt,
    ]
    process = subprocess.run(
        command,
        cwd=WORKSPACE,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    session_id: str | None = None
    for line in process.stdout.splitlines():
        print(f"{label} {line[:200]}", flush=True)
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        candidate = _find_session_id(event)
        if candidate:
            session_id = candidate

    if process.returncode != 0:
        raise RuntimeError(f"{label} codex exec exited {process.returncode}")
    return session_id


def main() -> None:
    for marker in (READY, CONTINUE, EVIDENCE):
        marker.unlink(missing_ok=True)
    render_config()

    model = os.environ.get("CANARY_MODEL", "gpt-5.5")
    nonce = os.environ.get("CANARY_NONCE", "NATIVE-RESUME-CANARY")

    print(f"CODEX_CANARY_START model={model} pid={os.getpid()}", flush=True)
    first_session = run_turn(
        "CODEX_TURN1",
        ["exec"],
        (
            "First turn of a native-session resume canary. Remember the nonce "
            f"{nonce}. Then reply exactly FIRST_CODEX_TURN_COMPLETE."
        ),
    )
    first_session = first_session or _newest_rollout_session_id()
    if not first_session:
        raise RuntimeError("The first codex exec produced no session id")

    READY.write_text(
        f"session_id={first_session}\ncontroller_pid={os.getpid()}\n",
        encoding="utf-8",
    )
    print(
        f"CODEX_CANARY_READY session_id={first_session} pid={os.getpid()}",
        flush=True,
    )
    while not CONTINUE.exists():
        time.sleep(0.2)

    print(
        f"CODEX_CANARY_RESTORED session_id={first_session} pid={os.getpid()}",
        flush=True,
    )
    second_session = run_turn(
        "CODEX_TURN2",
        ["exec", "resume", first_session],
        (
            "Second turn after CRIU restore. Without reading any file, state the "
            "exact nonce from the previous turn. Then use the shell to append the "
            f"exact line 'CODEX_SESSION_RESUMED {nonce}' to "
            "/workspace/native-resume-evidence.txt and reply exactly "
            "SECOND_CODEX_TURN_COMPLETE."
        ),
    )

    same_session = bool(second_session) and second_session == first_session
    expected_evidence = f"CODEX_SESSION_RESUMED {nonce}"
    evidence_ok = (
        EVIDENCE.exists()
        and EVIDENCE.read_text(encoding="utf-8").strip() == expected_evidence
    )
    print(
        "CODEX_CANARY_COMPLETE "
        f"original_session={first_session} resumed_session={second_session} "
        f"same_session={same_session} evidence_ok={evidence_ok}",
        flush=True,
    )
    if not same_session or not evidence_ok:
        raise RuntimeError("Native Codex session resume validation failed")


if __name__ == "__main__":
    main()
