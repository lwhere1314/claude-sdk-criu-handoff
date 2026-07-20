"""ControllerCodexAgent — Harbor's Codex agent plus a snapshot/resume boundary.

Pass it to ``harbor run`` via ``--agent harbor_resume.agent:ControllerCodexAgent``
with ``--agent-kwarg hr_run_id=<id>`` and, on a resume run,
``--agent-kwarg hr_resume=true``.

Behaviour:
- **first pass** (``hr_resume`` false): run the stock Codex agent to completion,
  then ask the environment to snapshot the container (fs commit + CRIU dump).
- **resume pass** (``hr_resume`` true): the environment has already restored the
  prior container, so ``$CODEX_HOME/sessions`` is present. Run
  ``codex exec resume --last --model <self.model_name>`` directly (bypassing the
  stock resume seeding, which would wipe and re-copy sessions), then re-snapshot
  so the run stays resumable.

At the snapshot boundary the ``codex`` child has exited; the only live process is
the container's idle keepalive — the stable boundary the repo's canary relies on.

Host-only (needs an installed ``harbor`` + Docker/CRIU). ``# HOST-VALIDATE`` marks
Harbor-internal call shapes to confirm against the installed version.
"""

from __future__ import annotations

import shlex

from harbor.agents.installed.codex import Codex  # HOST-VALIDATE: class name/path
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class ControllerCodexAgent(Codex):
    def __init__(self, *args, **kwargs) -> None:
        self._hr_run_id: str | None = kwargs.pop("hr_run_id", None)
        self._hr_resume: bool = _as_bool(kwargs.pop("hr_resume", False))
        super().__init__(*args, **kwargs)

    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        if self._hr_resume:
            await self._run_resume(instruction, environment)
        else:
            # Stock fresh pass to completion (installs codex, runs `codex exec`).
            await super().run(instruction, environment, context)  # type: ignore[misc]
        await self._snapshot(environment)

    async def _run_resume(self, instruction: str, environment: BaseEnvironment) -> None:
        if not self.model_name:
            raise ValueError("Model name is required")
        model = self.model_name.split("/")[-1]
        escaped = shlex.quote(instruction)
        # Mirror the stock `codex exec` invocation, but force `resume --last` and
        # do NOT re-seed sessions (they are already in the restored container).
        command = (
            "if [ -s ~/.nvm/nvm.sh ]; then . ~/.nvm/nvm.sh; fi; "
            "codex exec resume --last "
            "--dangerously-bypass-approvals-and-sandbox "
            "--skip-git-repo-check "
            f"--model {shlex.quote(model)} "
            "--json "
            f"-- {escaped}"
        )
        await environment.exec(command)  # HOST-VALIDATE: exec signature/kwargs

    async def _snapshot(self, environment: BaseEnvironment) -> None:
        if not self._hr_run_id:
            return
        snapshot = getattr(environment, "snapshot", None)
        if snapshot is None:
            raise RuntimeError(
                "ControllerCodexAgent requires --env harbor_resume.env:CriuDockerEnvironment"
            )
        await snapshot(self._hr_run_id)


def _as_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}
