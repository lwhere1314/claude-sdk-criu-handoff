#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-"$ROOT_DIR/.env"}
TASK_DIR=""
MODELS="kimi-k2.6"
MODES="criu_stable"
REPEATS=1
RESUME_DELAY_SEC=0
ARTIFACT_ROOT=${ARTIFACT_ROOT:-"$ROOT_DIR/artifacts/task-matrix"}
STORAGE_DRIVER=${STORAGE_DRIVER:-overlay2}
CAMPAIGN_ID=${CAMPAIGN_ID:-"tb21-$(date -u +%Y%m%dT%H%M%SZ)"}
RUNTIME_DIR=""
CONTAINERD_PID=""
DOCKERD_PID=""
ADAPTER_IMAGE=""
MAIN_IMAGE_CREATED=0
MAIN_DOCKER_PID_BEFORE=$(systemctl show -p MainPID --value docker 2>/dev/null || echo unknown)
HOST_PYTHON=${HOST_PYTHON:-$(command -v python3)}
OWNER_UID=${SUDO_UID:-$UID}
OWNER_GID=${SUDO_GID:-$(id -g)}

usage() {
  cat <<'EOF'
Usage: run-task-matrix.sh --task-dir PATH [options]

Options:
  --models CSV              Same-model routes (default: kimi-k2.6)
  --modes CSV               criu_stable,uninterrupted,native_resume_cold
  --repeats N               Replicates per cell (default: 1)
  --resume-delay-sec N       Delay after restore before resume signal
  --artifact-root PATH       Output directory
  --campaign-id ID           Stable campaign identifier
EOF
}

while (($#)); do
  case "$1" in
    --task-dir) TASK_DIR=$2; shift 2 ;;
    --models) MODELS=$2; shift 2 ;;
    --modes) MODES=$2; shift 2 ;;
    --repeats) REPEATS=$2; shift 2 ;;
    --resume-delay-sec) RESUME_DELAY_SEC=$2; shift 2 ;;
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
RUNTIME_DIR=${RUNTIME_DIR_OVERRIDE:-"/tmp/claude-sdk-criu-${TASK_ID}-${SUDO_UID:-$UID}"}

if (( EUID != 0 )); then
  exec sudo \
    --preserve-env=ENV_FILE,ARTIFACT_ROOT,CAMPAIGN_ID,RUNTIME_DIR_OVERRIDE,STORAGE_DRIVER,HOST_PYTHON,CODING_PLAN_BASE_URL,CODING_PLAN_API_KEY \
    "$0" --task-dir "$TASK_DIR" --models "$MODELS" --modes "$MODES" \
    --repeats "$REPEATS" --resume-delay-sec "$RESUME_DELAY_SEC" \
    --artifact-root "$ARTIFACT_ROOT" --campaign-id "$CAMPAIGN_ID"
fi

for command in containerd dockerd docker criu runc timeout sha256sum findmnt; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 2; }
done
[[ -x "$HOST_PYTHON" ]] || { echo "HOST_PYTHON is not executable: $HOST_PYTHON" >&2; exit 2; }

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

docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || {
  echo "Base image $BASE_IMAGE is absent; building from task environment..."
  docker build --network host -t "$BASE_IMAGE" "$TASK_DIR/environment"
}
TASK_WORKDIR=${TASK_WORKDIR:-$(docker image inspect -f '{{.Config.WorkingDir}}' "$BASE_IMAGE")}
TASK_WORKDIR=${TASK_WORKDIR:-/app}

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR/adapter" "$RUNTIME_DIR/containerd-root" \
  "$RUNTIME_DIR/containerd-state" "$RUNTIME_DIR/docker-data" "$RUNTIME_DIR/docker-exec"
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
  --containerd "$CONTAINERD_SOCKET" --containerd-namespace "criu-$TASK_ID" \
  --containerd-plugins-namespace "criu-$TASK_ID-plugins" \
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

wait_for_log() {
  local container=$1 marker=$2 timeout_sec=$3
  local deadline=$((SECONDS + timeout_sec))
  while ((SECONDS < deadline)); do
    docker -H "$ISOLATED_HOST" logs "$container" 2>&1 | grep -q "$marker" && return 0
    local state
    state=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Status}}' "$container")
    [[ "$state" == running ]] || {
      docker -H "$ISOLATED_HOST" logs "$container" >&2
      return 1
    }
    sleep 1
  done
  return 1
}

