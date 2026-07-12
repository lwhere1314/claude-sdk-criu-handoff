#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_DIR=${1:-"/tmp/claude-sdk-criu-handoff-${SUDO_UID:-$UID}"}

if (( EUID != 0 )); then
  exec sudo "$0" "$RUNTIME_DIR"
fi

case "$RUNTIME_DIR" in
  /tmp/claude-sdk-criu-handoff-*) ;;
  *) echo "Refusing to clean unexpected path: $RUNTIME_DIR" >&2; exit 2 ;;
esac

for pid_file in "$RUNTIME_DIR/dockerd.pid"; do
  [[ -r "$pid_file" ]] || continue
  pid=$(cat "$pid_file")
  [[ -r "/proc/$pid/cmdline" ]] || continue
  command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  [[ "$command_line" == *"$RUNTIME_DIR"* ]] && kill -TERM "$pid" 2>/dev/null || true
done

while read -r pid; do
  [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || continue
  command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  [[ "$command_line" == *"$RUNTIME_DIR"* ]] && kill -TERM "$pid" 2>/dev/null || true
done < <(pgrep -x containerd || true)

sleep 1
umount -l "$RUNTIME_DIR/docker-exec/netns/default" 2>/dev/null || true
rm -rf "$RUNTIME_DIR"
echo "Removed isolated runtime: $RUNTIME_DIR"
