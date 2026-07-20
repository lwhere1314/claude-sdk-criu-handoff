"""Collect the before/after Harbor trajectories into the repo's ``data/`` dir.

Each `harbor run` (pass 1 and the resume) writes an ATIF ``trajectory.json`` into
its trial's agent dir under Harbor's jobs directory. We don't depend on Harbor
printing the job id: we snapshot the time before a run and then pick the
``trajectory.json`` (and its sibling reward) that Harbor wrote after that instant.

Layout produced:
    <repo>/data/<run-id>/
        before/  trajectory.json  reward.txt  result.json
        after/   trajectory.json  reward.txt  result.json
        summary.json
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path


def data_dir() -> Path:
    override = os.environ.get("HARBOR_RESUME_DATA")
    if override:
        return Path(override)
    # <repo>/harbor-resume/src/harbor_resume/collect.py -> repo root is parents[3]
    return Path(__file__).resolve().parents[3] / "data"


def _jobs_roots() -> list[Path]:
    roots: list[Path] = []
    env = os.environ.get("HARBOR_JOBS_DIR")
    if env:
        roots.append(Path(env))
    # Common Harbor defaults; harmless if absent.
    home = Path.home()
    roots += [home / ".harbor" / "jobs", home / "harbor" / "jobs",
              Path.cwd() / "jobs", home / ".harbor"]
    return [r for r in roots if r.exists()]


def _newest_trajectory(since: float) -> Path | None:
    newest: tuple[float, Path] | None = None
    for root in _jobs_roots():
        for traj in root.rglob("trajectory.json"):
            try:
                mtime = traj.stat().st_mtime
            except OSError:
                continue
            if mtime + 1e-6 >= since and (newest is None or mtime > newest[0]):
                newest = (mtime, traj)
    return newest[1] if newest else None


def _find_reward(trial_dir: Path) -> Path | None:
    for name in ("verifier/reward.txt", "verifier/reward.json", "reward.txt", "reward.json"):
        p = trial_dir / name
        if p.exists():
            return p
    hits = list(trial_dir.rglob("reward.txt")) or list(trial_dir.rglob("reward.json"))
    return hits[0] if hits else None


def _find_result(trial_dir: Path) -> Path | None:
    hits = sorted(trial_dir.glob("*result*.json")) or sorted(trial_dir.rglob("*result*.json"))
    return hits[0] if hits else None


def collect(run_id: str, role: str, since: float) -> dict:
    """Copy the trajectory Harbor just wrote (+ reward/result) into data/<run-id>/<role>/.

    `role` is "before" or "after". Returns a small summary dict (best-effort;
    missing files are simply skipped so this never breaks the run).
    """
    out = data_dir() / run_id / role
    summary: dict = {"role": role, "found": False, "dir": str(out)}
    traj = _newest_trajectory(since)
    if traj is None:
        return summary
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy2(traj, out / "trajectory.json")
    summary["found"] = True
    summary["source"] = str(traj)

    trial_dir = traj.parents[1] if len(traj.parents) >= 2 else traj.parent
    reward = _find_reward(trial_dir)
    if reward:
        shutil.copy2(reward, out / reward.name)
        try:
            summary["reward"] = reward.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    result = _find_result(trial_dir)
    if result:
        shutil.copy2(result, out / "result.json")
    return summary


def write_summary(run_id: str, before: dict | None, after: dict | None) -> Path:
    out = data_dir() / run_id
    out.mkdir(parents=True, exist_ok=True)
    path = out / "summary.json"
    payload = {"run_id": run_id, "before": before, "after": after}
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return path
