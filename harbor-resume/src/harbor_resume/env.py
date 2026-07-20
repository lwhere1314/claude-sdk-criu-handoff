"""CriuDockerEnvironment — a Harbor Docker environment that snapshots the trial
container at a stable boundary and restores it on a later resume run.

Pass it to ``harbor run`` via ``--env harbor_resume.env:CriuDockerEnvironment``.
It subclasses Harbor's stock compose-based ``DockerEnvironment`` and only adds:

- ``keep_containers=True`` forced, so the container + snapshots survive between
  the two separate ``harbor`` invocations.
- ``snapshot(run_id)`` — a *paired* snapshot at the boundary: ``docker commit``
  (filesystem: the agent's workspace + ``$CODEX_HOME/sessions``) plus a
  best-effort ``docker checkpoint`` CRIU dump of the idle keepalive process.
  Triggered by ``ControllerCodexAgent`` after the pass completes.
- ``start()`` — on a resume run, restore the committed filesystem into the fresh
  container so ``codex exec resume --last`` continues in the identical workspace.

The functional resume medium is the committed image; the CRIU dump is the
demonstrative native-handoff artifact (the live process at the boundary is only
the idle keepalive — the ``codex`` child has already exited), exactly the claim
the repo README already makes.

Host-only: requires Docker (``--experimental`` for CRIU) + CRIU on PATH, and an
installed ``harbor``. Lines marked ``# HOST-VALIDATE`` touch Harbor internals whose
exact spelling can shift across Harbor versions; confirm them against the
installed version on first run.
"""

from __future__ import annotations

import os
from pathlib import Path

from harbor.environments.docker.docker import (  # HOST-VALIDATE: module path
    DockerEnvironment,
    _sanitize_docker_compose_project_name,
)

from harbor_resume import _docker, registry


class CriuDockerEnvironment(DockerEnvironment):
    #: where CRIU dumps are written (must persist between the two harbor commands)
    _CRIU_ROOT = Path(os.environ.get("HARBOR_RESUME_HOME", str(Path.home() / ".harbor-resume"))) / "criu"

    def __init__(self, *args, **kwargs) -> None:
        # Read our own kwargs (passed via `--environment-kwarg key=value`), then
        # force container retention so snapshots are never torn down.
        self._hr_run_id: str | None = kwargs.pop("hr_run_id", None)
        self._hr_restore: bool = _as_bool(kwargs.pop("hr_restore", False))
        kwargs["keep_containers"] = True
        super().__init__(*args, **kwargs)

    # -- snapshot -----------------------------------------------------------
    async def snapshot(self, run_id: str) -> registry.SnapshotRecord:
        """Paired fs-commit + CRIU dump of the current container, keyed by run id."""
        project = _sanitize_docker_compose_project_name(self.environment_name)  # HOST-VALIDATE
        cid = _docker.compose_main_container_id(project)

        image = f"harbor-resume/{run_id}:latest"
        _docker.commit(cid, image)

        criu_dir = self._CRIU_ROOT / run_id
        criu_name: str | None = None
        if _docker.checkpoint_available():
            try:
                _docker.checkpoint(cid, "boundary", criu_dir)
                criu_name = "boundary"
            except _docker.DockerError as exc:  # CRIU may reject some base images
                self.logger.warning(f"CRIU checkpoint skipped (fs snapshot kept): {exc}")

        record = registry.load(run_id) if registry.exists(run_id) else registry.SnapshotRecord(
            run_id=run_id, fs_image=image
        )
        record.fs_image = image
        record.criu_dir = str(criu_dir) if criu_name else None
        record.criu_name = criu_name
        record.passes = (record.passes or 0) + 1
        registry.save(record)
        self.logger.info(f"harbor-resume snapshot for {run_id}: image={image} criu={criu_name}")
        return record

    # -- restore ------------------------------------------------------------
    async def start(self, force_build: bool) -> None:
        await super().start(force_build)
        if not (self._hr_restore and self._hr_run_id and registry.exists(self._hr_run_id)):
            return
        record = registry.load(self._hr_run_id)
        if not _docker.image_exists(record.fs_image):
            self.logger.warning(f"No snapshot image {record.fs_image}; starting clean")
            return
        self._restore_state_from_image(record.fs_image)

    def _restore_state_from_image(self, image: str) -> None:
        """Copy the agent's persisted state out of the snapshot image into the
        freshly started container, so `codex exec resume --last` continues in the
        exact workspace + session it left behind.

        Restores the workspace and CODEX_HOME. Paths are read from the container
        env so this does not hard-code Harbor's layout.
        """
        project = _sanitize_docker_compose_project_name(self.environment_name)  # HOST-VALIDATE
        cid = _docker.compose_main_container_id(project)
        codex_home = os.environ.get("CODEX_HOME", "/root/.codex")  # HOST-VALIDATE: agent CODEX_HOME
        for path in ("/workspace", codex_home):
            try:
                _copy_dir_from_image(image, path, cid)
            except _docker.DockerError as exc:
                self.logger.warning(f"restore of {path} skipped: {exc}")

    async def stop(self, delete: bool) -> None:
        # Never delete: the committed image / CRIU dump must outlive this command.
        await super().stop(delete=False)


def _copy_dir_from_image(image: str, path: str, dest_container: str) -> None:
    """`docker cp` a directory out of an image (via a temp container) into a
    running container."""
    tmp = _docker._run(["create", image, "true"])
    try:
        # stream: `docker cp tmp:<path>/.  ->  dest:<path>` via the host is awkward
        # for arbitrary paths, so go through a tar pipe.
        import subprocess

        src = subprocess.Popen(["docker", "cp", f"{tmp}:{path}/.", "-"], stdout=subprocess.PIPE)
        dst = subprocess.run(
            ["docker", "cp", "-", f"{dest_container}:{path}"],
            stdin=src.stdout,
            stderr=subprocess.PIPE,
            text=True,
        )
        if src.stdout:
            src.stdout.close()
        src.wait()
        if dst.returncode != 0:
            raise _docker.DockerError(f"cp {path}: {dst.stderr.strip()}")
    finally:
        try:
            _docker._run(["rm", "-f", tmp])
        except _docker.DockerError:
            pass


def _as_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}
