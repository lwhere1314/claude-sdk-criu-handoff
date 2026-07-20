"""The ``harbor-resume`` command.

    harbor-resume run --dataset D --task T --model A [-- <extra harbor args>]
        -> runs stock `harbor run` wired with the CRIU agent/environment,
           snapshots at the boundary, prints a resume id.

    harbor-resume <id> [--model B] [--task T]
        -> restores that snapshot and continues with model B (or the original),
           re-snapshots, and verifies.

    harbor-resume ls | status <id>

Shells out to the ``harbor`` CLI; it does not import Harbor, so the wiring is
exercisable without Harbor installed.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
import uuid

from harbor_resume import collect, registry

AGENT = "harbor_resume.agent:ControllerCodexAgent"
ENV = "harbor_resume.env:CriuDockerEnvironment"


def _harbor_run(model: str, dataset: str | None, task: str | None,
                run_id: str, resume: bool, passthrough: list[str]) -> int:
    cmd = ["harbor", "run", "--agent", AGENT, "--env", ENV, "--model", model,
           "--agent-kwarg", f"hr_run_id={run_id}",
           "--environment-kwarg", f"hr_run_id={run_id}"]
    if resume:
        cmd += ["--agent-kwarg", "hr_resume=true",
                "--environment-kwarg", "hr_restore=true"]
    if dataset:
        cmd += ["--dataset", dataset]
    if task:
        cmd += ["--task", task]
    cmd += passthrough
    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.run(cmd).returncode


def cmd_run(args: argparse.Namespace) -> int:
    run_id = uuid.uuid4().hex[:12]
    registry.save(registry.SnapshotRecord(
        run_id=run_id, fs_image="", dataset=args.dataset, task_id=args.task,
        model=args.model,
    ))
    since = time.time()
    rc = _harbor_run(args.model, args.dataset, args.task, run_id,
                     resume=False, passthrough=args.rest)
    before = collect.collect(run_id, "before", since)
    collect.write_summary(run_id, before, None)
    if rc == 0:
        print(f"\nresume id: {run_id}")
        if before.get("found"):
            print(f"before trajectory: {before['dir']}  (reward={before.get('reward','?')})")
        print(f"resume with: harbor-resume {run_id} [--model <other>]")
    else:
        print(f"harbor run failed ({rc}); snapshot may be incomplete for {run_id}",
              file=sys.stderr)
    return rc


def cmd_resume(args: argparse.Namespace) -> int:
    try:
        record = registry.load(args.run_id)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    model = args.model or record.model
    if not model:
        print("No model recorded for this run; pass --model.", file=sys.stderr)
        return 2
    task = args.task or record.task_id
    since = time.time()
    rc = _harbor_run(model, record.dataset, task, args.run_id,
                     resume=True, passthrough=args.rest)
    after = collect.collect(args.run_id, "after", since)
    record = registry.load(args.run_id)  # env re-wrote it during the pass
    record.history.append({"model": model, "returncode": rc,
                           "after_reward": after.get("reward")})
    registry.save(record)
    # refresh summary with both halves
    import json as _json
    before = None
    summary_path = collect.data_dir() / args.run_id / "summary.json"
    if summary_path.exists():
        try:
            before = _json.loads(summary_path.read_text(encoding="utf-8")).get("before")
        except (OSError, ValueError):
            before = None
    collect.write_summary(args.run_id, before, after)
    if rc == 0:
        print(f"\nresumed {args.run_id} with model {model}; still resumable.")
        if after.get("found"):
            b = (before or {}).get("reward", "?")
            print(f"after trajectory: {after['dir']}  (reward {b} -> {after.get('reward','?')})")
    return rc


def cmd_ls(_: argparse.Namespace) -> int:
    runs = registry.list_runs()
    if not runs:
        print("no harbor-resume runs")
        return 0
    for r in runs:
        print(f"{r.run_id}  passes={r.passes}  model={r.model}  task={r.task_id}  image={r.fs_image}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    try:
        r = registry.load(args.run_id)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(f"run_id   : {r.run_id}")
    print(f"dataset  : {r.dataset}")
    print(f"task     : {r.task_id}")
    print(f"model    : {r.model}")
    print(f"session  : {r.session_id}")
    print(f"fs_image : {r.fs_image}")
    print(f"criu     : {r.criu_name} ({r.criu_dir})")
    print(f"passes   : {r.passes}")
    for i, h in enumerate(r.history, 1):
        print(f"  pass {i}: {h}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="harbor-resume", description=__doc__)
    sub = p.add_subparsers(dest="command")

    pr = sub.add_parser("run", help="run a task and snapshot it at the boundary")
    pr.add_argument("--dataset")
    pr.add_argument("--task")
    pr.add_argument("--model", required=True)
    pr.set_defaults(func=cmd_run)

    prs = sub.add_parser("resume", help="resume a snapshotted run by id")
    prs.add_argument("run_id")
    prs.add_argument("--model")
    prs.add_argument("--task")
    prs.set_defaults(func=cmd_resume)

    sub.add_parser("ls", help="list resumable runs").set_defaults(func=cmd_ls)

    pst = sub.add_parser("status", help="show a run's snapshot metadata")
    pst.add_argument("run_id")
    pst.set_defaults(func=cmd_status)
    return p


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    # Everything after a standalone `--` is forwarded verbatim to `harbor run`.
    passthrough: list[str] = []
    if "--" in argv:
        idx = argv.index("--")
        argv, passthrough = argv[:idx], argv[idx + 1:]
    # Shorthand: `harbor-resume <id>` == `harbor-resume resume <id>`.
    known = {"run", "resume", "ls", "status", "-h", "--help"}
    if argv and argv[0] not in known:
        argv = ["resume", *argv]
    parser = build_parser()
    args = parser.parse_args(argv)
    args.rest = passthrough
    if not getattr(args, "func", None):
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
