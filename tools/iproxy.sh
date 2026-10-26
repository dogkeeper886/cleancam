#!/usr/bin/env bash
# Runs iproxy (libusbmuxd), which forwards localhost ports to the iPhone's ports over USB, natively when the host has
# it, otherwise in a container with Ubuntu's libusbmuxd-tools: RHEL 8 packages none.
#   tools/iproxy.sh 5000:5000 5001:5001 5002:5002
#   IPROXY_IMAGE   container image to build and use (default: cleancam-idevice)
# The container reaches the host's usbmuxd through its socket. usbmuxd exits when the last iPhone is unplugged and
# makes a new socket when one is plugged in, so the script restarts the container on each new socket.
set -euo pipefail

if command -v iproxy >/dev/null; then
  exec iproxy "$@"
fi

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "iproxy not found: install libusbmuxd's tools, or podman or docker to run it in a container." >&2
  exit 1
fi

IMAGE=${IPROXY_IMAGE:-cleancam-idevice}
SOCKET=/run/usbmuxd
NAME=cleancam-iproxy-$$

if ! "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
  "$RUNTIME" build -q -t "$IMAGE" - >/dev/null <<'EOF'
FROM docker.io/library/ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libimobiledevice-utils libusbmuxd-tools \
    && rm -rf /var/lib/apt/lists/*
EOF
fi

trap '"$RUNTIME" rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
trap 'exit 0' INT TERM

# Identifies the socket file, so a new usbmuxd's socket differs from the one the container holds.
socket_id() { stat -Lc '%i %Z' "$SOCKET" 2>/dev/null || true; }

started=
while true; do
  current=$(socket_id)
  if [[ -n $current ]]; then
    running=$("$RUNTIME" container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)
    if [[ $current != "$started" || $running != true ]]; then
      "$RUNTIME" rm -f "$NAME" >/dev/null 2>&1 || true
      # --mount fails while the socket is missing, where -v would make a directory in its place.
      if "$RUNTIME" run -d --name "$NAME" --network host --security-opt label=disable \
          --mount "type=bind,source=$SOCKET,target=$SOCKET" "$IMAGE" iproxy "$@" >/dev/null; then
        started=$current
      fi
    fi
  fi
  sleep 1
done
