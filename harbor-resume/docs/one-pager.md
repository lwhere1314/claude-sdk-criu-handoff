# harbor-resume — one pager

## Problem
Harbor (the Terminal-Bench harness) runs an agent against a task, verifies it, and
throws the container away. There is no way to **pause a run and continue it later**,
and no way to hand a run to a **different model**. We want: run a task, get an id,
and later resume that id — same model or another — in the *identical* environment.

## Idea
Wrap stock `harbor run` (no fork) so that at a stable turn boundary the trial
container is **snapshotted with CRIU + a filesystem commit**, keyed by a run id.
A second command restores that snapshot and continues the native Codex session,
with the model overridden or kept the same.

```
harbor-resume run --dataset terminal-bench@2.0 --task <id> --model A   # -> resume id R
harbor-resume R --model B      # restore R, continue with B, re-snapshot, verify
harbor-resume R                # continue with the original model A
harbor-resume ls | status R
```

## How (no fork — Harbor extension points only)
| Piece | What it does |
|---|---|
| `ControllerCodexAgent` (`--agent`) | Harbor's `Codex` agent + a boundary: run the pass, then trigger the snapshot; on resume run `codex exec resume --last --model X` in the restored container. |
| `CriuDockerEnvironment` (`--env`) | Harbor's `DockerEnvironment` with `keep_containers=True`; `snapshot()` = `docker commit` (fs) + `docker checkpoint` (CRIU); `start()` restores the workspace + session on resume. |
| `registry.py` | run id → snapshot metadata (`~/.harbor-resume/`); the only state shared across the two commands. |
| `cli.py` | `harbor-resume` — resolves the id and wires the agent/env/model into `harbor run`. |

## What resume inherits
Model X continues model A's **full trajectory** (instructions, messages, every
tool call + output) **and** the exact **workspace** A produced (via the committed
image). It does **not** inherit A's private reasoning tokens across a model swap —
the shared history is messages + tool I/O, not the model's private reasoning tokens.

## Honest caveat
At the boundary the `codex` child has already exited, so the live process CRIU
dumps is the container's idle keepalive — a **stable turn boundary**, not an
in-flight generation. Functional state rides on the committed image; the CRIU dump
demonstrates the native-handoff mechanism (the same claim the repo README makes).
If a base image can't be CRIU-checkpointed, the fs commit alone still resumes
correctly; only the live-process demo is lost.

## Requirements
Installed `harbor` + Codex CLI · Docker daemon with `--experimental` · CRIU on
PATH · OpenAI-SDK-compatible `OPENAI_BASE_URL` / `OPENAI_API_KEY`.

## Status
- Static checks green; `registry`/`_docker`/`cli` import-checked; run→resume→resume
  wiring verified against a stub `harbor` (model override + passthrough correct).
- `env.py`/`agent.py` subclass Harbor internals; lines marked `# HOST-VALIDATE`
  (CODEX_HOME, `environment.exec`, compose container-id, `docker commit`/
  `checkpoint`) and the end-to-end snapshot/restore are **host-only**, like the
  repo's CRIU canary.
