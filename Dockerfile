FROM python:3.12-slim

ARG CLAUDE_AGENT_SDK_VERSION=0.2.115

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "claude-agent-sdk==${CLAUDE_AGENT_SDK_VERSION}"

WORKDIR /workspace
COPY fixture/run.py /workspace/run.py
COPY src/controller.py /opt/native-resume-controller.py

ENTRYPOINT ["python3", "-u", "/opt/native-resume-controller.py"]