make_env_file() {
  local path=$1 model=$2 phase=$3 nonce=$4
  local old_umask
  old_umask=$(umask)
  umask 077
  {
    printf 'ANTHROPIC_BASE_URL=%s\n' "$CODING_PLAN_BASE_URL"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "$CODING_PLAN_API_KEY"
    printf 'SOURCE_MODEL=%s\n' "$model"
    printf 'TARGET_MODEL=%s\n' "$model"
    printf 'HANDOFF_NONCE=%s\n' "$nonce"
    printf 'HANDOFF_PHASE=%s\n' "$phase"
    printf 'HANDOFF_MARKER_DIR=/tmp/claude-handoff\n'
    printf 'TASK_WORKDIR=%s\n' "$TASK_WORKDIR"
    printf 'TASK_INSTRUCTION_PATH=/opt/task-instruction.md\n'
    printf 'CLAUDE_CONFIG_DIR=%s/.claude\n' "$TASK_WORKDIR"
    printf 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1\n'
    printf 'IS_SANDBOX=1\n'
    printf 'WAIT_FOR_VERIFIER=1\n'
    printf 'PHASE1_MAX_TURNS=3\n'
    printf 'PHASE1_MAX_THINKING_TOKENS=2048\n'
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

IFS=',' read -r -a MODEL_LIST <<< "$MODELS"
IFS=',' read -r -a MODE_LIST <<< "$MODES"
mkdir -p "$ARTIFACT_ROOT/$CAMPAIGN_ID"

for model in "${MODEL_LIST[@]}"; do
  for mode in "${MODE_LIST[@]}"; do
    case "$mode" in criu_stable|uninterrupted|native_resume_cold) ;; *) echo "Bad mode: $mode"; exit 2;; esac
    for replicate in $(seq 1 "$REPEATS"); do
      safe_model=${model//[^a-zA-Z0-9_.-]/-}
      run_id="${TASK_ID}__${safe_model}__${mode}__r${replicate}"
      artifact_dir="$ARTIFACT_ROOT/$CAMPAIGN_ID/$run_id"
      mkdir -p "$artifact_dir"
      nonce="${CAMPAIGN_ID}-${run_id}-$RANDOM"
      container="handoff-${safe_model}-${mode}-${replicate}"
      checkpoint="cp-${replicate}"
      env_file="$RUNTIME_DIR/${run_id}.env"
      phase=both
      [[ "$mode" == native_resume_cold ]] && phase=first
      make_env_file "$env_file" "$model" "$phase" "$nonce"
      started_total=$SECONDS
      before_pid=null after_pid=null checkpoint_state=null checkpoint_created=false restored=false
      checkpoint_ms=0 restore_ms=0

      docker -H "$ISOLATED_HOST" run -d --name "$container" --network host \
        --security-opt seccomp=unconfined --cpus "$CPU_LIMIT" --memory "${MEMORY_MB}m" \
        --env-file "$env_file" "$ADAPTER_IMAGE" >/dev/null
      wait_for_log "$container" TASK_HANDOFF_READY "$AGENT_TIMEOUT"

      if [[ "$mode" == criu_stable ]]; then
        before_pid=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$container")
        cp_start=$SECONDS
        docker -H "$ISOLATED_HOST" checkpoint create "$container" "$checkpoint" >/dev/null
        checkpoint_ms=$(((SECONDS - cp_start) * 1000))
        checkpoint_created=true
        checkpoint_state=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Status}}' "$container")
        [[ "$checkpoint_state" == exited ]]
        restore_start=$SECONDS
        docker -H "$ISOLATED_HOST" start --checkpoint "$checkpoint" "$container" >/dev/null
        restore_ms=$(((SECONDS - restore_start) * 1000))
        restored=true
        after_pid=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$container")
        ((RESUME_DELAY_SEC > 0)) && sleep "$RESUME_DELAY_SEC"
        docker -H "$ISOLATED_HOST" exec "$container" touch /tmp/claude-handoff/continue
      elif [[ "$mode" == uninterrupted ]]; then
        before_pid=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$container")
        after_pid=$before_pid
        checkpoint_state=running
        ((RESUME_DELAY_SEC > 0)) && sleep "$RESUME_DELAY_SEC"
        docker -H "$ISOLATED_HOST" exec "$container" touch /tmp/claude-handoff/continue
      else
        docker -H "$ISOLATED_HOST" wait "$container" >/dev/null
        docker -H "$ISOLATED_HOST" logs "$container" > "$artifact_dir/turn1-container.log" 2>&1
        cold_image="cold-${safe_model}-${replicate}:local"
        docker -H "$ISOLATED_HOST" export "$container" | docker -H "$ISOLATED_HOST" import \
          --change "WORKDIR $TASK_WORKDIR" \
          --change 'ENTRYPOINT ["python3","-u","/opt/task_controller.py"]' - "$cold_image" >/dev/null
        docker -H "$ISOLATED_HOST" rm "$container" >/dev/null
        container="handoff-${safe_model}-cold-resume-${replicate}"
        make_env_file "$env_file" "$model" resume "$nonce"
        docker -H "$ISOLATED_HOST" run -d --name "$container" --network host \
          --security-opt seccomp=unconfined --cpus "$CPU_LIMIT" --memory "${MEMORY_MB}m" \
          --env-file "$env_file" "$cold_image" >/dev/null
        after_pid=$(docker -H "$ISOLATED_HOST" inspect -f '{{.State.Pid}}' "$container")
        checkpoint_state=not_attempted
      fi

      wait_for_log "$container" TASK_HANDOFF_COMPLETE "$AGENT_TIMEOUT"
      docker -H "$ISOLATED_HOST" logs "$container" > "$artifact_dir/container.log" 2>&1
      docker -H "$ISOLATED_HOST" cp "$container:/tmp/claude-handoff/evidence.txt" \
        "$artifact_dir/evidence.txt"
      grep -q '"same_session": true' "$artifact_dir/container.log"
      grep -q '"semantic_evidence": true' "$artifact_dir/container.log"
      grep -Fxq "NATIVE_SESSION_RESUMED $nonce" "$artifact_dir/evidence.txt"
      run_verifier "$container" "$artifact_dir"
      docker -H "$ISOLATED_HOST" exec "$container" touch /tmp/claude-handoff/verifier-complete
      docker -H "$ISOLATED_HOST" wait "$container" > "$artifact_dir/controller-exit-code.txt"
      docker -H "$ISOLATED_HOST" logs "$container" > "$artifact_dir/container.log" 2>&1
      total_ms=$(((SECONDS - started_total) * 1000))

      "$HOST_PYTHON" "$ROOT_DIR/scripts/summarize-task-run.py" \
        --log "$artifact_dir/container.log" \
        --turn1-log "$artifact_dir/turn1-container.log" \
        --output "$artifact_dir/run.json" --run-id "$run_id" --campaign-id "$CAMPAIGN_ID" \
        --git-sha "$GIT_SHA" --replicate "$replicate" --task-id "$TASK_ID" \
        --dataset-sha256 "$DATASET_SHA" --model "$model" --mode "$mode" \
        --resume-delay-ms "$((RESUME_DELAY_SEC * 1000))" --before-pid "$before_pid" \
        --after-pid "$after_pid" --checkpoint-created "$checkpoint_created" \
        --checkpoint-state "$checkpoint_state" --restored "$restored" \
        --checkpoint-ms "$checkpoint_ms" --restore-ms "$restore_ms" \
        --verifier-exit "$(cat "$artifact_dir/verifier-exit-code.txt")" \
        --verifier-ms "$(cat "$artifact_dir/verifier-duration-ms.txt")" \
        --reward "$(tr -d '[:space:]' < "$artifact_dir/reward.txt")" --total-ms "$total_ms" \
        --docker-version "$DOCKER_VERSION" --runc-version "$RUNC_VERSION" \
        --criu-version "$CRIU_VERSION" --kernel "$KERNEL_VERSION"

      docker -H "$ISOLATED_HOST" rm "$container" >/dev/null
      [[ "$mode" == native_resume_cold ]] && docker -H "$ISOLATED_HOST" image rm "$cold_image" >/dev/null
      echo "RUN_COMPLETE task=$TASK_ID model=$model mode=$mode reward=$(cat "$artifact_dir/reward.txt")"
    done
  done
