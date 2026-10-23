#!/usr/bin/env bash
# Receives the CleanCam stream and shows it as a webcam named "CleanCam" (/dev/video10).
#   cleancam-receive.sh             iPhone on USB (needs usbmuxd running and iproxy)
#   cleancam-receive.sh PHONE_IP    iPhone on the same WiFi
# Needs ffmpeg and the v4l2loopback kernel module.
set -euo pipefail

PORT=${PORT:-5000}        # TCP port the app listens on
VIDEO_NR=${VIDEO_NR:-10}  # webcam device number: /dev/video$VIDEO_NR
VIDEO=/dev/video$VIDEO_NR
HOST=${1:-}

if [[ ! -e $VIDEO ]]; then
  # exclusive_caps=1 lets Chrome and other WebRTC apps list the device as a camera.
  sudo modprobe v4l2loopback video_nr="$VIDEO_NR" card_label=CleanCam exclusive_caps=1
fi

if [[ -z $HOST ]]; then
  # iproxy forwards localhost:PORT to the app's PORT through the USB cable.
  iproxy "$PORT:$PORT" >/dev/null &
  IPROXY_PID=$!
  trap 'kill "$IPROXY_PID" 2>/dev/null' EXIT
  HOST=127.0.0.1
fi

echo "Writing the CleanCam stream from $HOST:$PORT to $VIDEO. Ctrl-C to stop."
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -f h264 -framerate 30 -i "tcp://$HOST:$PORT" \
    -fps_mode passthrough -pix_fmt yuv420p -f v4l2 "$VIDEO" || true
  sleep 1  # the app is closed or not reachable yet; try again
done
