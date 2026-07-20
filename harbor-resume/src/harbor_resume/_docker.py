"""Thin wrappers over the Docker CLI for the paired snapshot/restore.

Isolated from Harbor so it can be exercised on its own. All functions shell out
to ``docker``; the daemon must be started with ``--experimental`` for
``checkpoint``/``start --checkpoint`` (CRIU) to be available, and CRIU must be on
PATH — the same requirement as this repo's ``codex-cli`` canary.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


class DockerError(RuntimeError):
    pass


def _run(args: list[str], *, capture: bool = True) -> str:
    proc = subprocess.run(
        ["docker", *args],
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        raise DockerError(
            f"docker {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()}"
        )
    return (proc.stdout or "").strip()


def compose_main_container_id(project: str, service: str = "main") -> str:
    """Resolve the running container id for a compose project's main service."""
    cid = _run(["compose", "-p", project, "ps", "-q", service])
    if not cid:
        # Fall back to a label filter in case the project uses classic naming.
        cid = _run(
            [
                "ps",
                "-q",
                "--filter",
                f"label=com.docker.compose.project={project}",
                "--filter",
                f"label=com.docker.compose.service={service}",
            ]
        ).splitlines()[:1]
        cid = cid[0] if cid else ""
    if not cid:
        raise DockerError(f"No running container for project={project} service={service}")
    return cid


def commit(container_id: str, image: str) -> None:
    """Filesystem snapshot: the agent's whole workspace + $CODEX_HOME/sessions."""
    _run(["commit", container_id, image])


def checkpoint(container_id: str, name: str, checkpoint_dir: Path) -> None:
    """CRIU dump of the live (idle keepalive) process. Leaves the container running.

    Demonstrative: the functional resume is carried by the committed image; this
    proves the native CRIU handoff at a stable boundary (no live codex child).
    """
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    _run(
        [
            "checkpoint",
            "create",
            "--checkpoint-dir",
            str(checkpoint_dir),
            "--leave-running=true",
            container_id,
            name,
        ]
    )


def checkpoint_available() -> bool:
    """True if the daemon exposes experimental checkpoint support."""
    try:
        _run(["checkpoint", "--help"])
        return True
    except DockerError:
        return False


def image_exists(image: str) -> bool:
    try:
        _run(["image", "inspect", image])
        return True
    except DockerError:
        return False
