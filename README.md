# CleanCam

An iPhone's camera beats most webcams. But the Camera app draws a grid, a timer and buttons over the picture, and an HDMI adapter mirrors all of them. A video call then shows the phone's controls on top of the picture.

CleanCam sends only the camera's picture and the iPhone's microphone over the USB cable to a Linux PC, and plays the call's sound on the iPhone's loudspeaker. The PC shows them as a webcam, a microphone and a speaker, all named "CleanCam", in Zoom, OBS or a browser.

## The CleanCam app

CleanCam streams the back camera's frames instead of the screen, so the PC receives the clean picture.

![On the iPhone, the back camera and the microphone feed the CleanCam app, which encodes the video as H.264, or HEVC in the WiFi preset, at 1920x1080, 15 to 60 fps by the preset and up to 20 Mbps, converts the microphone to 48 kHz mono PCM, and serves them on TCP ports 5000 and 5001; on port 5002 it takes the PC's speaker sound and plays it on the loudspeaker. The USB cable, through usbmuxd and iproxy, carries all three ports both ways; over WiFi, the PC reaches the iPhone's IP directly. On the Linux PC, one ffmpeg decodes the video into v4l2loopback's /dev/video10, named CleanCam; another copies the microphone into a PipeWire or PulseAudio pipe source, the CleanCam microphone; and cat or parec passes what apps play on the CleanCam speaker back to the phone. Zoom, OBS or a browser picks CleanCam as the camera, the microphone and the speaker.](docs/images/stream-flow.png)

- **Preview:** the phone shows the picture with a zoom slider, which switches lenses on phones with more than one. The zoom label turns yellow where the camera starts to upscale.
- **Focus:** focus and exposure follow the largest face, or the center while no face shows. Tap the preview to hold them on a point; a long press hands them back.
- **Lock:** holds focus, exposure and white balance, so the picture stays steady.
- **Presets:** the settings button picks what you stream for, and the app keeps the choice. **Call**, the default, runs at 20–30 fps for Zoom, Meet and Teams, which send 30. **Low light** runs at 15–30 fps for a brighter face in the dark. **OBS** runs at 30–60 fps for apps that keep every frame, on a phone with a 60 fps mode. **WiFi** runs at 20–30 fps in HEVC, which carries a better picture in the same 10 Mbps, on a phone with an HEVC encoder. Switching to or from WiFi pauses the webcam for about a second while the receiver connects again.
- **Low light:** in a dark room the camera slows toward the bottom of its preset's frame rates for more light per frame, and turns on low-light boost where the phone has it.
- **Bitrate:** the video starts at 10 Mbps, or 20 Mbps at 60 fps, steps down while the PC falls behind, as on a weak WiFi link, and climbs back once it keeps up.
- **Status:** a second line names the preset, the camera mode, HEVC when the WiFi preset sends it, the frame rate, the bitrate and what focus follows, such as `Call · 1080p · 30 fps · 10.0 Mbps · Face`.
- **Mute:** stops sending the microphone; the PC's CleanCam microphone goes silent. The button appears once the microphone is allowed.
- **Speaker:** the loudspeaker plays whatever the video app sends to the CleanCam speaker, at the loudness the phone's volume buttons set.
- **Echo cancellation:** the iPhone removes its loudspeaker's sound from the microphone, as in a phone call, so the others hear only you. Your voice sounds like a phone call too.
- **Screen off:** blacks out the phone at its lowest brightness while the stream keeps running. Tap the screen to bring it back.
- **Orientation:** the stream follows the phone upright or sideways. Upright frames get black bars, so the webcam stays 1920x1080 and the video app keeps it.
- **Battery:** the app encodes only while a PC is connected.

## Install the app

An iOS app normally comes from the App Store or from Xcode on a Mac, and a Linux PC lacks both. The app then stays unbuilt and unsigned, and an iPhone runs only signed apps. GitHub Actions builds the app, and plumesign signs and installs it with a free Apple ID over the USB cable.

![The Build workflow on GitHub builds an unsigned CleanCam.ipa on every push and publishes it with each release. On the Linux PC: 1, get the IPA with gh release download; 2, install plumesign. On the iPhone: 3, connect it and tap Trust. On the PC: 4, log in with your Apple ID; 5, sign and install over the USB cable. On the iPhone: 6, trust the developer, after turning on Developer Mode on iOS 16 or later. Then open CleanCam, which runs for 7 days.](docs/images/install-steps.png)

1. **Get the IPA.** Download the unsigned `CleanCam.ipa` from the [latest release](https://github.com/dogkeeper886/cleancam/releases/latest):
   ```sh
   gh release download -R dogkeeper886/cleancam -p CleanCam.ipa -D build --clobber
   ```
   GitHub Actions also builds it on every push. For a commit after the release, download the run's `CleanCam-ipa` artifact with `gh run download <run-id> -n CleanCam-ipa -D build`. In a fork, enable the workflow in the Actions tab first.
2. **Install plumesign**, Impactor's command-line signer. Put it on `PATH` or set `PLUMESIGN`. `tools/plumesign.sh` runs it natively, or in podman or docker when it needs a newer glibc than the PC has.
3. **Connect the iPhone.** Plug it directly into the PC, since hubs can drop the link. Unlock it and tap "Trust This Computer".
4. **Log in** with your Apple ID. Type the password and 2FA code at the prompts; the password shows as you type.
   ```sh
   tools/plumesign.sh account login -u <your Apple ID>
   ```
5. **Sign and install:**
   ```sh
   tools/plumesign.sh sign --package build/CleanCam.ipa --apple-id --register-and-install --udid "$(idevice_id -l | head -1)"
   ```
6. **Trust it on the iPhone.** On iOS 16 or later, turn on Developer Mode in Settings → Privacy & Security first. Then trust your Apple ID under Settings → General → VPN & Device Management.

The app needs **iOS 15 or later**; an iPhone 5 or 5c on iOS 10 runs [CleanCamLegacy](#iphone-5-and-5c) instead. A free Apple ID signs it for **7 days**; [Renew after 7 days](#renew-after-7-days) covers what happens then.

These phones were tested by hand over the USB cable, with the video, the microphone and the speaker in a video call:

| Phone | iOS | App | PC |
|---|---|---|---|
| iPhone 5 | 10.3.4 | CleanCamLegacy | Rocky Linux 9 with PipeWire, and Rocky Linux 8.10 with PulseAudio |
| iPhone 7 | 15.8.8 | CleanCam | Rocky Linux 9 with PipeWire |
| iPhone X | 16.7.16 | CleanCam | Rocky Linux 9 with PipeWire |

| PC | Sound server | ffmpeg |
|---|---|---|
| Rocky Linux 9, minor release not recorded | PipeWire, version not recorded | 5.1 or later, version not recorded |
| Rocky Linux 8.10 | PulseAudio 14.0 | 4.4.8 |

Other distributions and versions are untested. [`host-setup.md`](.claude/skills/developing-cleancam/reference/host-setup.md) lists every package version on the Rocky Linux 8.10 PC.

## Receive on the PC

`receiver/cleancam-receive.sh` turns the stream into the "CleanCam" webcam, microphone and speaker. It needs usbmuxd, `iproxy` (libusbmuxd) or podman or docker to run it in a container, ffmpeg, which detects H.264 or HEVC, and the v4l2loopback kernel module. The microphone and the speaker also need PipeWire as the sound server with `pw-cli`, or PulseAudio with `pactl` and `parec`; on another sound server, the receiver runs video only. The speaker plays smoothly with `python3`, which sends its sound in even 10 ms pieces.

![On the Linux PC: 1, start the receiver, adding the iPhone's IP for WiFi. On the iPhone: 2, open CleanCam and allow its permission prompts; its status turns to Streaming to PC. On the PC: 3, pick CleanCam as the camera, the microphone and the speaker in the video app. On the iPhone: 4, keep CleanCam open, using Screen off instead of locking.](docs/images/receive-steps.png)

```sh
receiver/cleancam-receive.sh            # iPhone on USB
receiver/cleancam-receive.sh 192.0.2.7  # iPhone on the same WiFi, by its IP
```

Open CleanCam on the iPhone and allow the camera, microphone and local network prompts. Its status changes to "Streaming to PC". Then pick "CleanCam" as the camera, the microphone and the speaker in the video app, or watch the picture with `ffplay /dev/video10`.

- **Restart a video app** that opened before the stream; only then does it find the camera.
- **Pick the CleanCam speaker with the CleanCam microphone.** The iPhone cancels only its own loudspeaker's echo; to hear the call on the PC instead, wear headphones.
- **Keep CleanCam open.** iOS stops the camera when the phone locks or the app leaves the screen. Use Screen off instead.
- **Mirrored preview:** Zoom mirrors your own preview, so the picture looks flipped to you but reaches the others the right way round. Turn off Settings → Video → "Mirror my video" to see what they see.
- **Check the sound:** `tools/mic-check.sh` records 5 s from the CleanCam microphone and plays it on the CleanCam speaker, so the phone plays back what its microphone heard.
- **Debug the stream:** `nc 127.0.0.1 5003`, or the phone's IP over WiFi, prints one JSON line a second from the app: the frame rate, the target bitrate, the bits the encoder sent, the most sends a viewer had waiting, and the viewers per port. It adds a line for each event, such as the preset and its camera mode, the rate settings and what the encoder took of them, or a step down or up. Type `bitrate 10000000` to hold the bitrate, up to 100 Mbps, `auto` to hand it back to adaptation, `keyframe` for a keyframe, or `preset call`, `preset lowlight`, `preset obs` or `preset wifi` to switch the preset as the settings sheet does.

The receiver reads five settings from the environment:

| Variable | Changes | Default |
|---|---|---|
| `PORT` | the TCP port for video; it must match the app's | `5000` |
| `AUDIO_PORT` | the TCP port for the microphone; it must match the app's | `5001` |
| `SPEAKER_PORT` | the TCP port for the speaker; it must match the app's | `5002` |
| `DEBUG_PORT` | the TCP port the receiver forwards to the app's debug port over USB; it must match the app's | `5003` |
| `VIDEO_NR` | the webcam device number, `/dev/video<N>` | `10` |

## Renew after 7 days

A free Apple ID signs CleanCam for 7 days, counted from step 5. Once the 7 days pass, the app stays on the iPhone, but iOS refuses to open it. The webcam goes dark, often right before a call. Run step 5 again to sign the app for another 7 days.

![Sign and install on the PC with README step 5. CleanCam then works on the iPhone for 7 days. On day 7 it won't open, while the PC side keeps waiting. Run step 5 again with the same IPA and no rebuild to start over; renewing early restarts the clock. When step 5 fails with a login or session error, log in again with step 4, then run step 5.](docs/images/renew-cycle.png)

- **On day 7:** the icon stays, but tapping it leaves you on the home screen or shows an alert. The receiver and the video app keep running and wait for the stream.
- **Renew:** plug the iPhone in and run step 5 again with the same `build/CleanCam.ipa`. Keep the app on the phone.
- **Renew early:** step 5 works on any day before the deadline and restarts the 7 days, so renew before an important call.
- **Log in again** with step 4 when step 5 fails with a login or session error, for example after you change your Apple ID password.
- **Trust:** when you sign again with the same Apple ID, the iPhone usually still trusts it from step 6.
- **Check the deadline** in the signing profile on the iPhone:
  ```sh
  d=$(mktemp -d) && ideviceprovision copy "$d" >/dev/null
  for f in "$d"/*; do openssl smime -inform der -verify -noverify -in "$f" 2>/dev/null | grep -A1 -E '<key>(Name|ExpirationDate)</key>'; done
  ```
- **Sign for a year** with the paid Apple Developer Program ($99 a year), instead of renewing every week.

## iPhone 5 and 5c

The app needs iOS 15, but a 32-bit iPhone such as the iPhone 5 stops at iOS 10. Xcode dropped 32-bit apps years ago, and the Xcode on GitHub's macOS runners is too new to build one. `CleanCamLegacy/` is a second app for these phones, written in Objective-C for iOS 10. It has the same controls except the presets, and the same ports and stream formats, so the receiver stays as it is, and it builds on Linux, in GitHub Actions or on your PC.

![The Build workflow on GitHub builds an unsigned CleanCam-legacy.ipa on every push and publishes it with each release. On the Linux PC: 1, get the IPA with gh release download, or build it with tools/build-legacy.sh. On the iPhone 5 on iOS 10: 2, connect only this iPhone, plugged in directly, and tap Trust. On the PC: 3, sign and install CleanCam-legacy.ipa with plumesign. On the iPhone: 4, trust the developer under Device Management, with no Developer Mode. Then open CleanCam, which runs for 7 days.](docs/images/legacy-steps.png)

1. **Get the IPA.** Download the unsigned `CleanCam-legacy.ipa` from the [latest release](https://github.com/dogkeeper886/cleancam/releases/latest):
   ```sh
   gh release download -R dogkeeper886/cleancam -p CleanCam-legacy.ipa -D build --clobber
   ```
   Or build it yourself. The first time it runs, `tools/build-legacy.sh` downloads the iOS 11.4 SDK and the theos project's iOS toolchain, checks them against pinned checksums, compiles in podman or docker, and writes `build/CleanCam-legacy.ipa`:
   ```sh
   tools/build-legacy.sh
   ```
2. **Connect only this iPhone**, straight into the PC. Unlock it and tap "Trust This Computer". With one phone plugged in, the next step and the receiver pick it.
3. **Sign and install** with the Apple ID from step 4 of [Install the app](#install-the-app):
   ```sh
   tools/plumesign.sh sign --package build/CleanCam-legacy.ipa --apple-id --register-and-install --udid "$(idevice_id -l | head -1)"
   ```
4. **Trust the developer** under Settings → General → Device Management. On iOS 10, this trust is the only setting.

Then open CleanCam, allow the camera and microphone prompts, and [receive on the PC](#receive-on-the-pc) as with the main app. iOS 10 asks for only these two.

- **Renew** every 7 days with step 3 and the same IPA.
- **iPhone 5s, 6 and 6 Plus** fall between the two apps: they stop at iOS 12, which runs only 64-bit apps, while the main app needs iOS 15.

## Change the app

Change the app from any computer: edit the Swift code in `CleanCam/`, then push. The Build workflow generates the Xcode project from `project.yml` with XcodeGen and compiles it on a GitHub macOS runner. Keep the code within the `deploymentTarget` in `project.yml` (iOS 15), and guard newer APIs with `if #available`.

CleanCamLegacy builds on Linux instead: edit the Objective-C code in `CleanCamLegacy/`, build it with `tools/build-legacy.sh`, and install it with step 3 of [iPhone 5 and 5c](#iphone-5-and-5c). The Build workflow also builds it on a GitHub Linux runner on every push. Keep it within iOS 10's APIs; clang warns about newer ones. When you change the Swift app, port the change to `CleanCamLegacy/` too, so the iPhone 5 gets it.

Publish a release by pushing a `v*` tag, such as `v0.2.0`. The Build workflow attaches both IPAs and their SHA-256 sums to it. Raise the version in `project.yml` and `CleanCamLegacy/Info.plist` first.

## Setup details and troubleshooting

`.claude/skills/developing-cleancam/` is a Claude Code skill that sets up the iPhone, the PC and the signer, and `.claude/skills/developing-cleancam-legacy/` sets up the iPhone 5 the same way. Both use these reference files:

- **[`host-setup.md`](.claude/skills/developing-cleancam/reference/host-setup.md):** packages per distribution, how to pick and verify a plumesign release, and the extra steps RHEL 8 and 9 family systems need.
- **[`troubleshooting.md`](.claude/skills/developing-cleancam/reference/troubleshooting.md):** symptoms, causes and fixes, from USB hubs and pairing errors to Apple sign-in errors, iPhone 5 build errors and a missing camera.
