"""harbor-resume: CRIU-snapshot & resume a Harbor run by run-id.

Public surface:
- ``harbor_resume.env.CriuDockerEnvironment`` — pass as ``--env`` to ``harbor run``.
- ``harbor_resume.agent.ControllerCodexAgent`` — pass as ``--agent``.
- ``harbor_resume.cli.main`` — the ``harbor-resume`` command.
"""

__all__ = ["registry"]
