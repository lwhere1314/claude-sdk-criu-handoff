# Offline and online restore boundaries

This repository intentionally starts with an **offline stable boundary**.  A
model turn has finished, its Claude CLI child has exited, and PID 1 waits with
no child process, established TCP socket, or pidfd.  Docker/CRIU then restores
that waiting controller.  After restore, a new CLI child continues the native
SDK session with `resume=session_id`.

A Docker image is only a filesystem/configuration template, not a running
process snapshot. A Docker checkpoint stores CRIU process state, while the
container's writable layer remains separate; it is not a rewindable filesystem
snapshot. The `native_resume_cold` control explicitly exports/imports that
filesystem and starts a new PID 1 to measure image-only offline recovery.

That design restores two different kinds of state without conflating them:

- CRIU restores the local controller's memory and execution point.
- Claude Agent SDK restores conversational state from its native session
  JSONL and workspace.

The harness records a random controller epoch, the session ID, and JSONL
line/byte/SHA-256 statistics before checkpoint, immediately after restore, and
after the resumed turn.  A run is not a successful handoff merely because the
task verifier passes.

## Why phase 1 has a hard tool deny list

`tools` and `allowed_tools` describe the tools that phase 1 may use.  The
additional `disallowed_tools` list is a cut-point guard while Claude Code runs
with `bypassPermissions`: it prevents a model-generated Bash, write, edit,
subagent, or web call from actually starting at the checkpoint boundary.

This restriction is not a requirement of CRIU or of native SDK resume.  It is
an experimental control used only to make the offline checkpoint comparable
across models and replicates.  Phase 2 re-enables the normal coding tools.

## What "online restore" can mean

There are three materially different targets:

1. **Active local process restore.** CRIU checkpoints the Claude CLI while it
   is running.  This may be testable on one host, but requires explicit policy
   for open TCP sockets, pipes, pidfds, timers, and child processes.
2. **Reconnect and idempotent replay.** The restored controller discards a
   broken remote stream, reconnects, and resumes or retries from a recorded
   request boundary.  This is achievable without claiming byte-for-byte stream
   continuity.
3. **Exact in-flight remote generation restore.** Restoring the provider's
   server-side decoding state and the same TLS stream cannot be guaranteed by
   a checkpoint taken only on the client host.  It requires provider-side
   checkpoint/resume support or an equivalent durable request protocol.

A later `criu_active_probe` should therefore be reported separately from the
offline matrix.  Its first milestone is local CLI survival or a classified
restore failure; its practical milestone is reconnect plus idempotent replay.
Neither result should be presented as exact restoration of remote model
generation.

## Primary references

- [Docker checkpoint command](https://docs.docker.com/reference/cli/docker/checkpoint/)
  documents the feature as experimental and focused on single-host use cases.
- [CRIU TCP connection restore](https://www.criu.org/TCP_connection) describes
  TCP repair, sequence restoration, network locking, and the explicit
  `--tcp-established` opt-in.
- [CRIU external resources](https://criu.org/External_resources) explains why
  resources whose state lives outside the dumped container need caller help
  and may not be generically restorable.
