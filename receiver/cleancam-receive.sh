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
# so audio never piles up. node.latency holds PipeWire's cycle at 512 samples, so the speaker writes its sound in
# 10.7 ms pieces; an app that asks for 100 ms, as pw-play does, otherwise makes it 43 ms pieces, too coarse for the
# phone's 80 ms queue, which then cuts the sound into a buzz.
pipe_tunnel() {  # MODE FIFO NODE_NAME
  pw-cli -m load-module libpipewire-module-pipe-tunnel "{ tunnel.mode = $1 pipe.filename = \"$2\"
    audio.format = S16LE audio.rate = 48000 audio.channels = 1 audio.position = [ MONO ]
    stream.props = { node.name = $3 node.description = CleanCam node.always-process = true
      node.latency = 512/48000 } }" >/dev/null &
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

# Sends standard input to the phone's speaker port as it arrives. bash's /dev/tcp leaves Nagle's algorithm on, which
# holds each 10 ms write until the previous one is acknowledged, so the sound reached the phone in 40 ms clumps and
# stuttered; python3 turns it off. Without python3, /dev/tcp still plays, with the stutter.
send_speaker() {
  if command -v python3 >/dev/null; then
    python3 -I -c '
import socket, sys
connection = socket.create_connection((sys.argv[1], int(sys.argv[2])))
connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
read = sys.stdin.buffer.raw.read
while True:
    data = read(65536)
    if not data:
        break
    connection.sendall(data)
' "$HOST" "$SPEAKER_PORT"
  else
    cat >"/dev/tcp/$HOST/$SPEAKER_PORT"
  fi
}

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
        | send_speaker || true
    elif [[ -p $SPEAKER_FIFO ]]; then
      # The tunnel writes whole samples, so every read is too.
      send_speaker <"$SPEAKER_FIFO" || true
    fi
    sleep 1  # the app is closed or not reachable yet, or the speaker is starting; try again
  done 2>/dev/null &
fi

# ffmpeg 5.1 renamed -vsync to -fps_mode; older ones, such as ffmpeg 4.4 on RHEL 8, know only -vsync.
FPS_MODE=-vsync
[[ $(ffmpeg -hide_banner -h full 2>/dev/null) == *"-fps_mode"* ]] && FPS_MODE=-fps_mode

# The phone's H.264 names no frame rate. ffmpeg 6.0 and older take it from -framerate, but 6.1 (libavformat 60.16) and
# newer give each frame 1 tick of 1/1200000 s, so every frame lands on timestamp 0 and ffmpeg warns on each one.
# -r on the input spaces the frames at the frame rate again.
FRAME_RATE=(-framerate 30)
LAVF_VERSION='libavformat +([0-9]+)\. *([0-9]+)'
if [[ $(ffmpeg -hide_banner -version 2>/dev/null) =~ $LAVF_VERSION ]] &&
  (( BASH_REMATCH[1] > 60 || (BASH_REMATCH[1] == 60 && BASH_REMATCH[2] >= 16) )); then
  FRAME_RATE+=(-r 30)
fi

MESSAGE="Writing the CleanCam stream from $HOST:$PORT to $VIDEO"
[[ $SOUND ]] && MESSAGE+=", its sound to the CleanCam microphone, and the CleanCam speaker to the phone"
echo "$MESSAGE. Ctrl-C to stop."
while true; do
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -f h264 "${FRAME_RATE[@]}" -i "tcp://$HOST:$PORT" \
    "$FPS_MODE" passthrough -pix_fmt yuv420p -f v4l2 "$VIDEO" || true
  sleep 1  # the app is closed or not reachable yet; try again
done
