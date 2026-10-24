# Troubleshooting

Find the symptom, apply the fix, then resume at the step that failed.

| Symptom | Cause | Fix |
|---|---|---|
| No CI run appears after a push to a fork | GitHub disables workflows on new forks | Enable them in the fork's Actions tab, then push again |
| `command -v` misses `iproxy`, `idevice_id` or `idevicepair` | libusbmuxd or libimobiledevice tools are not installed | Install them from `host-setup.md` |
| `idevice_id -l` is empty; usbmuxd logs `RX aborted due to error or disconnect` | The iPhone is behind a USB hub, often the front-panel ports | Plug it straight into the PC |
| `Pair failed ... lockdown error -5`, or `idevicepair` returns `-5` | libimobiledevice 1.3.0 signs pairing certificates with SHA-1, which OpenSSL 3 rejects | Run usbmuxd and the idevice tools with the OpenSSL setting in `host-setup.md` |
| `idevicepair`: "a passcode is set" | The iPhone is locked | Unlock it and tap Trust |
| A Flatpak signer such as Impactor shows No Device while `idevice_id -l` lists the iPhone | The app holds the `/run/usbmuxd` socket from before usbmuxd restarted | Restart the app; keep usbmuxd running as in `host-setup.md` |
| `GLIBC_2.38 not found` | The plumesign build needs a newer glibc than the host | `tools/plumesign.sh` runs it in a container once podman or docker is installed |
| `plumesign not found` | No binary on PATH and `PLUMESIGN` unset | Install plumesign from `host-setup.md` |
| Signing fails with an authentication or session error although `account list` shows the Apple ID | The saved session expired, or the password changed | Ask the user to log in again from their own terminal |
| Sign-in: `Plist error: Serde("invalid type: string \"<html>\", expected a map")` | Apple answers 503 to the Android identity plumesign 2.7.0 sends | Use plumesign 2.7.1 or later |
| Sign-in: `Authentication SRP error -80046` after the 2FA code | Apple rejects the anisette data from the default server | Point plumesign at a Mac anisette server with `tools/plumesign.sh anisette server --set https://mac-ani.jkcoxson.com`; on builds without that command, use a build whose default is Mac anisette (see `host-setup.md`) |
| Sign-in: `Anisette error: ... EndProvisioningError` | The anisette server failed provisioning | Retry later, or set another server as above |
| `Device ID <udid> not found` | Upstream plumesign matches `--udid` against usbmuxd's numeric device number, not the UDID | Pass the number instead: `1` for the first iPhone usbmuxd saw since it started |
| Install fails because the app needs a newer iOS | `deploymentTarget` is above the phone's iOS | Read the phone's iOS with `ideviceinfo -k ProductVersion`, lower `deploymentTarget` in `project.yml`, and rebuild |
| The app won't open: "Untrusted Developer" | First install from this Apple ID | Settings → General → VPN & Device Management → Trust |
| The app stopped opening after about a week | Free Apple ID signing lasts 7 days | Reinstall with step 13 of `SKILL.md` |
| The video app lists no "CleanCam" camera | `exclusive_caps=1` lists the device only while ffmpeg writes to it | Start the receiver and the app, then restart the video app |
| The video app lists no "CleanCam" microphone | The receiver is not running, or it printed `pw-cli not found` | Start the receiver; install PipeWire's tools from `host-setup.md` |
| The "CleanCam" microphone stays silent and the app shows no Mute button | The user denied the microphone prompt | Ask the user to allow it in Settings → CleanCam → Microphone, then reopen the app |
| The picture looks left-right flipped in the video app | The video app mirrors the user's own preview; the other side sees it the right way round | Turn off the app's mirroring, in Zoom Settings → Video → "Mirror my video" |
| The phone stays on "Waiting for PC on port …" | The receiver is not running, or the iPhone is not paired | Start `receiver/cleancam-receive.sh`; check `idevicepair validate` |
| The receiver prints `Non-monotonic DTS` | The raw H.264 stream carries no timestamps | Harmless |
