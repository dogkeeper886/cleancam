#!/usr/bin/env bash
# Builds the current CleanCam code and installs it on the one iPhone on USB, in one run.
# Picks the app by the phone's iOS: iOS 10 gets CleanCamLegacy, built here with tools/build-legacy.sh; iOS 15 or later
# gets CleanCam, which only GitHub Actions builds, from the Build run of the pushed HEAD commit.
# Signs with the Apple ID that `tools/plumesign.sh account login` saved. When a step needs the user, it stops with one
# line naming what to do. Its full output, without plumesign's DEBUG lines and with the Apple ID masked, goes to
# build/deploy.log.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG=build/deploy.log
mkdir -p build
: >"$LOG"

# libimobiledevice 1.3.0 signs pairing certificates with SHA-1, which OpenSSL 3 rejects (see host-setup.md).
CNF=/usr/local/etc/usbmuxd-openssl.cnf
[[ -z ${OPENSSL_CONF:-} && -f $CNF ]] && export OPENSSL_CONF=$CNF

die() { echo "deploy: $*" >&2; exit 1; }
# fail MESSAGE: shows the log's last lines, then dies.
fail() { tail -n 15 "$LOG" >&2; die "$*"; }
# mask: hides the Apple ID's address, so the output can go into a chat.
mask() { sed -E 's/([[:alnum:]._%+-])[[:alnum:]._%+-]*@/\1***@/g'; }

for t in idevice_id idevicepair ideviceinfo ideviceprovision gh; do
  command -v "$t" >/dev/null || die "$t not found: install it from .claude/skills/developing-cleancam/reference/host-setup.md."
done

mapfile -t UDIDS < <(idevice_id -l)
case ${#UDIDS[@]} in
  0) die "No iPhone on USB: plug it straight into the PC, without a hub, unlock it and run again." ;;
  1) UDID=${UDIDS[0]} ;;
  *) die "${#UDIDS[@]} iPhones on USB: unplug all but one and run again." ;;
esac

# pair raises the Trust prompt on the phone, and succeeds once the user has tapped Trust.
if ! idevicepair -u "$UDID" validate >>"$LOG" 2>&1; then
  idevicepair -u "$UDID" pair >>"$LOG" 2>&1 ||
    fail "The iPhone is not paired: unlock it, tap Trust This Computer, enter the passcode and run again."
fi

IOS=$(ideviceinfo -u "$UDID" -k ProductVersion)
MODEL=$(ideviceinfo -u "$UDID" -k ProductType)
MAJOR=${IOS%%.*}
if (( MAJOR == 10 )); then
  APP=CleanCamLegacy BUNDLE=io.github.dogkeeper886.cleancam.legacy TRUST="General → Device Management"
elif (( MAJOR >= 15 )); then
  APP=CleanCam BUNDLE=io.github.dogkeeper886.cleancam TRUST="General → VPN & Device Management"
else
  die "$MODEL on iOS $IOS runs neither app: CleanCamLegacy needs iOS 10, CleanCam iOS 15 or later."
fi

ACCOUNTS=$(tools/plumesign.sh account list </dev/null 2>&1 || true)
grep -q '(selected)' <<<"$ACCOUNTS" ||
  die "No Apple ID saved: log in from your own terminal with: tools/plumesign.sh account login -u <Apple ID>, then run again."

if [[ $APP == CleanCamLegacy ]]; then
  echo "Building CleanCamLegacy for $MODEL on iOS $IOS (log: $LOG)"
  tools/build-legacy.sh >>"$LOG" 2>&1 || fail "tools/build-legacy.sh failed."
  IPA=build/CleanCam-legacy.ipa
  REV=$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- CleanCamLegacy tools/build-legacy.sh || echo +changes)
else
  [[ -z $(git status --porcelain -- CleanCam project.yml) ]] ||
    die "CleanCam/ has uncommitted changes, and only GitHub Actions builds CleanCam: commit and push them, then run again."
  SHA=$(git rev-parse HEAD)
  RUN=$(gh run list --workflow build.yml --commit "$SHA" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [[ -n $RUN ]] ||
    die "No Build run for HEAD ${SHA:0:7}, and only GitHub Actions builds CleanCam: push it, then run again."
  echo "Waiting for Build run $RUN of ${SHA:0:7} for $MODEL on iOS $IOS (log: $LOG)"
  until [[ $(gh run view "$RUN" --json status --jq .status) == completed ]]; do sleep 20; done
  DIR=build/ci-$RUN
  [[ -f $DIR/CleanCam.ipa ]] || gh run download "$RUN" -n CleanCam-ipa -D "$DIR" >>"$LOG" 2>&1 ||
    fail "Build run $RUN has no CleanCam-ipa artifact: see gh run view $RUN --log-failed."
  IPA=$DIR/CleanCam.ipa
  REV=${SHA:0:7}
fi

echo "Signing and installing $IPA"
tools/plumesign.sh sign --package "$IPA" --apple-id --register-and-install --udid "$UDID" </dev/null 2>&1 |
  grep -v DEBUG | mask >>"$LOG" || true
grep -q 'Installation complete' "$LOG" ||
  fail "Signing or installing failed: find the error above in .claude/skills/developing-cleancam/reference/troubleshooting.md."

# The newest expiry among this app's signing profiles on the phone.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ideviceprovision -u "$UDID" copy "$TMP" >>"$LOG" 2>&1 || true
EXPIRES=
for f in "$TMP"/*; do
  p=$(openssl smime -inform der -verify -noverify -in "$f" 2>/dev/null) || continue
  grep -qE "<string>iOS Team Provisioning Profile: ${BUNDLE//./\\.}\.[A-Z0-9]+</string>" <<<"$p" || continue
  e=$(grep -A1 '<key>ExpirationDate</key>' <<<"$p" | sed -n 's|.*<date>\(.*\)</date>.*|\1|p')
  [[ $e > $EXPIRES ]] && EXPIRES=$e
done
EXPIRES=$([[ -n $EXPIRES ]] && date -d "$EXPIRES" '+%Y-%m-%d %H:%M %Z' || echo unknown)

DEVMODE=
(( MAJOR >= 16 )) && DEVMODE=", and turn on Developer Mode in Settings → Privacy & Security"
echo "Installed $APP $REV on $MODEL (iOS $IOS), signed until $EXPIRES."
echo "On the iPhone: open CleanCam. On a first install, trust your Apple ID in Settings → $TRUST first$DEVMODE."
