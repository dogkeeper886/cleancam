#!/usr/bin/env bash
# Receives the CleanCam stream and shows it as a webcam named "CleanCam" (/dev/video10),
# the phone's microphone as a microphone named "CleanCam", and plays a speaker named "CleanCam" on the phone.
#   cleancam-receive.sh             iPhone on USB (needs usbmuxd running and iproxy)
#   cleancam-receive.sh PHONE_IP    iPhone on the same WiFi
# Needs ffmpeg and the v4l2loopback kernel module; the microphone and the speaker need PipeWire (pw-cli)
# or PulseAudio (pactl).
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
  if ! command -v iproxy >/dev/null; then
    echo "iproxy not found: install libusbmuxd's tools, or forward the ports another way and pass 127.0.0.1." >&2
    exit 1
  fi
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

# Loads PulseAudio's pipe module of the same kind: a source reads the FIFO, a sink writes what apps play into it.
# The sink keeps time by the system clock, so it plays at the apps' pace while the phone is away.
pulse_pipe() {  # source|sink FIFO NAME
  local timing=()
  [[ $1 == sink ]] && timing=(use_system_clock_for_timing=yes)
  rm -f "$2"  # PulseAudio makes the FIFO itself
  local module
  if module=$(pactl load-module "module-pipe-$1" "$1_name=$3" file="$2" format=s16le rate=48000 \
      channels=1 channel_map=mono "$1_properties=device.description=CleanCam" "${timing[@]}"); then
    PULSE_MODULES+=("$module")
  fi
}

MIC_FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-mic-$AUDIO_PORT.fifo
SPEAKER_FIFO=${XDG_RUNTIME_DIR:-/tmp}/cleancam-speaker-$SPEAKER_PORT.fifo
SOUND=yes
# PulseAudio names itself "pulseaudio"; PipeWire's PulseAudio service names itself "PulseAudio (on PipeWire ...)".
if [[ $(pactl info 2>/dev/null || true) == *"Server Name: pulseaudio"* ]]; then
  pulse_pipe source "$MIC_FIFO" cleancam-mic
  pulse_pipe sink "$SPEAKER_FIFO" cleancam-speaker
elif command -v pw-cli >/dev/null; then
  pipe_tunnel source "$MIC_FIFO" cleancam-mic
  pipe_tunnel sink "$SPEAKER_FIFO" cleancam-speaker
else
  SOUND=
  echo "Neither PipeWire (pw-cli) nor PulseAudio found: video only." >&2
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
    # cat passes the sound on as soon as it arrives. The sink writes whole samples, so every read is too.
    if [[ -p $SPEAKER_FIFO ]]; then
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
