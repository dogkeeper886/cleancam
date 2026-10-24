#!/usr/bin/env bash
# Receives the CleanCam stream and shows it as a webcam named "CleanCam" (/dev/video10),
# the phone's microphone as a microphone named "CleanCam", and plays a speaker named "CleanCam" on the phone.
#   cleancam-receive.sh             iPhone on USB (needs usbmuxd running and iproxy)
#   cleancam-receive.sh PHONE_IP    iPhone on the same WiFi
# Needs ffmpeg and the v4l2loopback kernel module; the microphone and the speaker need PipeWire (pw-cli).
set -euo pipefail

PORT=${PORT:-5000}                  # TCP port the app sends video on
AUDIO_PORT=${AUDIO_PORT:-5001}      # TCP port the app sends microphone audio on
SPEAKER_PORT=${SPEAKER_PORT:-5002}  # TCP port the app plays speaker audio from
VIDEO_NR=${VIDEO_NR:-10}            # webcam device number: /dev/video$VIDEO_NR
VIDEO=/dev/video$VIDEO_NR
HOST=${1:-}

# Stop what this script started in the background: iproxy, the CleanCam microphone and speaker, and the audio loops.
trap 'pkill -P $$ 2>/dev/null' EXIT

if [[ ! -e $VIDEO ]]; then
  # exclusive_caps=1 lets Chrome and other WebRTC apps list the device as a camera.
  sudo modprobe v4l2loopback video_nr="$VIDEO_NR" card_label=CleanCam exclusive_caps=1
fi

if [[ -z $HOST ]]; then
  # iproxy forwards each localhost port to the app's port through the USB cable.
  iproxy "$PORT:$PORT" "$AUDIO_PORT:$AUDIO_PORT" "$SPEAKER_PORT:$SPEAKER_PORT" >/dev/null &
  HOST=127.0.0.1
fi

# Loads PipeWire's pipe-tunnel module: a device named "CleanCam" that exchanges raw audio through a FIFO.
# A source (microphone) reads the FIFO, playing silence while nothing arrives and matching its rate to the phone's clock;
# a sink (speaker) writes what apps play into it. always-process keeps the device running while no app uses it,
# so audio never piles up.
pipe_tunnel() {  # MODE FIFO NODE_NAME
  pw-cli -m load-module libpipewire-module-pipe-tunnel "{ tunnel.mode = $1 pipe.filename = \"$2\"
    audio.format = S16LE audio.rate = 48000 audio.channels = 1 audio.position = [ MONO ]
    stream.props = { node.name = $3 node.description = CleanCam node.always-process = true } }" >/dev/null &
}

if command -v pw-cli >/dev/null; then
  MIC_FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-mic-$AUDIO_PORT.fifo
  SPEAKER_FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-speaker-$SPEAKER_PORT.fifo
  pipe_tunnel source "$MIC_FIFO" cleancam-mic
  pipe_tunnel sink "$SPEAKER_FIFO" cleancam-speaker
  while true; do
    # ffmpeg writes whole samples, so a reconnect never shifts the bytes out of order.
    if [[ -p $MIC_FIFO ]]; then
      ffmpeg -hide_banner -loglevel warning \
        -f s16le -ar 48000 -ac 1 -i "tcp://$HOST:$AUDIO_PORT" -f s16le -y "$MIC_FIFO" || true
    fi
    sleep 1  # the app is closed or not reachable yet, or the microphone is starting; try again
  done &
  while true; do
    # cat passes the sound on as soon as it arrives. The tunnel writes whole samples, so every read is too.
    if [[ -p $SPEAKER_FIFO ]]; then
      cat "$SPEAKER_FIFO" 2>/dev/null >"/dev/tcp/$HOST/$SPEAKER_PORT" || true
    fi
    sleep 1  # the app is closed or not reachable yet, or the speaker is starting; try again
  done 2>/dev/null &
else
  echo "pw-cli not found: video only. The CleanCam microphone and speaker need PipeWire." >&2
fi

echo "Writing the CleanCam stream from $HOST:$PORT to $VIDEO, its sound to the CleanCam microphone," \
  "and the CleanCam speaker to the phone. Ctrl-C to stop."
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -f h264 -framerate 30 -i "tcp://$HOST:$PORT" \
    -fps_mode passthrough -pix_fmt yuv420p -f v4l2 "$VIDEO" || true
  sleep 1  # the app is closed or not reachable yet; try again
done
