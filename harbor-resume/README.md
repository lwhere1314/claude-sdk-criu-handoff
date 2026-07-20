# harbor-resume

Snapshot a **Harbor** (Terminal-Bench) run at a stable turn boundary and **resume
it later by run id**, continuing the agent's native Codex session **with the model
overridden or kept the same** — using **CRIU** (plus a filesystem commit) as the
resume medium.

It wraps stock `harbor run` through Harbor's documented extension points
(`--agent module:Class`, `--env module:Class`, `--agent-kwarg`,
`--environment-kwarg`). **No fork of Harbor.**

```
# pass 1: run a task, snapshot the container at the boundary, get a resume id
harbor-resume run --dataset terminal-bench@2.0 --task <id> --model <A>

# resume that id later, with another model (or the same one)
harbor-resume <id> --model <B>
harbor-resume <id>                 # reuse the original model A

harbor-resume ls
harbor-resume status <id>
```

## How it works

| Piece | Role |
| --- | --- |
| `agent.ControllerCodexAgent` (`--agent`) | subclass of Harbor's `Codex`. Runs the pass, then triggers the environment snapshot. On resume, runs `codex exec resume --last --model <X>` directly against the restored container. |
| `env.CriuDockerEnvironment` (`--env`) | subclass of Harbor's `DockerEnvironment`. Forces `keep_containers=True`; `snapshot()` does a paired `docker commit` (fs) + `docker checkpoint` (CRIU) keyed by run id; `start()` restores the committed workspace/session on a resume run. |
| `registry.py` | run id → snapshot metadata under `~/.harbor-resume/`; the only state shared between the two `harbor` commands. |
| `collect.py` | after each pass, copies Harbor's ATIF `trajectory.json` (+ reward/result) into the repo's `data/`. |
| `cli.py` | the `harbor-resume` command that wires the above into `harbor run`. |

## Before/after trajectories

Harbor writes one ATIF `trajectory.json` per trial. Since the first pass and the
resume are two separate `harbor run`s, each produces its own — so every resumed
run yields a **before** and an **after** trajectory, collected into:

```
data/<run-id>/
  before/  trajectory.json  reward.txt  result.json   # pass 1 (e.g. weak model)
  after/   trajectory.json  reward.txt  result.json   # resumed pass (e.g. strong)
  summary.json                                         # reward before -> after
```

The **after** trajectory is the *continued* session, so it contains the before
prefix + the resumed model's additions; slice it at the resume boundary to isolate
what the second model added. `data/` is gitignored by default (a local output dir
like `artifacts/`); drop the `data/` line from the root `.gitignore` to version
them. Override the location with `HARBOR_RESUME_DATA`, and point the collector at a
non-default Harbor jobs dir with `HARBOR_JOBS_DIR`.

At the snapshot boundary the `codex` child has already exited, so the only live
process CRIU dumps is the container's idle keepalive — a **stable turn boundary**,
the same claim [`../README.md`](../README.md) makes. Functional state (the agent's
workspace + `$CODEX_HOME/sessions`) is carried by the committed image; the CRIU
dump demonstrates the native-handoff mechanism. Model **X** is applied by the
resume pass's `--model`.

When model **X** resumes, it inherits model A's full trajectory (instructions,
messages, every tool call + output) **and** the exact workspace A produced. It
does not inherit A's private/provider-internal reasoning tokens across a model
swap; the shared history is messages + tool I/O, not the model's private reasoning tokens.

## Quick start from scratch

From a bare **Linux** host (CRIU is Linux-only).

**1. Host prerequisites (once)** — Docker + CRIU, with experimental enabled so
`docker checkpoint` exists:

```bash
sudo apt-get install -y docker.io criu
echo '{ "experimental": true }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

criu check                 # must pass
docker checkpoint --help   # must exist (proves experimental is on)
```

**2. Install Harbor + this wrapper (once):**

```bash
uv tool install harbor          # or: pip install harbor
pip install -e ./harbor-resume  # exposes the `harbor-resume` command
```

You do **not** need the Codex CLI on the host — Harbor's Codex agent installs it
inside the task container, and the resume container already has it (it is in the
committed image).

**3. Configure the model endpoint (per shell):**

```bash
export OPENAI_BASE_URL=http://localhost:5000/v1   # any OpenAI-compatible endpoint
export OPENAI_API_KEY=sk-...                                      # read by Harbor's Codex agent
```

**4. Run a task (model A) → get a resume id:**

```bash
harbor datasets list                       # find a dataset/task
harbor-resume run --dataset terminal-bench@2.0 --task <task-id> --model <A>
# ... snapshots at the boundary, verifies, prints:  resume id: 5576ba3e168f
```

**5. Inspect:**

```bash
harbor-resume ls
harbor-resume status 5576ba3e168f
```

**6. Resume — same or different model, repeatably:**

```bash
harbor-resume 5576ba3e168f --model <B>   # restore, continue with B, re-snapshot, verify
harbor-resume 5576ba3e168f               # continue with the original model A
harbor-resume 5576ba3e168f --model <C>   # ...and again; each resume re-arms it
```

> First real run also validates the `# HOST-VALIDATE` seams in `env.py`/`agent.py`
> (CODEX_HOME path, `environment.exec` shape, compose container-id) against your
> installed Harbor version — expect to confirm/tweak one or two lines. Everything
> up to the Harbor boundary (CLI wiring, registry, model override) is pre-verified.

## Requirements

- An installed `harbor` (`uv tool install harbor` / `pip install harbor`) and the
  Codex CLI it manages.
- A Docker daemon started with `--experimental` and **CRIU** on `PATH` (same as
  this repo's `codex-cli` canary). The container + snapshot are retained between
  the two commands.
- OpenAI-SDK-compatible `OPENAI_BASE_URL` / `OPENAI_API_KEY` (see `.env.example`),
  consumed by Harbor's Codex agent.

## Status / validation

- Static checks (compile + import the Harbor-independent modules — `registry`,
  `_docker`, `cli`):
  ```bash
  python3 -m py_compile src/harbor_resume/*.py
  python3 -c "import sys; sys.path.insert(0,'src'); import harbor_resume.registry, harbor_resume._docker, harbor_resume.cli"
  ```
- `env.py` / `agent.py` subclass Harbor internals; lines marked `# HOST-VALIDATE`
  (module paths, `CODEX_HOME`, `environment.exec` shape, compose project naming)
  should be confirmed against the installed Harbor version on first host run.
- End-to-end (snapshot/restore correctness, CRIU dump) is **host-only** and not
  exercised in CI, exactly like the CRIU canary.

## Fallback

If a task's base image is un-checkpointable by CRIU, the fs commit alone still
resumes correctly (workspace + Codex session); the CRIU dump is skipped with a
warning and only the live-process demonstration is lost.
