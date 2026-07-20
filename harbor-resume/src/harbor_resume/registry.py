"""Run-id → snapshot registry, shared by the CLI, the custom agent, and the
custom environment.

A record is written when a run is snapshotted and read when it is resumed. It is
the only state that must survive between the two separate ``harbor`` invocations,
so it lives on the host under ``$HARBOR_RESUME_HOME`` (default ``~/.harbor-resume``).

Nothing here imports Harbor, so it is fully unit-testable on its own.
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path


def home() -> Path:
    root = os.environ.get("HARBOR_RESUME_HOME")
    return Path(root) if root else Path.home() / ".harbor-resume"


@dataclass
class SnapshotRecord:
    """Everything needed to resume a run in a later process."""

    run_id: str
    # Paired snapshot artifacts (see env.CriuDockerEnvironment.snapshot):
    fs_image: str  # `docker commit` tag, e.g. "harbor-resume/<run-id>:latest"
    criu_dir: str | None = None  # `docker checkpoint --checkpoint-dir` path (demonstrative)
    criu_name: str | None = None  # checkpoint name, if a CRIU dump was taken
    # Provenance for re-launching the same task with the same-or-overridden model:
    dataset: str | None = None
    task_id: str | None = None
    model: str | None = None  # model used for the pass that produced this snapshot
    session_id: str | None = None  # native Codex session id (stable across resumes)
    passes: int = 1  # how many times this run has been (re)snapshotted
    history: list[dict] = field(default_factory=list)  # per-pass {model, verifier}

    def path(self) -> Path:
        return home() / f"{self.run_id}.json"


def save(record: SnapshotRecord) -> Path:
    home().mkdir(parents=True, exist_ok=True)
    path = record.path()
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(asdict(record), indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)
    return path


def load(run_id: str) -> SnapshotRecord:
    path = home() / f"{run_id}.json"
    if not path.exists():
        raise KeyError(f"No harbor-resume snapshot for run id {run_id!r} at {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    return SnapshotRecord(**data)


def exists(run_id: str) -> bool:
    return (home() / f"{run_id}.json").exists()


def list_runs() -> list[SnapshotRecord]:
    if not home().exists():
        return []
    records: list[SnapshotRecord] = []
    for path in sorted(home().glob("*.json")):
        try:
            records.append(SnapshotRecord(**json.loads(path.read_text(encoding="utf-8"))))
        except (json.JSONDecodeError, TypeError):
            continue
    return records
