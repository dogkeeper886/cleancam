# CleanCam

An iPhone's camera beats most webcams. But the Camera app draws a grid, a timer and buttons over the picture, and an HDMI adapter mirrors all of them. A video call then shows the phone's controls on top of the picture.

CleanCam sends only the camera's picture over the USB cable to a Linux PC, where it shows up as a webcam named "CleanCam" in Zoom, OBS or a browser.

## The CleanCam app

CleanCam streams the back camera's own frames instead of the screen, so the PC receives the picture without the phone's overlays.

```
iPhone   camera -> CleanCam app (H.264, 1920x1080, 30 fps) -> TCP port 5000
                                     | USB cable
Linux PC usbmuxd -> iproxy -> ffmpeg -> v4l2loopback /dev/video10 "CleanCam" -> Zoom / OBS / browser
```

- **Preview:** the phone shows the picture with a zoom slider, which switches lenses on phones with more than one.
- **Lock:** holds focus, exposure and white balance, so the picture stays steady.
- **Screen off:** blacks out the phone at its lowest brightness while the stream keeps running. Tap the screen to bring it back.
- **Orientation:** the stream follows the phone upright or sideways. Upright frames get black bars, so the webcam stays 1920x1080 and the video app keeps it.
- **Battery:** the app encodes only while a PC is connected.

## Install the app

An iOS app normally comes from the App Store or from Xcode on a Mac, and a Linux PC lacks both. Without them the app stays unbuilt and unsigned, and an iPhone runs only signed apps. GitHub Actions builds the app, and plumesign signs and installs it with a free Apple ID over the USB cable.

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

A free Apple ID signs the app for **7 days**. When it stops opening, repeat step 5. The app needs **iOS 15 or later**.

## Receive on the PC

`receiver/cleancam-receive.sh` turns the stream into the "CleanCam" webcam. It needs usbmuxd, `iproxy` (libusbmuxd), ffmpeg and the v4l2loopback kernel module.

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

## Change the app

Change the app from any computer: edit the Swift code in `CleanCam/`, then push. The Build workflow generates the Xcode project from `project.yml` with XcodeGen and compiles it on a GitHub macOS runner. Keep the code within the `deploymentTarget` in `project.yml` (iOS 15), and guard newer APIs with `if #available`.

## Setup details and troubleshooting

`.claude/skills/developing-cleancam/` holds the real-world setup as a Claude Code skill:

- **[`host-setup.md`](.claude/skills/developing-cleancam/reference/host-setup.md):** packages per distribution, how to pick and verify a plumesign release, and the extra steps RHEL 9 family systems need.
- **[`troubleshooting.md`](.claude/skills/developing-cleancam/reference/troubleshooting.md):** symptoms, causes and fixes, from USB hubs and pairing errors to Apple sign-in errors and a missing camera.
