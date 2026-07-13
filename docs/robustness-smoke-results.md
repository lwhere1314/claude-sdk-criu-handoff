# Terminal-Bench 2.1 offline restore smoke results

Date: 2026-07-13  
Host: `aliyun-linux-admin`  
Harness: Claude Agent SDK 0.2.115, isolated Docker daemon, Docker/CRIU stable
turn boundary

These are mechanism and compatibility smoke tests with one replicate per cell.
They are not estimates of model capability or statistically significant
robustness rates.

## Completed CRIU cells

| Task | Coding Plan model | CRIU restore | Native handoff | Verifier |
|---|---|---:|---:|---:|
| cancel-async-tasks | kimi-k2.6 | pass | pass | 5/6, reward 0 |
| cancel-async-tasks | kimi-k2.7-code | pass | pass | 6/6, reward 1 |
| cancel-async-tasks | doubao-seed-2.0-code | pass | pass | 5/6, reward 0 |
| cancel-async-tasks | doubao-seed-2.0-pro | pass | pass | 5/6, reward 0 |
| cancel-async-tasks | deepseek-v4-pro | pass | pass | 5/6, reward 0 |
| query-optimize | doubao-seed-2.0-code | pass | pass | 5/6, reward 0 |
| query-optimize | doubao-seed-2.0-pro | pass | pass | 6/6, reward 1 |
| train-fasttext | doubao-seed-2.0-pro | pass | pass | not evaluated; phase 2 capped at 1200 s |
| train-fasttext | kimi-k2.7-code | pass | pass | not evaluated; phase 2 capped at 900 s |

For every completed CRIU cell above, checkpoint creation and restore succeeded,
the in-memory controller epoch was unchanged, the native session ID matched,
the model wrote the exact continuity nonce, and the checkpoint boundary had
zero child processes, zero established TCP sockets owned by PID 1, and zero
pidfds.

The four failing `cancel-async-tasks` verifier runs all passed five tests and
failed the same queued-task cancellation cleanup case. This is a model/task
failure after a successful handoff, not a restore failure. The Seed Code
`query-optimize` run failed only its performance test; Seed Pro passed 6/6.

Both FastText results are censored rather than counted as task failures: their
restored sessions and semantic handoffs succeeded, but no `model.bin` was
produced before the 1200- and 900-second experiment caps. The task's official
agent timeout is 3600 seconds.

## Fixed Kimi failure takeover

These campaigns are reported separately from the aggregate smoke counts below.
They reuse one real Kimi 2.6 `cancel-async-tasks` failure rather than sampling a
new source trajectory for every target:

- source verifier: 5/6, reward 0; only
  `test_tasks_cancel_above_max_concurrent` failed;
- source `run.py` SHA-256:
  `52cb984a8e37f564dad5f1333429b68c61f7ac855a89ea3c760d3593c68e3461`;
- source native JSONL: 69 lines, 137296 bytes, SHA-256
  `4762c69dca6a127c6c4e48077ac5c1c5b780c8f11f6242f39cc1a3fbb3612135`;
- fixed input-directory SHA-256:
  `9e27829446850bb7155b1af83e9824a6bdc84090616c7e7ec2f164d647673d6c`.

| Target | Treatment | Native continuity | Workspace hash restored | Target changed `run.py` | Verifier |
|---|---|---:|---:|---:|---:|
| doubao-seed-2.0-pro | CRIU stable | pass | pass | no | 5/6, reward 0 |
| deepseek-v4-pro | CRIU stable | pass | pass | yes | 6/6, reward 1 |
| deepseek-v4-pro | cold native control | pass | pass | yes | 6/6, reward 1 |

Both CRIU rows restored PID 1 with a changed host PID and an unchanged
controller epoch. Both also resumed the exact Kimi session ID, recovered the
nonce from native history, and began from the hashes above. Seed completed the
handoff but left the failing workspace unchanged. DeepSeek changed `run.py` and
passed all six tests; its CRIU run took about 14 minutes because it generated a
hanging diagnostic before recovering without human intervention.

The original Kimi controller's deleted CRIU pages were not available. The
runner therefore loaded the fixed workspace and native session into a fresh
waiting controller, recorded the original epoch as provenance, checkpointed
that waiting controller, and restored it before target resume. This proves
CRIU restoration of the rehydrated controller plus native cross-model resume;
it does not claim resurrection of the original Kimi process memory.

Docker 26 rejected cross-container clone restore with `custom checkpointdir is
not supported`. The controlled CRIU comparison consequently used one runner
invocation per target, both referencing the same fixed input hash. The cold
DeepSeek route is retained as a control and is not mislabeled as CRIU.

## Robustness controls

The Kimi 2.7 control campaign produced:

| Treatment | PID 1 / epoch behavior | Native handoff | Verifier |
|---|---|---:|---:|
| uninterrupted | one controller epoch | pass | 5/6, reward 0 |
| native_resume_cold | new PID 1 and new epoch | pass | 5/6, reward 0 |
| criu_stable, 30 s resume delay | restored original epoch | pass | 6/6, reward 1 |

The cold result demonstrates image/filesystem-only offline recovery through a
new controller, while the CRIU results additionally demonstrate preservation
of the local controller's process memory and execution point. The different
task rewards are not evidence that CRIU improves model quality: each cell has
only one sample, and another normal Kimi 2.7 CRIU run also happened to pass.

Across all retained artifacts, 10/10 CRIU restores and 12/12 native handoffs
succeeded. Ten runs reached a verifier and three passed it; the two FastText
runs were excluded from that denominator. The task rate mixes tasks and models
and is reported only as harness coverage, not as a model benchmark score.

The campaign also exercises:

- uninterrupted two-turn native resume;
- cold native resume with a new PID 1 controller;
- CRIU restore followed by a 30-second delayed resume signal;
- structured phase timeout/failure recording so one bad model does not abort a
  multi-model campaign;
- private-test injection only after the agent finishes;
- artifact secret scanning and isolated-runtime removal.

## Harness failures found during the smoke test

1. The server's privileged shell selected Python 3.6 for result aggregation.
   The runner now probes for Python 3.10 or newer before privilege elevation.
2. Anthropic-compatible gateways can emit one SDK event per thinking token.
   Those non-semantic events are now suppressed from retained logs.
3. A phase timeout previously aborted the rest of a model matrix. The runner
   now writes a failed `run.json`, removes that run, and continues.
4. Interrupted screen sessions can deliver `SIGHUP`. The cleanup trap now
   handles HUP in addition to INT and TERM.

Use `scripts/aggregate-results.py` to compute restore, native-handoff, and task
success rates separately. A verifier-censored run is excluded from the task
pass-rate denominator.
