#!/usr/bin/env bash
# Receives the CleanCam stream and shows it as a webcam named "CleanCam" (/dev/video10),
# and the phone's microphone as a microphone named "CleanCam".
#   cleancam-receive.sh             iPhone on USB (needs usbmuxd running and iproxy)
#   cleancam-receive.sh PHONE_IP    iPhone on the same WiFi
# Needs ffmpeg and the v4l2loopback kernel module; the microphone needs PipeWire (pw-cli).
set -euo pipefail

PORT=${PORT:-5000}              # TCP port the app sends video on
AUDIO_PORT=${AUDIO_PORT:-5001}  # TCP port the app sends microphone audio on
VIDEO_NR=${VIDEO_NR:-10}        # webcam device number: /dev/video$VIDEO_NR
VIDEO=/dev/video$VIDEO_NR
HOST=${1:-}

# Stop what this script started in the background: iproxy, the CleanCam microphone and the audio loop.
trap 'pkill -P $$ 2>/dev/null' EXIT

if [[ ! -e $VIDEO ]]; then
  # exclusive_caps=1 lets Chrome and other WebRTC apps list the device as a camera.
  sudo modprobe v4l2loopback video_nr="$VIDEO_NR" card_label=CleanCam exclusive_caps=1
fi

if [[ -z $HOST ]]; then
  # iproxy forwards localhost:PORT and localhost:AUDIO_PORT to the app's ports through the USB cable.
  iproxy "$PORT:$PORT" "$AUDIO_PORT:$AUDIO_PORT" >/dev/null &
  HOST=127.0.0.1
fi

if command -v pw-cli >/dev/null; then
  FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-mic.fifo
  # A PipeWire source named "CleanCam", which video apps list as a microphone, reads the raw audio from FIFO.
  # It plays silence while nothing arrives and matches its rate to the phone's clock;
  # always-process keeps it reading while no app records, so audio never piles up.
  pw-cli -m load-module libpipewire-module-pipe-tunnel "{ tunnel.mode = source pipe.filename = \"$FIFO\"
    audio.format = S16LE audio.rate = 48000 audio.channels = 1 audio.position = [ MONO ]
    stream.props = { node.name = cleancam-mic node.description = CleanCam node.always-process = true } }" >/dev/null &
  while true; do
    # ffmpeg writes whole samples, so a reconnect never shifts the bytes out of order.
    if [[ -p $FIFO ]]; then
      ffmpeg -hide_banner -loglevel warning \
        -f s16le -ar 48000 -ac 1 -i "tcp://$HOST:$AUDIO_PORT" -f s16le -y "$FIFO" || true
    fi
    sleep 1  # the app is closed or not reachable yet, or the microphone is starting; try again
  done &
else
  echo "pw-cli not found: video only. The CleanCam microphone needs PipeWire." >&2
fi

echo "Writing the CleanCam stream from $HOST:$PORT to $VIDEO and its sound to the CleanCam microphone. Ctrl-C to stop."
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -f h264 -framerate 30 -i "tcp://$HOST:$PORT" \
    -fps_mode passthrough -pix_fmt yuv420p -f v4l2 "$VIDEO" || true
  sleep 1  # the app is closed or not reachable yet; try again
done
