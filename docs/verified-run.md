# Verified run: Alibaba Cloud Linux

The standalone runner was executed end to end on 2026-07-12 after being copied
to a clean temporary directory on the host. It did not reuse an earlier image,
container, checkpoint, or session.

- Result: **PASS**
- Model: `kimi-k2.6`
- Claude Agent SDK: `0.2.115`
- Native session ID before and after restore:
  `cafdb65f-875a-4cd2-b6e9-fd8b4f717694`
- Host PID before checkpoint: `588700`
- Host PID after restore: `589318`
- State immediately after checkpoint: `exited`
- Same native session: `true`
- Tool-written evidence validated: `true`
- Isolated runtime remaining after exit: `0` processes and no data directory
- Main Docker daemon after exit: `active`

The run used Seed Coding Plan's Anthropic-compatible endpoint. No API key,
OAuth credential, checkpoint image, or container inspection output is retained
in this repository.
