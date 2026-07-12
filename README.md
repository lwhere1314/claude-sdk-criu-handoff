# Claude SDK + CRIU Native Session Handoff

A minimal, standalone experiment that checkpoints a waiting Python controller
with CRIU, restores it, and continues the same native Claude Agent SDK session
with `resume=session_id`.

The second turn is **not** reconstructed from a rendered trajectory. The SDK's
native session files and workspace survive inside the restored container.

## What the canary proves

1. A Claude Agent SDK turn runs to completion and returns a native `session_id`.
2. The Claude CLI subprocess and its HTTPS connection exit.
3. Docker/CRIU checkpoints the waiting PID 1 controller and filesystem.
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
