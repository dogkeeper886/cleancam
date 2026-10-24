# CleanCam

An iPhone's camera beats most webcams. But the Camera app draws a grid, a timer and buttons over the picture, and an HDMI adapter mirrors all of them. A video call then shows the phone's controls on top of the picture.

CleanCam sends only the camera's picture over the USB cable to a Linux PC, where it shows up as a webcam named "CleanCam" in Zoom, OBS or a browser.

## The CleanCam app

CleanCam streams the back camera's own frames instead of the screen, so the PC receives the picture without the phone's overlays.

![On the iPhone, the back camera feeds the CleanCam app, which encodes H.264 at 1920x1080 and 30 fps and serves it on TCP port 5000. Over the USB cable, usbmuxd and iproxy carry the stream to ffmpeg on the Linux PC; over WiFi, ffmpeg reaches the iPhone's IP directly. ffmpeg writes to v4l2loopback's /dev/video10, named CleanCam, which Zoom, OBS or a browser picks as the camera.](docs/images/stream-flow.png)

- **Preview:** the phone shows the picture with a zoom slider, which switches lenses on phones with more than one.
- **Lock:** holds focus, exposure and white balance, so the picture stays steady.
- **Screen off:** blacks out the phone at its lowest brightness while the stream keeps running. Tap the screen to bring it back.
- **Orientation:** the stream follows the phone upright or sideways. Upright frames get black bars, so the webcam stays 1920x1080 and the video app keeps it.
- **Battery:** the app encodes only while a PC is connected.

## Install the app

An iOS app normally comes from the App Store or from Xcode on a Mac, and a Linux PC lacks both. Without them the app stays unbuilt and unsigned, and an iPhone runs only signed apps. GitHub Actions builds the app, and plumesign signs and installs it with a free Apple ID over the USB cable.

![The Build workflow on GitHub builds an unsigned CleanCam.ipa on every push. On the Linux PC: 1, get the IPA; 2, install plumesign. On the iPhone: 3, connect it and tap Trust. On the PC: 4, log in with your Apple ID; 5, sign and install over the USB cable. On the iPhone: 6, trust the developer, after turning on Developer Mode on iOS 16 or later. Then open CleanCam, which runs for 7 days.](docs/images/install-steps.png)

1. **Get the IPA.** GitHub Actions builds an unsigned `CleanCam.ipa` on every push. Download it from the run's `CleanCam-ipa` artifact:
   ```sh
   gh run download <run-id> -n CleanCam-ipa -D build
   ```
   In a fork, enable the workflow in the Actions tab first.
2. **Install plumesign**, Impactor's command-line signer. Put it on `PATH` or set `PLUMESIGN`. `tools/plumesign.sh` runs it natively, or in podman or docker when it needs a newer glibc than the PC has.
3. **Connect the iPhone.** Plug it directly into a port on the PC, since hubs can drop the link. Unlock it and tap "Trust This Computer".
4. **Log in** with your Apple ID. Type the password and 2FA code at the prompts; the password shows as you type.
   ```sh
   tools/plumesign.sh account login -u <your Apple ID>
   ```
5. **Sign and install:**
   ```sh
   tools/plumesign.sh sign --package build/CleanCam.ipa --apple-id --register-and-install --udid "$(idevice_id -l | head -1)"
   ```
6. **Trust it on the iPhone.** On iOS 16 or later, turn on Developer Mode in Settings → Privacy & Security first. Then trust your Apple ID under Settings → General → VPN & Device Management.

The app needs **iOS 15 or later**. A free Apple ID signs it for **7 days**; [Renew after 7 days](#renew-after-7-days) covers what happens then.

## Receive on the PC

`receiver/cleancam-receive.sh` turns the stream into the "CleanCam" webcam. It needs usbmuxd, `iproxy` (libusbmuxd), ffmpeg and the v4l2loopback kernel module.

![On the Linux PC: 1, start the receiver, adding the iPhone's IP for WiFi. On the iPhone: 2, open CleanCam and allow the camera and local network; its status turns to Streaming to PC. On the PC: 3, pick CleanCam in the video app, restarting apps opened earlier. On the iPhone: 4, keep CleanCam open, using Screen off instead of locking.](docs/images/receive-steps.png)

```sh
receiver/cleancam-receive.sh            # iPhone on USB
receiver/cleancam-receive.sh 192.0.2.7  # iPhone on the same WiFi, by its IP
```

Open CleanCam on the iPhone and allow the camera and local network prompts. Its status changes to "Streaming to PC". Then pick "CleanCam" as the camera in the video app, or watch it with `ffplay /dev/video10`.

- **Restart a video app** that opened before the stream; only then does it find the camera.
- **Keep CleanCam open.** iOS stops the camera when the phone locks or the app leaves the screen. Use Screen off instead.

The receiver reads two settings from the environment:

| Variable | Changes | Default |
|---|---|---|
| `PORT` | the TCP port; it must match the app's | `5000` |
| `VIDEO_NR` | the webcam device number, `/dev/video<N>` | `10` |

## Renew after 7 days

A free Apple ID signs CleanCam for 7 days, counted from step 5. When the signing expires, the app stays on the iPhone, but iOS refuses to open it. The webcam goes dark, often right before a call. Running step 5 again signs the app for another 7 days.

![Sign and install on the PC with README step 5. CleanCam then works on the iPhone for 7 days. On day 7 it won't open, while the PC side keeps waiting. Run step 5 again with the same IPA and no rebuild to start over; renewing early restarts the clock. When step 5 fails with a login or session error, log in again with step 4, then run step 5.](docs/images/renew-cycle.png)

- **On day 7:** the icon stays, but tapping it opens nothing or shows an alert. The receiver and the video app keep running and wait for the stream.
- **Renew:** plug the iPhone in and run step 5 again with the same `build/CleanCam.ipa`. Skip the rebuild, and keep the app on the phone.
- **Renew early:** step 5 works on any day before the deadline and restarts the 7 days, so renew before an important call.
- **Log in again** with step 4 when step 5 fails with a login or session error, for example after an Apple ID password change.
- **Trust:** a re-sign with the same Apple ID usually keeps the trust from step 6.
- **Check the deadline** in the signing profile on the iPhone:
  ```sh
  d=$(mktemp -d) && ideviceprovision copy "$d" >/dev/null
  for f in "$d"/*; do openssl smime -inform der -verify -noverify -in "$f" 2>/dev/null | grep -A1 -E '<key>(Name|ExpirationDate)</key>'; done
  ```
- **Sign for a year** with the paid Apple Developer Program ($99 a year), instead of renewing every week.

## Change the app

Change the app from any computer: edit the Swift code in `CleanCam/`, then push. The Build workflow generates the Xcode project from `project.yml` with XcodeGen and compiles it on a GitHub macOS runner. Keep the code within the `deploymentTarget` in `project.yml` (iOS 15), and guard newer APIs with `if #available`.

## Setup details and troubleshooting

`.claude/skills/developing-cleancam/` holds the real-world setup as a Claude Code skill:

- **[`host-setup.md`](.claude/skills/developing-cleancam/reference/host-setup.md):** packages per distribution, how to pick and verify a plumesign release, and the extra steps RHEL 9 family systems need.
- **[`troubleshooting.md`](.claude/skills/developing-cleancam/reference/troubleshooting.md):** symptoms, causes and fixes, from USB hubs and pairing errors to Apple sign-in errors and a missing camera.
