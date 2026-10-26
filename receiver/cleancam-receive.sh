#!/usr/bin/env bash
# Receives the CleanCam stream and shows it as a webcam named "CleanCam" (/dev/video10),
# the phone's microphone as a microphone named "CleanCam", and plays a speaker named "CleanCam" on the phone.
#   cleancam-receive.sh             iPhone on USB (needs usbmuxd running and iproxy)
#   cleancam-receive.sh PHONE_IP    iPhone on the same WiFi
# Needs ffmpeg and the v4l2loopback kernel module; the microphone and the speaker need PipeWire (pw-cli)
# or PulseAudio (pactl and parec).
set -euo pipefail

PORT=${PORT:-5000}                  # TCP port the app sends video on
AUDIO_PORT=${AUDIO_PORT:-5001}      # TCP port the app sends microphone audio on
SPEAKER_PORT=${SPEAKER_PORT:-5002}  # TCP port the app plays speaker audio from
VIDEO_NR=${VIDEO_NR:-10}            # webcam device number: /dev/video$VIDEO_NR
VIDEO=/dev/video$VIDEO_NR
HOST=${1:-}

# Stop what this script started in the background: iproxy, the CleanCam microphone and speaker, and the audio loops.
# PulseAudio keeps the modules it loaded until they are unloaded.
PULSE_MODULES=()
cleanup() {
  pkill -P $$ 2>/dev/null || true
  for module in "${PULSE_MODULES[@]}"; do pactl unload-module "$module" || true; done
}
trap cleanup EXIT

if [[ ! -e $VIDEO ]]; then
  # exclusive_caps=1 lets Chrome and other WebRTC apps list the device as a camera.
  sudo modprobe v4l2loopback video_nr="$VIDEO_NR" card_label=CleanCam exclusive_caps=1
fi

if [[ -z $HOST ]]; then
  if ! command -v iproxy >/dev/null && ! command -v podman >/dev/null && ! command -v docker >/dev/null; then
    echo "iproxy not found: install libusbmuxd's tools, or podman or docker to run it in a container." >&2
    exit 1
  fi
  # iproxy forwards each localhost port to the app's port through the USB cable; tools/iproxy.sh runs it in a
  # container where the host lacks it.
  "$(dirname "$0")/../tools/iproxy.sh" "$PORT:$PORT" "$AUDIO_PORT:$AUDIO_PORT" "$SPEAKER_PORT:$SPEAKER_PORT" \
    >/dev/null &
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

# Loads a PulseAudio module and keeps its number for the cleanup.
pulse_load() {  # MODULE ARGUMENT...
  local module
  if module=$(pactl load-module "$@"); then PULSE_MODULES+=("$module"); fi
}

MIC_FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-mic-$AUDIO_PORT.fifo
SPEAKER_FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-speaker-$SPEAKER_PORT.fifo
# PulseAudio names itself "pulseaudio"; PipeWire's PulseAudio service names itself "PulseAudio (on PipeWire ...)".
if [[ $(pactl info 2>/dev/null || true) == *"Server Name: pulseaudio"* ]]; then
  SOUND=pulseaudio
  # The microphone is a pipe source, which reads the FIFO. The speaker is a null sink, which keeps the system
  # clock's pace, and parec hands its sound on every 10 ms. PulseAudio's pipe sink writes 43 ms at once instead,
  # too coarse for the phone's 80 ms queue, which then cuts and gaps the sound into a buzz.
  rm -f "$MIC_FIFO"  # the pipe source makes the FIFO itself
  pulse_load module-pipe-source source_name=cleancam-mic file="$MIC_FIFO" format=s16le rate=48000 channels=1 \
    channel_map=mono source_properties=device.description=CleanCam
  pulse_load module-null-sink sink_name=cleancam-speaker format=s16le rate=48000 channels=1 channel_map=mono \
    sink_properties=device.description=CleanCam
elif command -v pw-cli >/dev/null; then
  SOUND=pipewire
  pipe_tunnel source "$MIC_FIFO" cleancam-mic
  pipe_tunnel sink "$SPEAKER_FIFO" cleancam-speaker
else
  SOUND=
  echo "Neither PipeWire (pw-cli) nor PulseAudio found: video only." >&2
fi

if [[ $SOUND == pulseaudio ]]; then
  # PulseAudio suspends a source no app records from; the phone's sound then piles up in the FIFO and the TCP buffers
  # and reaches the next app as tens of seconds of old sound. A reader that never stops keeps the microphone live,
  # as always-process does for PipeWire.
  while true; do
    parec -d cleancam-mic --format=s16le --rate=48000 --channels=1 --raw >/dev/null || true
    sleep 1  # the microphone is starting; try again
  done 2>/dev/null &
fi

if [[ $SOUND ]]; then
  while true; do
    # ffmpeg writes whole samples, so a reconnect never shifts the bytes out of order.
    if [[ -p $MIC_FIFO ]]; then
      ffmpeg -hide_banner -loglevel warning \
        -f s16le -ar 48000 -ac 1 -i "tcp://$HOST:$AUDIO_PORT" -f s16le -y "$MIC_FIFO" || true
    fi
    sleep 1  # the app is closed or not reachable yet, or the microphone is starting; try again
  done &
  while true; do
    if [[ $SOUND == pulseaudio ]]; then
      parec -d cleancam-speaker.monitor --latency-msec=10 --format=s16le --rate=48000 --channels=1 --raw \
        >"/dev/tcp/$HOST/$SPEAKER_PORT" || true
    elif [[ -p $SPEAKER_FIFO ]]; then
      # cat passes the sound on as soon as it arrives. The tunnel writes whole samples, so every read is too.
      cat "$SPEAKER_FIFO" 2>/dev/null >"/dev/tcp/$HOST/$SPEAKER_PORT" || true
    fi
    sleep 1  # the app is closed or not reachable yet, or the speaker is starting; try again
  done 2>/dev/null &
fi

# ffmpeg 5.1 renamed -vsync to -fps_mode; older ones, such as ffmpeg 4.4 on RHEL 8, know only -vsync.
FPS_MODE=-vsync
[[ $(ffmpeg -hide_banner -h full 2>/dev/null) == *"-fps_mode"* ]] && FPS_MODE=-fps_mode

MESSAGE="Writing the CleanCam stream from $HOST:$PORT to $VIDEO"
[[ $SOUND ]] && MESSAGE+=", its sound to the CleanCam microphone, and the CleanCam speaker to the phone"
echo "$MESSAGE. Ctrl-C to stop."
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -f h264 -framerate 30 -i "tcp://$HOST:$PORT" \
    "$FPS_MODE" passthrough -pix_fmt yuv420p -f v4l2 "$VIDEO" || true
  sleep 1  # the app is closed or not reachable yet; try again
done
