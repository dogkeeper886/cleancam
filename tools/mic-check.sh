#!/usr/bin/env bash
# Records the CleanCam microphone, then plays the recording on the CleanCam speaker, so the phone plays back what its
# microphone picked up. Needs the receiver running, and the sound server's tools: PulseAudio's pactl, parecord and
# paplay, or PipeWire's pw-cli, pw-record and pw-play.
#   tools/mic-check.sh [SECONDS] [FILE]    default: 5 s into $XDG_RUNTIME_DIR/cleancam-mic-check.wav
#   tools/mic-check.sh --play [FILE]       plays an earlier recording again
set -euo pipefail

if [[ ${1:-} == --play ]]; then
  MODE=play
  shift
else
  MODE=record
  DURATION=${1:-5}
  shift || true
fi
FILE=${1:-${XDG_RUNTIME_DIR:-/tmp}/cleancam-mic-check.wav}

# Picks the sound server as the receiver does. PulseAudio names itself "pulseaudio"; PipeWire's PulseAudio service
# names itself "PulseAudio (on PipeWire ...)".
if [[ $(pactl info 2>/dev/null || true) == *"Server Name: pulseaudio"* ]]; then
  SOUND=pulseaudio
elif command -v pw-cli >/dev/null; then
  SOUND=pipewire
else
  echo "Neither PipeWire (pw-cli) nor PulseAudio (pactl) found." >&2
  exit 1
fi

need() {  # sources|sinks NAME
  if [[ $SOUND == pulseaudio ]]; then
    pactl list short "$1" | cut -f2 | grep -qx "$2" && return
  else
    [[ $(pw-cli ls Node 2>/dev/null) == *"node.name = \"$2\""* ]] && return
  fi
  echo "$2 not found: start receiver/cleancam-receive.sh and open CleanCam on the phone first." >&2
  exit 1
}
need sources cleancam-mic
need sinks cleancam-speaker

if [[ $MODE == record ]]; then
  echo "Recording $DURATION s from the CleanCam microphone: speak now."
  # SIGINT lets parecord and pw-record finish the WAV header.
  if [[ $SOUND == pulseaudio ]]; then
    timeout -s INT "$DURATION" parecord -d cleancam-mic --file-format=wav --format=s16le --rate=48000 --channels=1 \
      "$FILE" || true
  else
    timeout -s INT "$DURATION" pw-record --target cleancam-mic --rate 48000 --channels 1 --format s16 "$FILE" || true
  fi
  echo "Saved $FILE ($(stat -c %s "$FILE") bytes)."
fi

echo "Playing $FILE on the CleanCam speaker."
if [[ $SOUND == pulseaudio ]]; then
  paplay -d cleancam-speaker "$FILE"
else
  pw-play --target cleancam-speaker "$FILE"
fi
echo "Done. Play it again with: $0 --play $FILE"
