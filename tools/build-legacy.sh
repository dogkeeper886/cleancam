#!/usr/bin/env bash
# Builds CleanCamLegacy, the app for 32-bit iPhones on iOS 10 such as the iPhone 5, into build/CleanCam-legacy.ipa.
# The IPA is unsigned; sign and install it like the main app, with tools/plumesign.sh.
#
# Runs on Linux: clang and Apple's ld64 from the theos project's iOS toolchain run in a container,
# against the iOS 11.4 SDK, the last with 32-bit ARM, which the theos 10.3 SDK's libc stubs lack memset for.
# Both download once into build/legacy-tools.
# Needs podman or docker, curl and zip.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS=build/legacy-tools
SDK=$TOOLS/iPhoneOS11.4.sdk
CLANG=$TOOLS/linux/iphone/bin/clang
APP=build/legacy/Payload/CleanCam.app

# fetch URL SHA256: downloads a .tar.xz, checks it and unpacks it into $TOOLS.
fetch() {
  local file=$TOOLS/${1##*/}
  mkdir -p "$TOOLS"
  curl -fL --retry 3 -o "$file" "$1"
  echo "$2  $file" | sha256sum -c --quiet -
  tar -xJf "$file" -C "$TOOLS"
  rm "$file"
}
[[ -d $SDK ]] || fetch https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS11.4.sdk.tar.xz \
  fb77df55f2478d5d8e069e2686123f2540642128d4c1ad749db3f0b474fae5fb
[[ -x $CLANG ]] || fetch https://github.com/L1ghtmann/llvm-project/releases/download/main-update_3-eabca92/iOSToolchain-x86_64.tar.xz \
  cc9fbc7f8a3f9336f926cd4fb7cc2233a17b2ba40504cc8c0ff3211bd9df27e3

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iOS toolchain runs in a container." >&2
  exit 1
fi
# Run as the calling user so the build output stays theirs.
if [[ $RUNTIME == *podman ]]; then
  USER_OPTS=(--userns=keep-id)
else
  USER_OPTS=(--user "$(id -u):$(id -g)")
fi

rm -rf build/legacy build/CleanCam-legacy.ipa
mkdir -p "$APP"
"$RUNTIME" run --rm --security-opt label=disable "${USER_OPTS[@]}" -v "$PWD:$PWD" -w "$PWD" \
  docker.io/library/ubuntu:24.04 \
  "$CLANG" -target armv7-apple-ios10.0 -isysroot "$SDK" -fobjc-arc -O2 -Wall \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework AVFoundation \
  -framework CoreImage -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework AudioToolbox \
  CleanCamLegacy/*.m -o "$APP/CleanCam"

cp CleanCamLegacy/Info.plist CleanCamLegacy/Default-568h@2x.png "$APP/"
(cd build/legacy && zip -qr ../CleanCam-legacy.ipa Payload)
echo "Built build/CleanCam-legacy.ipa"
