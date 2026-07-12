ARG TASK_BASE_IMAGE
FROM ${TASK_BASE_IMAGE}

ARG CLAUDE_AGENT_SDK_VERSION=0.2.115

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates python3 python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install --no-cache-dir --break-system-packages \
       "claude-agent-sdk==${CLAUDE_AGENT_SDK_VERSION}"

COPY task_controller.py /opt/task_controller.py
COPY task-instruction.md /opt/task-instruction.md

ENTRYPOINT ["python3", "-u", "/opt/task_controller.py"]
