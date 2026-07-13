# Claude SDK + CRIU Native Session Handoff

A minimal, standalone experiment that checkpoints a waiting Python controller
with CRIU, restores it, and continues the same native Claude Agent SDK session
with `resume=session_id`.

The second turn is **not** reconstructed from a rendered trajectory. The SDK's
native session files and workspace survive inside the restored container.

## What the canary proves

1. A Claude Agent SDK turn runs to completion and returns a native `session_id`.
2. The Claude CLI subprocess and its HTTPS connection exit.
3. Docker/CRIU checkpoints the waiting PID 1 controller; the same container's
   writable layer retains the native session files and workspace.
4. The container is restored from that checkpoint.
5. A new SDK query uses `ClaudeAgentOptions(resume=session_id)`.
6. The resumed model recalls a nonce from turn one and uses Bash to write an
   exact evidence line.
7. The run passes only if the session IDs and evidence both match.

This tests restoration at a **stable model-turn boundary**. It does not claim
to migrate a live TLS connection or an in-flight model generation.

## Requirements

- Linux host with root or passwordless `sudo`
- `containerd`, `dockerd`, Docker CLI, `runc`, and CRIU on `PATH`
- `criu check` passes
- Outbound access to the configured Anthropic-compatible coding endpoint

Tested on:

- Alibaba Cloud Linux 3
- Linux `5.10.134-19.2.al8.x86_64`
- Docker `26.1.3`, containerd `1.6.32`, runc `1.1.12`, CRIU `3.18`
- `claude-agent-sdk==0.2.115`

See the [verified run](docs/verified-run.md) for the recorded end-to-end result.

## Quick start

```bash
cp .env.example .env
chmod 600 .env
# Edit .env and set the Seed Coding Plan key.
./scripts/run-canary.sh
```

Alternatively, export `CODING_PLAN_BASE_URL` and `CODING_PLAN_API_KEY`; the
runner accepts those variables without creating `.env`.

The script automatically elevates with `sudo`, starts an isolated experimental
Docker daemon under `/tmp`, runs the experiment, writes sanitized results under
`artifacts/`, and removes the isolated runtime on exit. It does not reconfigure
or restart the host's main Docker daemon.

The user-facing `CODING_PLAN_*` settings are mapped to the standard
`ANTHROPIC_*` variables only inside the canary container because those are the
variables consumed by Claude Code. No Seed Agent Plan configuration is read,
aliased, or reused.

## Expected result

```text
PASS: native SDK session resumed after CRIU restore
Artifacts: .../artifacts/<timestamp>
```

The artifact directory contains:

- `result.md`: pass/fail facts, session ID, and host PID transition
- `container.log`: compact SDK events with no API key
- `evidence.txt`: the exact tool-written nonce evidence

## Security model

The API key is never copied into the image or retained in artifacts. During a
run it necessarily exists in the container environment and therefore in the
checkpoint. The runner always deletes the entire isolated Docker data root and
checkpoint on exit. If the runner is killed with `SIGKILL` or the host crashes,
clean the runtime before reusing the machine:

```bash
./scripts/cleanup-runtime.sh
```

Never commit `.env`; it is ignored by Git.

## Repository checks

```bash
make check
```

The GitHub Actions workflow performs static Python and shell syntax checks. The
full CRIU test is intentionally host-run because hosted CI runners generally do
not provide this daemon/checkpoint setup.

## Terminal-Bench 2.1 robustness matrix

`scripts/run-task-matrix.sh` layers the SDK controller onto a real
Terminal-Bench task image without adding the task's tests to the agent image.
It supports three treatments:

- `uninterrupted`: two native SDK turns in one controller, without CRIU
- `native_resume_cold`: export the post-turn filesystem without container
  environment metadata, start a new PID 1 controller, and resume the session
- `criu_stable`: checkpoint and restore the waiting PID 1 controller before
  the second SDK turn

Example:

```bash
./scripts/run-task-matrix.sh \
  --task-dir /path/to/terminal-bench-2.1/query-optimize \
  --models kimi-k2.6,doubao-seed-2.0-code,doubao-seed-2.0-pro \
  --modes uninterrupted,criu_stable \
  --repeats 1
```

Phase 1 is deliberately read-only and exposes only `Read`, `Glob`, and `Grep`.
This creates a comparable quiescent checkpoint boundary across models. Phase 2
explicitly exposes `Read`, `Write`, `Edit`, `Bash`, `Glob`, and `Grep` and must
produce the real task artifact. Private tests are copied into the container
only after phase 2 completes; the external task verifier supplies the reward.

