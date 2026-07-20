# Codex CLI + CRIU Native Session Handoff

A parallel of the [Claude SDK canary](../README.md) built on the **Codex CLI**
(`codex exec`). It checkpoints a waiting Python controller with CRIU, restores
it, and continues the same native Codex session with
`codex exec resume <session_id>`.

The second turn is **not** reconstructed from a rendered trajectory. Codex's
native rollout file under `$CODEX_HOME/sessions` and the workspace survive inside
the restored container.

## What the canary proves

1. A `codex exec` turn runs to completion and returns a native session ID.
2. The `codex` process and its HTTPS connection exit.
3. Docker/CRIU checkpoints the waiting PID 1 controller and filesystem.
4. The container is restored from that checkpoint.
5. A new turn runs `codex exec resume <session_id>`, which continues the same
   persisted rollout.
6. The resumed model recalls a nonce from turn one and uses the shell to write an
   exact evidence line.
7. The run passes only if the session IDs and evidence both match.

This tests restoration at a **stable model-turn boundary**. It does not claim to
migrate a live TLS connection or an in-flight model generation.

## How it differs from the Claude canary

| Claude SDK canary | Codex CLI canary |
| --- | --- |
| `claude-agent-sdk` (pip) | `@openai/codex` CLI (npm, pinned) |
| `ClaudeAgentOptions(resume=session_id)` | `codex exec resume <session_id>` |
| `CLAUDE_CONFIG_DIR=/workspace/.claude` | `CODEX_HOME=/workspace/.codex` |
| Anthropic-compatible endpoint (`ANTHROPIC_*`) | OpenAI-compatible endpoint via a Codex `model_provider` |

The controller renders `$CODEX_HOME/config.toml` at startup with a custom
`[model_providers.coding_plan]` block pointing at the OpenAI-SDK-compatible
(Responses API) endpoint, with `wire_api = "responses"` (Codex 0.144+ dropped
`chat`). The API key is never written to the file; Codex reads it at runtime from
the provider's `env_key` (`OPENAI_API_KEY`).

## Requirements

- Linux host with root or passwordless `sudo`
- `containerd`, `dockerd`, Docker CLI, `runc`, and CRIU on `PATH`
- `criu check` passes
- Outbound access to the configured OpenAI-compatible coding endpoint

## Quick start

```bash
cp .env.example .env
chmod 600 .env
# Edit .env: set OPENAI_BASE_URL, OPENAI_API_KEY, and an OpenAI-compatible model.
./scripts/run-canary.sh
```

Alternatively, export `OPENAI_BASE_URL` and `OPENAI_API_KEY`; the runner accepts
those variables without creating `.env`.

The script automatically elevates with `sudo`, starts an isolated experimental
Docker daemon under `/tmp`, runs the experiment, prints the sanitized result to
stdout, and removes the isolated runtime on exit. Nothing is written into the
repository. It does not reconfigure or restart the host's main Docker daemon.

## Expected result

```text
PASS: native Codex session resumed after CRIU restore
  Model:                     gpt-5.5
  Native session ID:         019f7f59-9e10-7663-8258-b777dce15ddd
  Host PID before checkpoint: 61214
  Host PID after restore:     61639
  Checkpoint state:          exited
  Same native session:       true
  Evidence validated:        true
```

Validation (session IDs match, exact tool-written nonce evidence, container
`exited` after checkpoint) happens inside the isolated runtime dir, which is
removed on exit. No API key or container inspection output is retained.

## Security model

The API key is never copied into the image or written to disk by the runner.
During a run it necessarily exists in the container environment and therefore in
the checkpoint. The runner always deletes the entire isolated Docker data root and
checkpoint on exit. If the runner is killed with `SIGKILL` or the host crashes,
clean the runtime before reusing the machine:

```bash
./scripts/cleanup-runtime.sh
```

Never commit `.env`; it is ignored by Git.

## Repository checks

```bash
python3 -m py_compile src/controller.py
bash -n scripts/run-canary.sh scripts/cleanup-runtime.sh
```

The GitHub Actions workflow performs these static Python and shell syntax checks.
The full CRIU test is intentionally host-run because hosted CI runners generally
do not provide this daemon/checkpoint setup.
