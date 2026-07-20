#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-"$ROOT_DIR/.env"}
RUNTIME_DIR=${RUNTIME_DIR:-"/tmp/codex-cli-criu-handoff-${SUDO_UID:-$UID}"}
IMAGE=${CANARY_IMAGE:-"codex-cli-criu-handoff:local"}
CONTAINER=codex-cli-criu-handoff
CHECKPOINT=stable-turn-boundary
DOCKER_SOCKET="$RUNTIME_DIR/docker.sock"
DOCKER_HOST_VALUE="unix://$DOCKER_SOCKET"
CONTAINERD_SOCKET="$RUNTIME_DIR/containerd.sock"
CONTAINERD_PID=""
DOCKERD_PID=""

if (( EUID != 0 )); then
  exec sudo \
    --preserve-env=ENV_FILE,RUNTIME_DIR,CANARY_IMAGE,OPENAI_BASE_URL,OPENAI_API_KEY,CANARY_MODEL,CANARY_NONCE \
    "$0" "$@"
fi

for command in containerd dockerd docker criu runc; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 2
  }
done

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
elif [[ -z "${OPENAI_BASE_URL:-}" || -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Missing $ENV_FILE and exported OpenAI-compatible credentials." >&2
  echo "Copy .env.example to .env or export OPENAI_BASE_URL and OPENAI_API_KEY." >&2
  exit 2
fi

: "${OPENAI_BASE_URL:?Set OPENAI_BASE_URL in .env}"
: "${OPENAI_API_KEY:?Set OPENAI_API_KEY in .env}"
CANARY_MODEL=${CANARY_MODEL:-gpt-5.5}
CANARY_NONCE=${CANARY_NONCE:-"CRIU-$(date +%s)-$RANDOM"}

case "$OPENAI_BASE_URL$OPENAI_API_KEY$CANARY_MODEL" in
  *$'\n'*) echo "Configuration values must not contain newlines" >&2; exit 2 ;;
esac

stop_owned_process() {
  local pid=${1:-}
  [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || return 0
  local command_line
  command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  [[ "$command_line" == *"$RUNTIME_DIR"* ]] || {
    echo "Refusing to stop process $pid outside $RUNTIME_DIR" >&2
    return 1
  }
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  set +e
  stop_owned_process "$DOCKERD_PID"
  stop_owned_process "$CONTAINERD_PID"
  umount -l "$RUNTIME_DIR/docker-exec/netns/default" 2>/dev/null || true
  rm -rf "$RUNTIME_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rm -rf "$RUNTIME_DIR"
mkdir -p \
  "$RUNTIME_DIR/containerd-root" \
  "$RUNTIME_DIR/containerd-state" \
  "$RUNTIME_DIR/docker-data" \
  "$RUNTIME_DIR/docker-exec"
chmod 700 "$RUNTIME_DIR"
printf '{}\n' > "$RUNTIME_DIR/docker.json"

containerd \
  --address "$CONTAINERD_SOCKET" \
  --root "$RUNTIME_DIR/containerd-root" \
  --state "$RUNTIME_DIR/containerd-state" \
  >"$RUNTIME_DIR/containerd.log" 2>&1 &
CONTAINERD_PID=$!

for _ in $(seq 1 100); do
  [[ -S "$CONTAINERD_SOCKET" ]] && break
  kill -0 "$CONTAINERD_PID" 2>/dev/null || {
    tail -n 80 "$RUNTIME_DIR/containerd.log" >&2
    exit 3
  }
  sleep 0.1
done
[[ -S "$CONTAINERD_SOCKET" ]] || {
  echo "containerd socket did not become ready" >&2
  exit 3
}

dockerd \
  --config-file "$RUNTIME_DIR/docker.json" \
  --experimental \
  --host "$DOCKER_HOST_VALUE" \
  --containerd "$CONTAINERD_SOCKET" \
  --containerd-namespace codex-cli-criu-handoff \
  --containerd-plugins-namespace codex-cli-criu-handoff-plugins \
  --data-root "$RUNTIME_DIR/docker-data" \
  --exec-root "$RUNTIME_DIR/docker-exec" \
  --pidfile "$RUNTIME_DIR/dockerd.pid" \
  --bridge none \
  --iptables=false \
  --ip-forward=false \
  --ip-masq=false \
  --storage-driver vfs \
  >"$RUNTIME_DIR/dockerd.log" 2>&1 &
DOCKERD_PID=$!

for _ in $(seq 1 200); do
  docker -H "$DOCKER_HOST_VALUE" info >/dev/null 2>&1 && break
  kill -0 "$DOCKERD_PID" 2>/dev/null || {
    tail -n 100 "$RUNTIME_DIR/dockerd.log" >&2
    exit 3
  }
  sleep 0.1
done
docker -H "$DOCKER_HOST_VALUE" info >/dev/null 2>&1 || {
  echo "Isolated dockerd did not become ready" >&2
  exit 3
}

criu check >/dev/null
docker -H "$DOCKER_HOST_VALUE" build --network host -t "$IMAGE" "$ROOT_DIR"

ENV_SNAPSHOT="$RUNTIME_DIR/container.env"
PREVIOUS_UMASK=$(umask)
umask 077
{
  printf 'OPENAI_BASE_URL=%s\n' "$OPENAI_BASE_URL"
  printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY"
  printf 'CANARY_MODEL=%s\n' "$CANARY_MODEL"
  printf 'CANARY_NONCE=%s\n' "$CANARY_NONCE"
  printf 'CODEX_HOME=/workspace/.codex\n'
  printf 'IS_SANDBOX=1\n'
} > "$ENV_SNAPSHOT"
umask "$PREVIOUS_UMASK"

docker -H "$DOCKER_HOST_VALUE" run -d \
  --name "$CONTAINER" \
  --network host \
  --security-opt seccomp=unconfined \
  --env-file "$ENV_SNAPSHOT" \
  "$IMAGE" >/dev/null

wait_for_marker() {
  local marker=$1
  local attempts=$2
  for _ in $(seq 1 "$attempts"); do
    docker -H "$DOCKER_HOST_VALUE" logs "$CONTAINER" 2>&1 | grep -q "$marker" && return 0
    local state
    state=$(docker -H "$DOCKER_HOST_VALUE" inspect -f '{{.State.Status}}' "$CONTAINER")
    [[ "$state" == running ]] || {
      docker -H "$DOCKER_HOST_VALUE" logs "$CONTAINER" >&2
      return 1
    }
    sleep 1
  done
  return 1
}

echo "Waiting for the first native Codex turn..."
wait_for_marker CODEX_CANARY_READY 900 || {
  echo "Timed out before the stable checkpoint boundary" >&2
  exit 4
}

BEFORE_PID=$(docker -H "$DOCKER_HOST_VALUE" inspect -f '{{.State.Pid}}' "$CONTAINER")
docker -H "$DOCKER_HOST_VALUE" checkpoint create "$CONTAINER" "$CHECKPOINT" >/dev/null
CHECKPOINT_STATE=$(docker -H "$DOCKER_HOST_VALUE" inspect -f '{{.State.Status}}' "$CONTAINER")
[[ "$CHECKPOINT_STATE" == exited ]] || {
  echo "Container did not stop after checkpoint: $CHECKPOINT_STATE" >&2
  exit 5
}

docker -H "$DOCKER_HOST_VALUE" start --checkpoint "$CHECKPOINT" "$CONTAINER" >/dev/null
AFTER_PID=$(docker -H "$DOCKER_HOST_VALUE" inspect -f '{{.State.Pid}}' "$CONTAINER")
docker -H "$DOCKER_HOST_VALUE" exec "$CONTAINER" touch /workspace/native-resume.continue

echo "Waiting for the resumed native Codex turn..."
wait_for_marker CODEX_CANARY_COMPLETE 900 || {
  echo "Timed out during the resumed turn" >&2
  exit 6
}
docker -H "$DOCKER_HOST_VALUE" wait "$CONTAINER" >/dev/null

# Validate inside the isolated runtime dir (removed on exit); nothing is written
# into the repository.
VALIDATE_DIR="$RUNTIME_DIR/validate"
mkdir -p "$VALIDATE_DIR"
docker -H "$DOCKER_HOST_VALUE" logs "$CONTAINER" > "$VALIDATE_DIR/container.log" 2>&1
docker -H "$DOCKER_HOST_VALUE" cp \
  "$CONTAINER:/workspace/native-resume-evidence.txt" \
  "$VALIDATE_DIR/evidence.txt"

grep -q 'same_session=True evidence_ok=True' "$VALIDATE_DIR/container.log"
grep -Fxq "CODEX_SESSION_RESUMED $CANARY_NONCE" "$VALIDATE_DIR/evidence.txt"

SESSION_ID=$(sed -n \
  's/.*CODEX_CANARY_COMPLETE original_session=\([^ ]*\).*/\1/p' \
  "$VALIDATE_DIR/container.log" | tail -n 1)

echo "PASS: native Codex session resumed after CRIU restore"
echo "  Model:                     $CANARY_MODEL"
echo "  Native session ID:         $SESSION_ID"
echo "  Host PID before checkpoint: $BEFORE_PID"
echo "  Host PID after restore:     $AFTER_PID"
echo "  Checkpoint state:          $CHECKPOINT_STATE"
echo "  Same native session:       true"
echo "  Evidence validated:        true"
