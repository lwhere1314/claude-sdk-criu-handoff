FROM python:3.12-slim

# Codex is installed from the official standalone installer (a musl static
# binary that runs on glibc), which is more reliable than the npm package.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/root/.local/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL https://chatgpt.com/codex/install.sh | sh \
    && apt-get purge -y curl && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && codex --version

WORKDIR /workspace
COPY src/controller.py /opt/codex-resume-controller.py

ENTRYPOINT ["python3", "-u", "/opt/codex-resume-controller.py"]
