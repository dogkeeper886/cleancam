#!/usr/bin/env bash
# Records the CleanCam microphone, then plays the recording on the CleanCam speaker, so the phone plays back what its
# microphone picked up. Needs the receiver running.
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

need() {  # sources|sinks NAME
  if ! pactl list short "$1" | cut -f2 | grep -qx "$2"; then
    echo "$2 not found: start receiver/cleancam-receive.sh and open CleanCam on the phone first." >&2
    exit 1
  fi
}
need sources cleancam-mic
need sinks cleancam-speaker

if [[ $MODE == record ]]; then
  echo "Recording $DURATION s from the CleanCam microphone: speak now."
  # SIGINT lets parecord finish the WAV header.
  timeout -s INT "$DURATION" parecord -d cleancam-mic --file-format=wav --format=s16le --rate=48000 --channels=1 \
    "$FILE" || true
  echo "Saved $FILE ($(stat -c %s "$FILE") bytes)."
fi

echo "Playing $FILE on the CleanCam speaker."
paplay -d cleancam-speaker "$FILE"
echo "Done. Play it again with: $0 --play $FILE"
