#!/usr/bin/env bash
# Runs plumesign (Impactor's command-line signer) against the iPhone on USB, natively when the host can run it,
# otherwise in a container: upstream Linux builds need glibc 2.38+.
#   PLUMESIGN        plumesign binary (default: `plumesign` on PATH)
#   PLUMESIGN_HOME   Apple ID session for container runs (default: ~/.local/share/cleancam/plumesign);
#                    native runs keep it in ~/.config/PlumeImpactor
#   PLUMESIGN_IMAGE  container image with glibc 2.38+ (default: docker.io/library/ubuntu:24.04)
# Paths under the current directory, such as build/CleanCam.ipa, work the same in both modes.
set -euo pipefail

BIN=${PLUMESIGN:-$(command -v plumesign || true)}
if [[ -z $BIN || ! -x $BIN ]]; then
  echo "plumesign not found: put it on PATH or set PLUMESIGN=/path/to/plumesign" \
    "(see .claude/skills/developing-cleancam/reference/host-setup.md)." >&2
  exit 1
fi
BIN=$(readlink -f "$BIN")

if "$BIN" --version >/dev/null 2>&1; then
  exec "$BIN" "$@"
fi

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "This host cannot run plumesign directly (it needs glibc 2.38+); install podman or docker to run it in a container." >&2
  exit 1
fi

DATA=${PLUMESIGN_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cleancam/plumesign}
mkdir -p "$DATA"

CA=
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [[ -f $f ]] && { CA=$f; break; }
done
if [[ -z $CA ]]; then
  echo "No CA certificate bundle found; plumesign needs one to reach Apple." >&2
  exit 1
fi

# Run as the calling user so the session files stay theirs.
if [[ $RUNTIME == *podman ]]; then
  USER_OPTS=(--userns=keep-id)
else
  USER_OPTS=(--user "$(id -u):$(id -g)")
fi
TTY=()
[[ -t 0 ]] && TTY=(-t)

# label=disable lets the container reach the usbmuxd socket on SELinux hosts.
exec "$RUNTIME" run --rm -i "${TTY[@]}" --security-opt label=disable "${USER_OPTS[@]}" \
  -e HOME=/data -v "$DATA:/data" \
  -v /run/usbmuxd:/run/usbmuxd \
  -v "$BIN:/usr/local/bin/plumesign:ro" \
  -v "$CA:/etc/ssl/certs/ca-certificates.crt:ro" \
  -v "$PWD:$PWD:ro" -w "$PWD" \
  "${PLUMESIGN_IMAGE:-docker.io/library/ubuntu:24.04}" plumesign "$@"
