#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-"$ROOT_DIR/.env"}
TASK_DIR=""
SOURCE_MODEL="kimi-k2.6"
TARGET_MODELS="kimi-k2.7-code"
SOURCE_STRATEGY="write_run_py"
SOURCE_CHECKPOINT_INPUT=""
AGENT_TIMEOUT_OVERRIDE=0
ARTIFACT_ROOT=${ARTIFACT_ROOT:-"$ROOT_DIR/artifacts/fixed-takeover"}
CAMPAIGN_ID=${CAMPAIGN_ID:-"takeover-$(date -u +%Y%m%dT%H%M%SZ)"}
STORAGE_DRIVER=${STORAGE_DRIVER:-overlay2}
RUNTIME_DIR=""
CONTAINERD_PID=""
DOCKERD_PID=""
ADAPTER_IMAGE=""
SOURCE_IMAGE=""
MAIN_IMAGE_CREATED=0
MAIN_DOCKER_PID_BEFORE=$(systemctl show -p MainPID --value docker 2>/dev/null || echo unknown)
OWNER_UID=${SUDO_UID:-$UID}
OWNER_GID=${SUDO_GID:-$(id -g)}

if [[ -z "${HOST_PYTHON:-}" ]]; then
  for candidate in /usr/local/bin/python3 "$(command -v python3)"; do
    if [[ -x "$candidate" ]] \
      && "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' \
        >/dev/null 2>&1; then
      HOST_PYTHON=$candidate
      break
    fi
  done
fi
HOST_PYTHON=${HOST_PYTHON:-$(command -v python3)}

usage() {
  cat <<'EOF'
Usage: run-fixed-takeover.sh --task-dir PATH [options]

Options:
  --source-model MODEL       Source model that creates one fixed failure
  --target-models CSV        Target models restored from that source boundary
  --source-strategy NAME     write_run_py or attempt
  --source-checkpoint-input PATH
                             Rehydrate a fixed workspace/native session instead
                             of sampling the source model again
  --agent-timeout-sec N      Override task timeout for each model phase
  --artifact-root PATH       Credential-free result root
  --campaign-id ID           Stable campaign identifier
EOF
}

while (($#)); do
  case "$1" in
    --task-dir) TASK_DIR=$2; shift 2 ;;
    --source-model) SOURCE_MODEL=$2; shift 2 ;;
    --target-models) TARGET_MODELS=$2; shift 2 ;;
    --source-strategy) SOURCE_STRATEGY=$2; shift 2 ;;
    --source-checkpoint-input) SOURCE_CHECKPOINT_INPUT=$2; shift 2 ;;
    --agent-timeout-sec) AGENT_TIMEOUT_OVERRIDE=$2; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT=$2; shift 2 ;;
    --campaign-id) CAMPAIGN_ID=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TASK_DIR" && -f "$TASK_DIR/task.toml" && -f "$TASK_DIR/instruction.md" ]] || {
  echo "--task-dir must point to a Terminal-Bench task" >&2
  exit 2
}
TASK_DIR=$(cd "$TASK_DIR" && pwd)
TASK_ID=$(basename "$TASK_DIR")
RUNTIME_DIR=${RUNTIME_DIR_OVERRIDE:-"/tmp/claude-sdk-takeover-${TASK_ID}-${SUDO_UID:-$UID}"}

if ((EUID != 0)); then
  exec sudo \
    --preserve-env=ENV_FILE,ARTIFACT_ROOT,CAMPAIGN_ID,RUNTIME_DIR_OVERRIDE,STORAGE_DRIVER,HOST_PYTHON,CODING_PLAN_BASE_URL,CODING_PLAN_API_KEY \
    "$0" --task-dir "$TASK_DIR" --source-model "$SOURCE_MODEL" \
    --target-models "$TARGET_MODELS" --source-strategy "$SOURCE_STRATEGY" \
    ${SOURCE_CHECKPOINT_INPUT:+--source-checkpoint-input "$SOURCE_CHECKPOINT_INPUT"} \
    --agent-timeout-sec "$AGENT_TIMEOUT_OVERRIDE" \
    --artifact-root "$ARTIFACT_ROOT" --campaign-id "$CAMPAIGN_ID"
fi

for command in containerd dockerd docker criu runc timeout sha256sum findmnt; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 2; }
done
[[ -x "$HOST_PYTHON" ]] || { echo "HOST_PYTHON is not executable" >&2; exit 2; }

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
elif [[ -z "${CODING_PLAN_BASE_URL:-}" || -z "${CODING_PLAN_API_KEY:-}" ]]; then
  echo "Provide .env or exported Coding Plan credentials" >&2
  exit 2
fi
: "${CODING_PLAN_BASE_URL:?}"
: "${CODING_PLAN_API_KEY:?}"
[[ "$SOURCE_STRATEGY" == write_run_py || "$SOURCE_STRATEGY" == attempt ]] || {
  echo "--source-strategy must be write_run_py or attempt" >&2
  exit 2
}
if [[ -n "$SOURCE_CHECKPOINT_INPUT" ]]; then
  SOURCE_CHECKPOINT_INPUT=$(cd "$SOURCE_CHECKPOINT_INPUT" && pwd)
  for required in run.py native-manifest.json native-session; do
    [[ -e "$SOURCE_CHECKPOINT_INPUT/$required" ]] || {
      echo "Fixed source checkpoint is missing $required" >&2
      exit 2
    }
  done
