#!/usr/bin/env python3
"""Build one credential-free robustness result from controller/verifier logs."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    for name in (
        "log", "turn1_log", "output", "run_id", "campaign_id", "git_sha",
        "task_id", "dataset_sha256", "model", "mode", "checkpoint_state",
        "docker_version", "runc_version", "criu_version", "kernel",
    ):
        parser.add_argument("--" + name.replace("_", "-"), required=True)
    for name in (
        "replicate", "resume_delay_ms", "checkpoint_ms", "restore_ms",
        "verifier_exit", "verifier_ms", "total_ms",
    ):
        parser.add_argument("--" + name.replace("_", "-"), type=int, required=True)
    parser.add_argument("--before-pid", required=True)
    parser.add_argument("--after-pid", required=True)
    parser.add_argument("--checkpoint-created", choices=("true", "false"), required=True)
    parser.add_argument("--restored", choices=("true", "false"), required=True)
    parser.add_argument("--reward", type=float, required=True)
    return parser.parse_args()


def marker_json(text: str, marker: str) -> dict[str, Any]:
    for line in text.splitlines():
        if line.startswith(marker + " "):
            return json.loads(line[len(marker) + 1 :])
    return {}


def nullable_pid(value: str) -> int | None:
    return None if value == "null" else int(value)


def jsonl_stats(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "exists": bool(value.get("exists", False)),
        "parseable": bool(value.get("parseable", False)),
        "bytes": int(value.get("bytes", 0)),
        "lines": int(value.get("lines", 0)),
        "sha256": value.get("sha256"),
    }


def main() -> None:
    args = parse_args()
    log_path = Path(args.log)
    turn1_path = Path(args.turn1_log)
    log = log_path.read_text(encoding="utf-8", errors="replace")
    turn1_log = turn1_path.read_text(encoding="utf-8", errors="replace") if turn1_path.exists() else ""
    combined = turn1_log + "\n" + log

    before = marker_json(combined, "TASK_SESSION_BEFORE")
    after_restore = marker_json(log, "TASK_SESSION_AFTER_RESTORE")
    complete = marker_json(log, "TASK_HANDOFF_COMPLETE")
    epochs = re.findall(r"TASK_CONTROLLER_START .*?epoch=([0-9a-f]+)", combined)
    entrypoint_starts = combined.count("TASK_CONTROLLER_START ")
    quiescence = before.get("quiescence", {})
    jsonl_before = before.get("jsonl_before", {})
    jsonl_after_restore = after_restore
    jsonl_after_turn2 = complete.get("jsonl_after_turn2", {})

    same_session = bool(complete.get("same_session", False))
    evidence = bool(complete.get("semantic_evidence", False))
    task_pass = args.reward == 1.0
    checkpoint_created = args.checkpoint_created == "true"
    restored = args.restored == "true"
    true_criu = (
        args.mode != "criu_stable"
        or (
            checkpoint_created
            and restored
            and len(epochs) == 1
            and before.get("controller_epoch") == complete.get("controller_epoch_after")
        )
    )
    status = "pass" if same_session and evidence and task_pass and true_criu else "fail"
    failure_stage = None
    if not same_session or not evidence:
        failure_stage = "native_resume"
    elif not true_criu:
        failure_stage = "criu_restore"
    elif not task_pass:
        failure_stage = "verifier"

    result = {
        "schema_version": "1.0.0",
        "run_id": args.run_id,
        "campaign_id": args.campaign_id,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "git_sha": args.git_sha,
        "replicate": args.replicate,
        "seed": None,
        "task": {
            "suite": "terminal-bench",
            "version": "2.1",
            "id": args.task_id,
            "dataset_sha256": args.dataset_sha256,
        },
        "route": {
            "source_model": args.model,
            "target_model": args.model,
            "requested_model_turn1": before.get("source_model", args.model),
            "requested_model_turn2": complete.get("requested_model_turn2", args.model),
            "observed_model_turn1": before.get("observed_model_turn1"),
            "observed_model_turn2": complete.get("observed_model_turn2"),
        },
        "treatment": {
            "mode": args.mode,
            "checkpoint_timing": "post_turn_quiescent",
            "resume_signal_delay_ms": args.resume_delay_ms,
            "fault": {"kind": "none", "parameters": {}},
        },
        "runtime": {
            "sdk_version": "0.2.115",
            "docker_version": args.docker_version,
            "runc_version": args.runc_version,
            "criu_version": args.criu_version,
            "kernel": args.kernel,
            "host_fingerprint": "aliyun-linux-admin",
        },
        "checkpoint": {
            "attempted": args.mode == "criu_stable",
            "created": checkpoint_created,
            "state_after_create": args.checkpoint_state,
            "restored": restored,
            "entrypoint_start_count": entrypoint_starts,
            "controller_epoch_before": before.get("controller_epoch"),
            "controller_epoch_after": complete.get("controller_epoch_after"),
            "container_pid_before": 1 if before else None,
            "container_pid_after": 1 if complete else None,
            "host_pid_before": nullable_pid(args.before_pid),
            "host_pid_after": nullable_pid(args.after_pid),
            "quiescence": {
                "child_processes": quiescence.get("child_processes"),
                "established_tcp": quiescence.get("established_tcp"),
                "pidfd": quiescence.get("pidfd"),
                "stable_for_ms": quiescence.get("stable_for_ms"),
            },
        },
        "session": {
            "resume_requested": True,
            "resume_accepted": bool(complete),
            "id_before": before.get("session_id"),
            "id_after": complete.get("session_id_after"),
            "same_id": same_session,
            "jsonl": {
                "before": jsonl_stats(jsonl_before),
                "after_restore": jsonl_stats(jsonl_after_restore),
                "after_turn2": jsonl_stats(jsonl_after_turn2),
            },
        },
        "validation": {
            "semantic_evidence": evidence,
            "verifier_exit_code": args.verifier_exit,
            "task_reward": args.reward,
            "task_pass": task_pass,
        },
        "timing_ms": {
            "turn1": before.get("turn1_ms"),
            "quiescence_wait": quiescence.get("wait_ms"),
            "checkpoint": args.checkpoint_ms,
            "restore": args.restore_ms,
            "resume_to_first_event": complete.get("turn2_first_event_ms"),
            "turn2": complete.get("turn2_ms"),
            "verifier": args.verifier_ms,
            "total": args.total_ms,
        },
        "outcome": {
            "status": status,
            "failure_stage": failure_stage,
            "expected_unsupported": False,
            "error_class": None,
            "error_message_sanitized": None,
        },
        "cleanup": {
            "runtime_removed": False,
            "main_docker_untouched": None,
            "secret_scan_clean": None,
        },
    }
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