Because the CLI runs with `bypassPermissions`, phase 1 also hard-denies Bash,
write/edit, subagent, and web tools. This is an experimental cut-point guard,
not a requirement of CRIU or SDK resume: a model may still propose a denied
tool call, but it cannot execute it before the checkpoint.

Every run retains a credential-free `run.json`, controller log, verifier log,
reward, and semantic continuity evidence. The isolated daemon uses a separate
data root and is removed after the campaign.

Aggregate one or more campaigns without reading raw credential-bearing runtime
state:

```bash
python3 scripts/aggregate-results.py artifacts/task-matrix
```

## Fixed cross-model takeover

`scripts/run-fixed-takeover.sh` is the task-level experiment for a real coding
boundary. With `--source-strategy write_run_py`, the source model may inspect
the task and use normal coding tools. An SDK `PostToolUse` hook stops the turn
immediately after the first successful tool call that leaves a non-empty
`run.py`. With `--source-strategy attempt`, the source instead receives a full
coding attempt, so a naturally failing final workspace and its native session
can be frozen. The runner then:

1. records the workspace and native-session hashes;
2. verifies the source workspace without exposing held-out tests beforehand;
3. checkpoints the quiescent PID 1 controller with CRIU;
4. restores the exact workspace and SDK session;
5. resumes that session with the requested target model; and
6. verifies the target workspace and records whether `run.py` changed.

Example:

```bash
./scripts/run-fixed-takeover.sh \
  --task-dir /path/to/terminal-bench-2.1/cancel-async-tasks \
  --source-model kimi-k2.6 \
  --target-models kimi-k2.7-code \
  --source-strategy write_run_py
```

Add `--source-only` to sample and score independent source cutpoints without
running a target continuation. Each campaign still creates and hashes a real
CRIU checkpoint, runs the held-out verifier against the frozen workspace, and
then removes the sensitive checkpoint pages and isolated daemon data root.
This mode is useful for estimating how often a source model's first
implementation is already correct before selecting fixed failures for target
takeover experiments.

Use `--source-checkpoint-input` to repeat targets from an already captured
credential-free source directory containing `run.py`, `native-manifest.json`,
and `native-session/`. This rehydrates the exact workspace and SDK session in
a new waiting controller, records the original controller epoch, and creates a
new CRIU checkpoint. It does not claim to resurrect deleted CRIU page images.
The rehydrated controller does not call the source model again.

For a controlled multi-target comparison, invoke the runner once per target
with the same `--source-checkpoint-input`. Each target then receives its own
CRIU-restored waiting controller while the input workspace and native-session
hashes remain identical. Docker 26 does not support restoring one checkpoint
into a differently named container via a custom checkpoint directory; a
multi-model CSV therefore records later targets as `native_resume_cold` when
that clone attempt is rejected, rather than mislabeling them as CRIU restores.

Source correctness, agent completion, and final task correctness are separate
measurements. A first `run.py` may already pass, and an agent may time out after
producing correct code. The timeout path therefore freezes and independently
verifies the final workspace instead of assigning a synthetic zero reward.

The read-only Phase 1 restrictions described above apply to
`run-task-matrix.sh`, not this fixed coding boundary. The fixed takeover runner
must allow write and execution tools before its explicit hook cutpoint.

The retained source directory is an auditable, credential-free rehydration
bundle, not a portable process snapshot. It stores the workspace, native SDK
session, manifests, verifier output, image identity, and a content hash of the
CRIU checkpoint. Raw CRIU memory pages and the isolated Docker data root are
deleted because process memory may contain API credentials. Exact CRIU restore
is available only while a live campaign retains those pages; later experiments
can rehydrate the same workspace and native session in a new controller.

### Interpretation boundary

The CRIU treatment restores the local PID 1 controller's memory and execution
point. A fresh Claude CLI process then performs the official SDK native resume
from the session JSONL. The experiment therefore demonstrates compatibility
between CRIU controller restoration and native session resume; it does not
claim that CRIU restores an in-flight remote model generation or its TLS
connection. Active-generation recovery is a separate, explicitly unsupported
probe until TCP, pidfd, remote timeout, and idempotent replay constraints are
handled.

See [offline and online restore boundaries](docs/offline-vs-online-restore.md)
for the staged active-restore design.

See the [Terminal-Bench 2.1 smoke results](docs/robustness-smoke-results.md)
for the current multi-task, multi-model evidence and its interpretation limits.