fi

BASE_IMAGE=$(sed -n 's/^[[:space:]]*docker_image[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TASK_DIR/task.toml" | head -n 1)
CPU_LIMIT=$(sed -n 's/^[[:space:]]*cpus[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$TASK_DIR/task.toml" | head -n 1)
MEMORY_MB=$(sed -n 's/^[[:space:]]*memory_mb[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$TASK_DIR/task.toml" | head -n 1)
AGENT_TIMEOUT=$(sed -n '/^\[agent\]/,/^\[/s/^[[:space:]]*timeout_sec[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$TASK_DIR/task.toml" | head -n 1)
VERIFIER_TIMEOUT=$(sed -n '/^\[verifier\]/,/^\[/s/^[[:space:]]*timeout_sec[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$TASK_DIR/task.toml" | head -n 1)
CPU_LIMIT=${CPU_LIMIT:-1}
MEMORY_MB=${MEMORY_MB:-2048}
AGENT_TIMEOUT=${AGENT_TIMEOUT%.*}
VERIFIER_TIMEOUT=${VERIFIER_TIMEOUT%.*}
AGENT_TIMEOUT=${AGENT_TIMEOUT:-1800}
VERIFIER_TIMEOUT=${VERIFIER_TIMEOUT:-1800}
((AGENT_TIMEOUT_OVERRIDE > 0)) && AGENT_TIMEOUT=$AGENT_TIMEOUT_OVERRIDE
TASK_WORKDIR=$(docker image inspect -f '{{.Config.WorkingDir}}' "$BASE_IMAGE" 2>/dev/null || true)

stop_owned_process() {
  local pid=${1:-}
  [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || return 0
  local command_line
  command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  [[ "$command_line" == *"$RUNTIME_DIR"* ]] || return 1
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  set +e
  if [[ -n "${ISOLATED_HOST:-}" ]]; then
    docker -H "$ISOLATED_HOST" ps -aq 2>/dev/null | xargs -r docker -H "$ISOLATED_HOST" rm -f >/dev/null 2>&1
    [[ -n "$SOURCE_IMAGE" ]] && docker -H "$ISOLATED_HOST" image rm "$SOURCE_IMAGE" >/dev/null 2>&1
  fi
  if [[ -n "$ADAPTER_IMAGE" && "$MAIN_IMAGE_CREATED" == 1 ]]; then
    docker image rm "$ADAPTER_IMAGE" >/dev/null 2>&1 || true
  fi
  stop_owned_process "$DOCKERD_PID"
  stop_owned_process "$CONTAINERD_PID"
  while read -r shim_pid; do
    [[ -n "$shim_pid" ]] && kill -TERM "$shim_pid" 2>/dev/null || true
  done < <(pgrep -f "containerd-shim.*$RUNTIME_DIR/containerd.sock" || true)
  while read -r mountpoint; do
    [[ -n "$mountpoint" ]] && umount -l "$mountpoint" 2>/dev/null || true
  done < <(findmnt -rn -o TARGET | awk -v root="$RUNTIME_DIR" 'index($0, root) == 1' | sort -r)
  rm -rf "$RUNTIME_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || {
  echo "Base image $BASE_IMAGE is absent; building task environment"
  docker build --network host -t "$BASE_IMAGE" "$TASK_DIR/environment"
}
TASK_WORKDIR=${TASK_WORKDIR:-$(docker image inspect -f '{{.Config.WorkingDir}}' "$BASE_IMAGE")}
TASK_WORKDIR=${TASK_WORKDIR:-/app}

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR/adapter" "$RUNTIME_DIR/containerd-root" \
  "$RUNTIME_DIR/containerd-state" "$RUNTIME_DIR/docker-data" \
  "$RUNTIME_DIR/docker-exec" "$RUNTIME_DIR/fixed-checkpoint"
chmod 700 "$RUNTIME_DIR"
cp "$ROOT_DIR/docker/task.Dockerfile" "$RUNTIME_DIR/adapter/Dockerfile"
cp "$ROOT_DIR/src/task_controller.py" "$RUNTIME_DIR/adapter/task_controller.py"
cp "$TASK_DIR/instruction.md" "$RUNTIME_DIR/adapter/task-instruction.md"

ADAPTER_IMAGE="claude-sdk-criu-handoff:${TASK_ID}-${CAMPAIGN_ID}"
docker build --network host --build-arg TASK_BASE_IMAGE="$BASE_IMAGE" \
  -t "$ADAPTER_IMAGE" "$RUNTIME_DIR/adapter"
MAIN_IMAGE_CREATED=1

printf '{}\n' > "$RUNTIME_DIR/docker.json"
CONTAINERD_SOCKET="$RUNTIME_DIR/containerd.sock"
DOCKER_SOCKET="$RUNTIME_DIR/docker.sock"
ISOLATED_HOST="unix://$DOCKER_SOCKET"
containerd --address "$CONTAINERD_SOCKET" --root "$RUNTIME_DIR/containerd-root" \
  --state "$RUNTIME_DIR/containerd-state" >"$RUNTIME_DIR/containerd.log" 2>&1 &
CONTAINERD_PID=$!
for _ in $(seq 1 100); do
  [[ -S "$CONTAINERD_SOCKET" ]] && break
  kill -0 "$CONTAINERD_PID" 2>/dev/null || { tail -80 "$RUNTIME_DIR/containerd.log"; exit 3; }
  sleep 0.1
done

dockerd --config-file "$RUNTIME_DIR/docker.json" --experimental --host "$ISOLATED_HOST" \
  --containerd "$CONTAINERD_SOCKET" --containerd-namespace "takeover-$TASK_ID" \
  --containerd-plugins-namespace "takeover-$TASK_ID-plugins" \
  --data-root "$RUNTIME_DIR/docker-data" --exec-root "$RUNTIME_DIR/docker-exec" \
  --pidfile "$RUNTIME_DIR/dockerd.pid" --bridge none --iptables=false \
  --ip-forward=false --ip-masq=false --storage-driver "$STORAGE_DRIVER" \
  >"$RUNTIME_DIR/dockerd.log" 2>&1 &
DOCKERD_PID=$!
for _ in $(seq 1 200); do
  docker -H "$ISOLATED_HOST" info >/dev/null 2>&1 && break
  kill -0 "$DOCKERD_PID" 2>/dev/null || { tail -100 "$RUNTIME_DIR/dockerd.log"; exit 3; }
  sleep 0.1
done
docker -H "$ISOLATED_HOST" info >/dev/null
criu check >/dev/null
docker save "$ADAPTER_IMAGE" | docker -H "$ISOLATED_HOST" load >/dev/null
docker image rm "$ADAPTER_IMAGE" >/dev/null
MAIN_IMAGE_CREATED=0

GIT_SHA=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
DATASET_SHA=$(find "$TASK_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
DOCKER_VERSION=$(docker -H "$ISOLATED_HOST" version --format '{{.Server.Version}}')
RUNC_VERSION=$(runc --version | awk 'NR==1{print $3}')
CRIU_VERSION=$(criu --version | awk 'NR==1{print $2}')
KERNEL_VERSION=$(uname -r)
CAMPAIGN_DIR="$ARTIFACT_ROOT/$CAMPAIGN_ID"
SOURCE_DIR="$CAMPAIGN_DIR/source-checkpoint"
mkdir -p "$SOURCE_DIR"

wait_for_log() {
  local container=$1 marker=$2 timeout_sec=$3
  local deadline=$((SECONDS + timeout_sec))
  while ((SECONDS < deadline)); do
    docker -H "$ISOLATED_HOST" logs "$container" 2>&1 | grep -q "$marker" && return 0
    local state
    state=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)
    [[ "$state" == running ]] || return 1
    sleep 1
  done
  return 1
}

make_env_file() {
  local path=$1 source=$2 target=$3 phase=$4 nonce=$5 strategy=$6
  local old_umask
  old_umask=$(umask)
  umask 077
  {
    printf 'ANTHROPIC_BASE_URL=%s\n' "$CODING_PLAN_BASE_URL"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$CODING_PLAN_API_KEY"
    printf 'SOURCE_MODEL=%s\n' "$source"
    printf 'TARGET_MODEL=%s\n' "$target"
    printf 'SOURCE_STRATEGY=%s\n' "$strategy"
    printf 'HANDOFF_NONCE=%s\n' "$nonce"
    printf 'HANDOFF_PHASE=%s\n' "$phase"
    printf 'HANDOFF_MARKER_DIR=/tmp/claude-handoff\n'
    printf 'TASK_WORKDIR=%s\n' "$TASK_WORKDIR"
    printf 'TASK_INSTRUCTION_PATH=/opt/task-instruction.md\n'
    printf 'CLAUDE_CONFIG_DIR=%s/.claude\n' "$TASK_WORKDIR"
    printf 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1\n'
    printf 'IS_SANDBOX=1\n'
    printf 'WAIT_FOR_VERIFIER=1\n'
    printf 'SOURCE_MAX_TURNS=20\n'
    printf 'SOURCE_MAX_THINKING_TOKENS=8192\n'
    printf 'PHASE2_MAX_TURNS=20\n'
    printf 'PHASE2_MAX_THINKING_TOKENS=8192\n'
  } > "$path"
  umask "$old_umask"
}

run_verifier() {
  local container=$1 artifact_dir=$2
  docker -H "$ISOLATED_HOST" exec "$container" mkdir -p /tests /logs/verifier
  docker -H "$ISOLATED_HOST" cp "$TASK_DIR/tests/." "$container:/tests/"
  local started=$SECONDS
  set +e
  timeout "${VERIFIER_TIMEOUT}s" docker -H "$ISOLATED_HOST" exec -w "$TASK_WORKDIR" \
    "$container" bash /tests/test.sh >"$artifact_dir/verifier.log" 2>&1
  local verifier_exit=$?
  set -e
  echo "$verifier_exit" > "$artifact_dir/verifier-exit-code.txt"
  echo $(((SECONDS - started) * 1000)) > "$artifact_dir/verifier-duration-ms.txt"
  docker -H "$ISOLATED_HOST" cp "$container:/logs/verifier/reward.txt" \
    "$artifact_dir/reward.txt" 2>/dev/null || printf '0\n' > "$artifact_dir/reward.txt"
  docker -H "$ISOLATED_HOST" cp "$container:/logs/verifier/ctrf.json" \
    "$artifact_dir/ctrf.json" 2>/dev/null || true
}

safe_name() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '-'
}

SOURCE_SAFE=$(safe_name "$SOURCE_MODEL")
SOURCE_CONTAINER="takeover-source-$SOURCE_SAFE"
SOURCE_ENV="$RUNTIME_DIR/source.env"
NONCE="${CAMPAIGN_ID}-${TASK_ID}-${SOURCE_SAFE}-$RANDOM"
SOURCE_PHASE=both
if [[ -n "$SOURCE_CHECKPOINT_INPUT" ]]; then
  SOURCE_PHASE=hold
  SOURCE_STRATEGY=$("$HOST_PYTHON" -c \
    'import json,sys; print(json.load(open(sys.argv[1])).get("source_strategy") or "attempt")' \
    "$SOURCE_CHECKPOINT_INPUT/native-manifest.json")
  NONCE=$("$HOST_PYTHON" -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["nonce"])' \
    "$SOURCE_CHECKPOINT_INPUT/native-manifest.json")
fi
make_env_file "$SOURCE_ENV" "$SOURCE_MODEL" "$SOURCE_MODEL" "$SOURCE_PHASE" "$NONCE" "$SOURCE_STRATEGY"

docker -H "$ISOLATED_HOST" run --rm --entrypoint /bin/sh "$ADAPTER_IMAGE" \
  -c 'test ! -e "$1" && test ! -e /tests' sh "$TASK_WORKDIR/run.py"
docker -H "$ISOLATED_HOST" create --name "$SOURCE_CONTAINER" --network host \
  --security-opt seccomp=unconfined --cpus "$CPU_LIMIT" --memory "${MEMORY_MB}m" \
  --env-file "$SOURCE_ENV" "$ADAPTER_IMAGE" >/dev/null
if [[ -n "$SOURCE_CHECKPOINT_INPUT" ]]; then
  IMPORT_MARKERS="$RUNTIME_DIR/import-markers"
  mkdir -p "$IMPORT_MARKERS"
  cp "$SOURCE_CHECKPOINT_INPUT/native-manifest.json" "$IMPORT_MARKERS/manifest.json"
  if [[ -f "$SOURCE_CHECKPOINT_INPUT/source-cutpoint.json" ]]; then
    cp "$SOURCE_CHECKPOINT_INPUT/source-cutpoint.json" "$IMPORT_MARKERS/source-cutpoint.json"
  fi
  docker -H "$ISOLATED_HOST" cp "$IMPORT_MARKERS" \
    "$SOURCE_CONTAINER:/tmp/claude-handoff"
  docker -H "$ISOLATED_HOST" cp "$SOURCE_CHECKPOINT_INPUT/run.py" \
    "$SOURCE_CONTAINER:$TASK_WORKDIR/run.py"
  docker -H "$ISOLATED_HOST" cp "$SOURCE_CHECKPOINT_INPUT/native-session/." \
    "$SOURCE_CONTAINER:$TASK_WORKDIR/.claude/"
fi
docker -H "$ISOLATED_HOST" start "$SOURCE_CONTAINER" >/dev/null

SOURCE_STARTED=$SECONDS
if ! wait_for_log "$SOURCE_CONTAINER" TASK_HANDOFF_READY "$AGENT_TIMEOUT"; then
  docker -H "$ISOLATED_HOST" logs "$SOURCE_CONTAINER" > "$SOURCE_DIR/container.log" 2>&1 || true
  echo "Source model did not reach a fixed boundary" >&2
  exit 4
fi
SOURCE_BEFORE_PID=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$SOURCE_CONTAINER")
docker -H "$ISOLATED_HOST" logs "$SOURCE_CONTAINER" > "$SOURCE_DIR/container.log" 2>&1
docker -H "$ISOLATED_HOST" cp "$SOURCE_CONTAINER:/tmp/claude-handoff/manifest.json" \
  "$SOURCE_DIR/native-manifest.json"
docker -H "$ISOLATED_HOST" cp "$SOURCE_CONTAINER:/tmp/claude-handoff/source-cutpoint.json" \
  "$SOURCE_DIR/source-cutpoint.json" 2>/dev/null || printf 'null\n' > "$SOURCE_DIR/source-cutpoint.json"
docker -H "$ISOLATED_HOST" cp "$SOURCE_CONTAINER:$TASK_WORKDIR/run.py" \
  "$SOURCE_DIR/run.py"
OBSERVED_SOURCE=$("$HOST_PYTHON" -c \
  'import json,sys; print(json.load(open(sys.argv[1])).get("observed_model_turn1") or "")' \
  "$SOURCE_DIR/native-manifest.json")
[[ "$OBSERVED_SOURCE" == "$SOURCE_MODEL" ]] || {
  echo "Observed source model $OBSERVED_SOURCE did not match $SOURCE_MODEL" >&2
  exit 5
}
"$HOST_PYTHON" - "$SOURCE_DIR/native-manifest.json" "$SOURCE_DIR/source-cutpoint.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
cutpoint = json.loads(pathlib.Path(sys.argv[2]).read_text())
if manifest.get("source_strategy") not in {"write_run_py", "attempt"}:
    raise SystemExit("source manifest has an unsupported source strategy")
if manifest.get("source_cutpoint") != cutpoint:
    raise SystemExit("manifest/source cutpoint mismatch")
if manifest.get("source_strategy") == "write_run_py":
    run_py = (cutpoint or {}).get("run_py") or {}
    if not run_py.get("exists") or int(run_py.get("bytes") or 0) <= 0:
        raise SystemExit("cutpoint does not contain a non-empty run.py")
PY

CHECKPOINT="source-boundary"
CP_STARTED=$SECONDS
docker -H "$ISOLATED_HOST" checkpoint create "$SOURCE_CONTAINER" "$CHECKPOINT" >/dev/null
CHECKPOINT_MS=$(((SECONDS - CP_STARTED) * 1000))
[[ $(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Status}}' "$SOURCE_CONTAINER") == exited ]]

SOURCE_ID=$(docker -H "$ISOLATED_HOST" inspect -f '{{.Id}}' "$SOURCE_CONTAINER")
CHECKPOINT_PARENT="$RUNTIME_DIR/docker-data/containers/$SOURCE_ID/checkpoints"
cp -a "$CHECKPOINT_PARENT/$CHECKPOINT" "$RUNTIME_DIR/fixed-checkpoint/"
CHECKPOINT_SHA=$(find "$RUNTIME_DIR/fixed-checkpoint/$CHECKPOINT" -type f -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')

SOURCE_IMAGE="fixed-source-${SOURCE_SAFE}-${CAMPAIGN_ID}:local"
docker -H "$ISOLATED_HOST" export "$SOURCE_CONTAINER" \
  | docker -H "$ISOLATED_HOST" import --change "WORKDIR $TASK_WORKDIR" \
    --change 'ENTRYPOINT ["python3","-u","/opt/task_controller.py"]' \
    - "$SOURCE_IMAGE" >/dev/null
SOURCE_IMAGE_ID=$(docker -H "$ISOLATED_HOST" image inspect -f '{{.Id}}' "$SOURCE_IMAGE")

NATIVE_COPY="$RUNTIME_DIR/native-session-copy"
mkdir -p "$NATIVE_COPY"
docker -H "$ISOLATED_HOST" cp "$SOURCE_CONTAINER:$TASK_WORKDIR/.claude/." "$NATIVE_COPY/"
if grep -R -F -q -- "$CODING_PLAN_API_KEY" "$NATIVE_COPY"; then
  echo "Refusing to retain a native session containing the API key" >&2
  exit 5
fi
cp -a "$NATIVE_COPY" "$SOURCE_DIR/native-session"

SOURCE_VERIFIER="source-cutpoint-verifier"
docker -H "$ISOLATED_HOST" create --name "$SOURCE_VERIFIER" --network host \
  --entrypoint /bin/sh "$SOURCE_IMAGE" -c 'while :; do sleep 3600; done' >/dev/null
docker -H "$ISOLATED_HOST" start "$SOURCE_VERIFIER" >/dev/null
docker -H "$ISOLATED_HOST" exec "$SOURCE_VERIFIER" test ! -e /tests
run_verifier "$SOURCE_VERIFIER" "$SOURCE_DIR"
SOURCE_REWARD=$(tr -d '[:space:]' < "$SOURCE_DIR/reward.txt")
docker -H "$ISOLATED_HOST" rm -f "$SOURCE_VERIFIER" >/dev/null
SOURCE_VERIFIER_SUMMARY=$("$HOST_PYTHON" - "$SOURCE_DIR/reward.txt" "$SOURCE_DIR/ctrf.json" <<'PY'
import json
import pathlib
import sys

reward = float(pathlib.Path(sys.argv[1]).read_text().strip())
ctrf = json.loads(pathlib.Path(sys.argv[2]).read_text())
summary = ctrf.get("results", {}).get("summary", {})
tests = int(summary.get("tests", 0))
failed = int(summary.get("failed", 0))
if tests <= 0 or failed < 0 or failed > tests:
    raise SystemExit(f"invalid source verifier summary: {summary!r}")
print(json.dumps({"reward": reward, "tests": tests, "failed": failed}, sort_keys=True))
PY
)

SOURCE_MANIFEST_SHA=$(sha256sum "$SOURCE_DIR/native-manifest.json" | awk '{print $1}')
RUN_PY_SHA=$(sha256sum "$SOURCE_DIR/run.py" 2>/dev/null | awk '{print $1}' || echo null)
SOURCE_INPUT_SHA=null
SOURCE_INPUT_EPOCH=null
if [[ -n "$SOURCE_CHECKPOINT_INPUT" ]]; then
  SOURCE_INPUT_SHA=$(find "$SOURCE_CHECKPOINT_INPUT" -type f -print0 \
    | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
  SOURCE_INPUT_EPOCH=$("$HOST_PYTHON" -c \
    'import json,sys; print(json.load(open(sys.argv[1])).get("controller_epoch") or "null")' \
    "$SOURCE_CHECKPOINT_INPUT/native-manifest.json")
fi
"$HOST_PYTHON" - "$SOURCE_DIR/checkpoint.json" \
  "$SOURCE_CHECKPOINT_INPUT" "$SOURCE_INPUT_SHA" "$SOURCE_INPUT_EPOCH" <<PY
import json
from pathlib import Path
import sys

native = json.loads(Path("$SOURCE_DIR/native-manifest.json").read_text())
cutpoint = json.loads(Path("$SOURCE_DIR/source-cutpoint.json").read_text())
result = {
    "schema_version": "fixed-native-cutpoint-v0.2",
    "campaign_id": "$CAMPAIGN_ID",
    "task_id": "$TASK_ID",
    "source_model": "$SOURCE_MODEL",
    "observed_source_model": native.get("observed_model_turn1"),
    "source_reward": float("$SOURCE_REWARD"),
    "source_strategy": "$SOURCE_STRATEGY",
    "source_cutpoint": cutpoint,
    "source_checkpoint_id": "$CHECKPOINT",
    "criu_checkpoint_sha256": "$CHECKPOINT_SHA",
    "source_image_id": "$SOURCE_IMAGE_ID",
    "native_manifest_sha256": "$SOURCE_MANIFEST_SHA",
    "workspace_run_py_sha256": "$RUN_PY_SHA",
    "session_id": native.get("session_id"),
    "session_jsonl": native.get("jsonl_before"),
    "controller_epoch": native.get("controller_epoch"),
    "rehydrated_from_controller_epoch": native.get("rehydrated_from_controller_epoch"),
    "quiescence": native.get("quiescence"),
    "checkpoint_ms": $CHECKPOINT_MS,
    "source_turn_ms": native.get("turn1_ms"),
    "source_verifier": json.loads('''$SOURCE_VERIFIER_SUMMARY'''),
    "private_tests_present_in_source": False,
    "criu_images_retained": False,
    "source_checkpoint_input": sys.argv[2] or None,
    "source_checkpoint_input_sha256": None if sys.argv[3] == "null" else sys.argv[3],
    "source_checkpoint_input_controller_epoch": None if sys.argv[4] == "null" else sys.argv[4],
    "note": "Targets derive from one fixed workspace and native session. When source_checkpoint_input is set, a waiting controller is rehydrated and then CRIU-checkpointed. Sensitive CRIU pages are deleted during cleanup.",
}
Path("$SOURCE_DIR/checkpoint.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
PY

summarize_route() {
  local target=$1 mode=$2 container=$3 before_pid=$4 after_pid=$5 restored=$6
  local checkpoint_created=$7 restore_ms=$8 turn1_log=$9 route_dir=${10} total_ms=${11}
  local verifier_exit verifier_ms reward
  local route_checkpoint_ms=$CHECKPOINT_MS
  [[ "$checkpoint_created" == true ]] || route_checkpoint_ms=0
  verifier_exit=$(cat "$route_dir/verifier-exit-code.txt")
  verifier_ms=$(cat "$route_dir/verifier-duration-ms.txt")
  reward=$(tr -d '[:space:]' < "$route_dir/reward.txt")
  "$HOST_PYTHON" "$ROOT_DIR/scripts/summarize-task-run.py" \
    --log "$route_dir/container.log" --turn1-log "$turn1_log" \
    --output "$route_dir/run.json" --run-id "$(basename "$route_dir")" \
    --campaign-id "$CAMPAIGN_ID" --git-sha "$GIT_SHA" --replicate 1 \
    --task-id "$TASK_ID" --dataset-sha256 "$DATASET_SHA" \
    --source-model "$SOURCE_MODEL" --target-model "$target" --mode "$mode" \
    --checkpoint-state exited --resume-delay-ms 0 --before-pid "$before_pid" \
    --after-pid "$after_pid" --checkpoint-created "$checkpoint_created" \
    --restored "$restored" --checkpoint-ms "$route_checkpoint_ms" \
    --restore-ms "$restore_ms" --verifier-exit "$verifier_exit" \
    --verifier-ms "$verifier_ms" --reward "$reward" --total-ms "$total_ms" \
    --docker-version "$DOCKER_VERSION" --runc-version "$RUNC_VERSION" \
    --criu-version "$CRIU_VERSION" --kernel "$KERNEL_VERSION"
  "$HOST_PYTHON" - "$route_dir/run.json" "$SOURCE_DIR/checkpoint.json" <<'PY'
import hashlib
import json
import pathlib
import sys

run_path = pathlib.Path(sys.argv[1])
checkpoint = json.loads(pathlib.Path(sys.argv[2]).read_text())
run = json.loads(run_path.read_text())
run["source_checkpoint"] = checkpoint
final_path = run_path.parent / "final-run.py"
final_bytes = final_path.read_bytes() if final_path.exists() else b""
restored_run_py = {}
container_log = run_path.parent / "container.log"
for line in container_log.read_text(errors="replace").splitlines():
    if line.startswith("TASK_WORKSPACE_AFTER_RESTORE "):
        restored_run_py = json.loads(line.split(" ", 1)[1]).get("run_py") or {}
        break
source_sha = checkpoint.get("workspace_run_py_sha256")
final_sha = hashlib.sha256(final_bytes).hexdigest() if final_bytes else None
run["workspace_transition"] = {
    "source_run_py_sha256": source_sha,
    "restored_run_py_sha256": restored_run_py.get("sha256"),
    "restore_hash_match": restored_run_py.get("sha256") == source_sha,
    "final_run_py_sha256": final_sha,
    "final_run_py_bytes": len(final_bytes),
    "target_changed_run_py": bool(final_sha and final_sha != source_sha),
}
observed_source = run["route"].get("observed_model_turn1")
observed_target = run["route"].get("observed_model_turn2")
run["route"]["identity_match"] = (
    observed_source == run["route"]["source_model"]
    and observed_target == run["route"]["target_model"]
)
if not run["route"]["identity_match"]:
    run["outcome"].update({
        "status": "fail",
        "failure_stage": "model_identity",
        "error_class": "model_identity_mismatch",
        "error_message_sanitized": "observed model identity did not match the requested cross-model route",
    })
run_path.write_text(json.dumps(run, indent=2, sort_keys=True) + "\n")
PY
}

run_target() {
  local target=$1 container=$2 mode=$3 before_pid=$4 after_pid=$5 restored=$6
  local checkpoint_created=$7 restore_ms=$8 turn1_log=$9 route_started=${10}
  local target_safe route_id route_dir
  target_safe=$(safe_name "$target")
  route_id="${TASK_ID}__${SOURCE_SAFE}-to-${target_safe}__${mode}__r1"
  route_dir="$CAMPAIGN_DIR/$route_id"
  mkdir -p "$route_dir"

  if ! wait_for_log "$container" TASK_HANDOFF_COMPLETE "$AGENT_TIMEOUT"; then
    # The SDK can time out after it has already produced a valid workspace.
    # Freeze that exact state and verify the copied workspace independently;
    # agent completion and task correctness are intentionally separate fields.
    docker -H "$ISOLATED_HOST" pause "$container" >/dev/null 2>&1 || true
    docker -H "$ISOLATED_HOST" logs "$container" > "$route_dir/container.log" 2>&1 || true
    docker -H "$ISOLATED_HOST" cp "$container:/tmp/claude-handoff/evidence.txt" \
      "$route_dir/evidence.txt" 2>/dev/null || true
    docker -H "$ISOLATED_HOST" cp "$container:$TASK_WORKDIR/run.py" \
      "$route_dir/final-run.py" 2>/dev/null || true
    timeout_workspace="$RUNTIME_DIR/timeout-workspace-$target_safe"
    rm -rf "$timeout_workspace"
    mkdir -p "$timeout_workspace"
    docker -H "$ISOLATED_HOST" cp "$container:$TASK_WORKDIR/." \
      "$timeout_workspace/" 2>/dev/null || true
    docker -H "$ISOLATED_HOST" rm -f "$container" >/dev/null 2>&1 || true
    timeout_verifier="takeover-timeout-verifier-$target_safe"
    docker -H "$ISOLATED_HOST" create --name "$timeout_verifier" --network host \
      --entrypoint /bin/sh "$SOURCE_IMAGE" -c 'while :; do sleep 3600; done' >/dev/null
    docker -H "$ISOLATED_HOST" start "$timeout_verifier" >/dev/null
    docker -H "$ISOLATED_HOST" cp "$timeout_workspace/." \
      "$timeout_verifier:$TASK_WORKDIR/"
    run_verifier "$timeout_verifier" "$route_dir"
    docker -H "$ISOLATED_HOST" rm -f "$timeout_verifier" >/dev/null
    printf '125\n' > "$route_dir/controller-exit-code.txt"
    summarize_route "$target" "$mode" "$container" "$before_pid" "$after_pid" \
      "$restored" "$checkpoint_created" "$restore_ms" "$turn1_log" "$route_dir" \
      "$(((SECONDS - route_started) * 1000))"
    "$HOST_PYTHON" - "$route_dir/run.json" <<'PY'
import json
import pathlib
import sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["outcome"].update({"status": "fail", "failure_stage": "target_phase", "error_class": "target_timeout_or_failure"})
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
    return 0
  fi

  docker -H "$ISOLATED_HOST" logs "$container" > "$route_dir/container.log" 2>&1
  docker -H "$ISOLATED_HOST" cp "$container:/tmp/claude-handoff/evidence.txt" \
    "$route_dir/evidence.txt"
  docker -H "$ISOLATED_HOST" cp "$container:$TASK_WORKDIR/run.py" \
    "$route_dir/final-run.py"
  grep -q '"same_session": true' "$route_dir/container.log"
  grep -q '"semantic_evidence": true' "$route_dir/container.log"
  grep -Fxq "NATIVE_SESSION_RESUMED $NONCE" "$route_dir/evidence.txt"
  run_verifier "$container" "$route_dir"
  docker -H "$ISOLATED_HOST" exec "$container" touch /tmp/claude-handoff/verifier-complete
  docker -H "$ISOLATED_HOST" wait "$container" > "$route_dir/controller-exit-code.txt"
  docker -H "$ISOLATED_HOST" logs "$container" > "$route_dir/container.log" 2>&1
  summarize_route "$target" "$mode" "$container" "$before_pid" "$after_pid" \
    "$restored" "$checkpoint_created" "$restore_ms" "$turn1_log" "$route_dir" \
    "$(((SECONDS - route_started) * 1000))"
  docker -H "$ISOLATED_HOST" rm "$container" >/dev/null
  echo "TAKEOVER_COMPLETE source=$SOURCE_MODEL target=$target mode=$mode reward=$(cat "$route_dir/reward.txt")"
}

IFS=',' read -r -a TARGET_LIST <<< "$TARGET_MODELS"
[[ ${#TARGET_LIST[@]} -gt 0 ]] || { echo "No target models" >&2; exit 2; }

FIRST_TARGET=${TARGET_LIST[0]}
RESTORE_STARTED=$SECONDS
docker -H "$ISOLATED_HOST" start --checkpoint "$CHECKPOINT" "$SOURCE_CONTAINER" >/dev/null
FIRST_RESTORE_MS=$(((SECONDS - RESTORE_STARTED) * 1000))
FIRST_AFTER_PID=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$SOURCE_CONTAINER")
RESTORED_RUN_PY_SHA=$(docker -H "$ISOLATED_HOST" exec "$SOURCE_CONTAINER" \
  sha256sum "$TASK_WORKDIR/run.py" | awk '{print $1}')
[[ "$RESTORED_RUN_PY_SHA" == "$RUN_PY_SHA" ]] || {
  echo "run.py changed across CRIU restore" >&2
  exit 7
}
docker -H "$ISOLATED_HOST" exec "$SOURCE_CONTAINER" sh -lc \
  'printf "%s\n" "$1" > /tmp/claude-handoff/target-model && touch /tmp/claude-handoff/continue' \
  sh "$FIRST_TARGET"
run_target "$FIRST_TARGET" "$SOURCE_CONTAINER" criu_stable "$SOURCE_BEFORE_PID" \
  "$FIRST_AFTER_PID" true true "$FIRST_RESTORE_MS" /dev/null "$SECONDS"

for target in "${TARGET_LIST[@]:1}"; do
  target_safe=$(safe_name "$target")
  clone="takeover-clone-$target_safe"
  docker -H "$ISOLATED_HOST" create --name "$clone" --network host \
    --security-opt seccomp=unconfined --cpus "$CPU_LIMIT" --memory "${MEMORY_MB}m" \
    "$SOURCE_IMAGE" >/dev/null
  restore_started=$SECONDS
  set +e
  docker -H "$ISOLATED_HOST" start --checkpoint-dir "$RUNTIME_DIR/fixed-checkpoint" \
    --checkpoint "$CHECKPOINT" "$clone" >"$CAMPAIGN_DIR/${target_safe}-clone-restore.log" 2>&1
  clone_restore_exit=$?
  set -e
  if ((clone_restore_exit == 0)); then
    restore_ms=$(((SECONDS - restore_started) * 1000))
    after_pid=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$clone")
    docker -H "$ISOLATED_HOST" exec "$clone" sh -lc \
      'printf "%s\n" "$1" > /tmp/claude-handoff/target-model && touch /tmp/claude-handoff/continue' \
      sh "$target"
    run_target "$target" "$clone" criu_clone "$SOURCE_BEFORE_PID" "$after_pid" \
      true true "$restore_ms" "$SOURCE_DIR/container.log" "$SECONDS"
  else
    docker -H "$ISOLATED_HOST" rm -f "$clone" >/dev/null 2>&1 || true
    clone="takeover-cold-$target_safe"
    route_env="$RUNTIME_DIR/${target_safe}-cold.env"
    make_env_file "$route_env" "$SOURCE_MODEL" "$target" resume "$NONCE" attempt
    docker -H "$ISOLATED_HOST" run -d --name "$clone" --network host \
      --security-opt seccomp=unconfined --cpus "$CPU_LIMIT" --memory "${MEMORY_MB}m" \
      --env-file "$route_env" "$SOURCE_IMAGE" >/dev/null
    after_pid=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$clone")
    run_target "$target" "$clone" native_resume_cold null "$after_pid" \
      false false 0 "$SOURCE_DIR/container.log" "$SECONDS"
  fi
done

cleanup
trap - EXIT
MAIN_DOCKER_PID_AFTER=$(systemctl show -p MainPID --value docker 2>/dev/null || echo unknown)
MAIN_UNTOUCHED=false
[[ "$MAIN_DOCKER_PID_BEFORE" == "$MAIN_DOCKER_PID_AFTER" ]] && MAIN_UNTOUCHED=true
SECRET_SCAN_CLEAN=true
if grep -R -F -q -- "$CODING_PLAN_API_KEY" "$CAMPAIGN_DIR"; then
  SECRET_SCAN_CLEAN=false
fi
"$HOST_PYTHON" - "$CAMPAIGN_DIR" "$MAIN_UNTOUCHED" "$SECRET_SCAN_CLEAN" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
main_untouched = sys.argv[2] == "true"
secret_clean = sys.argv[3] == "true"
for path in root.rglob("run.json"):
    data = json.loads(path.read_text())
    data["cleanup"] = {
        "runtime_removed": True,
        "main_docker_untouched": main_untouched,
        "secret_scan_clean": secret_clean,
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
chown -R "$OWNER_UID:$OWNER_GID" "$CAMPAIGN_DIR"
echo "FIXED_TAKEOVER_COMPLETE $CAMPAIGN_DIR"
