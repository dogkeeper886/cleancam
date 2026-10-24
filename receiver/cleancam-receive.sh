#!/usr/bin/env bash
# Receives the CleanCam stream and shows it as a webcam named "CleanCam" (/dev/video10),
# and the phone's microphone as a microphone named "CleanCam".
#   cleancam-receive.sh             iPhone on USB (needs usbmuxd running and iproxy)
#   cleancam-receive.sh PHONE_IP    iPhone on the same WiFi
# Needs ffmpeg and the v4l2loopback kernel module; the microphone needs PipeWire (pw-cat).
set -euo pipefail

PORT=${PORT:-5000}              # TCP port the app sends video on
AUDIO_PORT=${AUDIO_PORT:-5001}  # TCP port the app sends microphone audio on
VIDEO_NR=${VIDEO_NR:-10}        # webcam device number: /dev/video$VIDEO_NR
VIDEO=/dev/video$VIDEO_NR
HOST=${1:-}

# Stop what this script started in the background: iproxy, the audio loop and pw-cat.
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

if command -v pw-cat >/dev/null; then
  # The raw audio becomes a PipeWire source named "CleanCam", which video apps list as a microphone.
  # aresample follows the arrival time, so the phone's and the PC's clocks drifting apart adds no lag;
  # always-process keeps the source running while no app records, so audio never piles up.
  while true; do
    ffmpeg -hide_banner -loglevel warning \
      -use_wallclock_as_timestamps 1 -f s16le -ar 48000 -ac 1 -i "tcp://$HOST:$AUDIO_PORT" \
      -af aresample=async=100:min_comp=0.02:first_pts=0 -f s16le - || true
    sleep 1  # the app is closed or not reachable yet; try again
  done | pw-cat --playback --raw --rate 48000 --channels 1 --format s16 --latency 20ms \
    -P '{ media.class=Audio/Source node.name=cleancam-mic node.description=CleanCam node.always-process=true }' - &
else
  echo "pw-cat not found: video only. The CleanCam microphone needs PipeWire." >&2
fi

echo "Writing the CleanCam stream from $HOST:$PORT to $VIDEO and its sound to the CleanCam microphone. Ctrl-C to stop."
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -f h264 -framerate 30 -i "tcp://$HOST:$PORT" \
    -fps_mode passthrough -pix_fmt yuv420p -f v4l2 "$VIDEO" || true
  sleep 1  # the app is closed or not reachable yet; try again
done
