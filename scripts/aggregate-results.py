#!/usr/bin/env python3
"""Aggregate credential-free Terminal-Bench handoff run.json files."""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="Artifact root or campaign directory")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of Markdown")
    return parser.parse_args()


def ratio(successes: int, total: int) -> str:
    return f"{successes}/{total} ({successes / total:.0%})" if total else "0/0"


def load_runs(root: Path) -> list[dict[str, Any]]:
    runs = []
    for path in sorted(root.rglob("run.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        data["_path"] = str(path)
        runs.append(data)
    return runs


def aggregate(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = collections.defaultdict(list)
    for run in runs:
        key = (
            run["task"]["id"],
            run["route"]["target_model"],
            run["treatment"]["mode"],
        )
        groups[key].append(run)

    rows = []
    for (task, model, mode), values in sorted(groups.items()):
        total = len(values)
        restore_attempted = sum(value["checkpoint"]["attempted"] for value in values)
        restore_ok = sum(
            value["checkpoint"]["attempted"]
            and (
                value["checkpoint"]["created"]
                and value["checkpoint"]["restored"]
                and value["checkpoint"]["controller_epoch_before"]
                == value["checkpoint"]["controller_epoch_after"]
            )
            for value in values
        )
        handoff_ok = sum(
            value["session"]["same_id"] and value["validation"]["semantic_evidence"]
            for value in values
        )
        task_evaluated = sum(
            value["validation"].get("verifier_exit_code") != 125 for value in values
        )
        task_ok = sum(value["validation"]["task_pass"] for value in values)
        rows.append(
            {
                "task": task,
                "model": model,
                "mode": mode,
                "n": total,
                "restore_attempted": restore_attempted,
                "restore_successes": restore_ok,
                "handoff_successes": handoff_ok,
                "task_evaluated": task_evaluated,
                "task_successes": task_ok,
                "restore_rate": restore_ok / restore_attempted if restore_attempted else None,
                "handoff_rate": handoff_ok / total,
                "task_rate": task_ok / task_evaluated if task_evaluated else None,
            }
        )
    return rows


def markdown(rows: list[dict[str, Any]]) -> str:
    lines = [
        "| Task | Model | Mode | n | Evaluated | Restore | Native handoff | Task pass |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        restore = (
            ratio(row["restore_successes"], row["restore_attempted"])
            if row["restore_attempted"]
            else "n/a"
        )
        lines.append(
            "| {task} | {model} | {mode} | {n} | {task_evaluated} | {restore} | {handoff} | {task_pass} |".format(
                **row,
                restore=restore,
                handoff=ratio(row["handoff_successes"], row["n"]),
                task_pass=ratio(row["task_successes"], row["task_evaluated"]),
            )
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    args = parse_args()
    runs = load_runs(args.root)
    rows = aggregate(runs)
    if args.json:
        print(json.dumps({"run_count": len(runs), "groups": rows}, indent=2, sort_keys=True))
    else:
        print(markdown(rows), end="")


if __name__ == "__main__":
    main()