done

cleanup
trap - EXIT
MAIN_DOCKER_PID_AFTER=$(systemctl show -p MainPID --value docker 2>/dev/null || echo unknown)
MAIN_UNTOUCHED=false
[[ "$MAIN_DOCKER_PID_BEFORE" == "$MAIN_DOCKER_PID_AFTER" ]] && MAIN_UNTOUCHED=true
SECRET_SCAN_CLEAN=true
if grep -R -F -q -- "$CODING_PLAN_API_KEY" "$ARTIFACT_ROOT/$CAMPAIGN_ID"; then
  SECRET_SCAN_CLEAN=false
fi
"$HOST_PYTHON" - "$ARTIFACT_ROOT/$CAMPAIGN_ID" "$MAIN_UNTOUCHED" "$SECRET_SCAN_CLEAN" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
main_untouched = sys.argv[2] == "true"
secret_clean = sys.argv[3] == "true"
for path in root.rglob("run.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    data["cleanup"] = {
        "runtime_removed": True,
        "main_docker_untouched": main_untouched,
        "secret_scan_clean": secret_clean,
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
chown -R "$OWNER_UID:$OWNER_GID" "$ARTIFACT_ROOT/$CAMPAIGN_ID"
echo "CAMPAIGN_COMPLETE $ARTIFACT_ROOT/$CAMPAIGN_ID"
