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
