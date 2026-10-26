---
description: >-
  An agent sets up CleanCam on a real iPhone and Linux PC by its own ideas.
  The repo holds the code, but not the world around it: the cable, the
  pairing, the Apple ID signer, the trust prompts, the 7-day expiry and the
  webcam receiver. A guessed step leaves an app the phone refuses, a sign-in
  Apple rejects, or a camera the video app never lists. This skill asks the
  agent to set up, run and renew that environment by the steps below.
---

Set up CleanCam on a real iPhone and Linux PC:
1. Confirm the user has an iPhone, its USB cable and a Linux PC; CleanCam needs no Mac.
2. Use the USB or WiFi stream for the clean picture, since an HDMI adapter mirrors the phone screen with its buttons.
3. Switch to the `developing-cleancam-legacy` skill for a 32-bit iPhone on iOS 10, such as the iPhone 5 (Settings → General → About), since this app needs iOS 15.
4. Sign with the user's free Apple ID through plumesign, since TestFlight needs a paid Apple Developer account and an App Store Connect upload that this repo does not do.
5. Set up the PC's tools from `reference/host-setup.md`.
6. Ask the user to plug the iPhone straight into the PC, without a hub, and unlock it.
7. Ask the user to tap "Trust This Computer" and enter the passcode.
8. Confirm the pairing with `idevicepair validate`.
9. Install a plumesign build that passes Apple sign-in, using the patched fork from `reference/host-setup.md` when upstream fails.
10. Ask the user to log in from their own terminal with `tools/plumesign.sh account login -u <their Apple ID>`, keeping the password and 2FA code out of the chat.
11. Leave the login's output and any container log unread, since plumesign echoes the password.
12. Fetch `CleanCam.ipa` from the latest release with `gh release download -R dogkeeper886/cleancam -p CleanCam.ipa -D build`, or from the `CleanCam-ipa` artifact of a GitHub Actions run for an unreleased commit, since only macOS can build it.
13. Sign and install with `tools/plumesign.sh sign --package build/CleanCam.ipa --apple-id --register-and-install --udid "$(idevice_id -l | head -1)" < /dev/null 2>&1 | grep -v DEBUG | tail -5`.
14. On iOS 16 or later, ask the user to turn on Developer Mode in Settings → Privacy & Security and restart the phone.
15. On a first install, ask the user to trust the developer in Settings → General → VPN & Device Management.
16. Ask the user to open CleanCam and allow the camera, microphone and local network prompts.
17. Start `receiver/cleancam-receive.sh`, which turns the USB stream into the "CleanCam" webcam, microphone and speaker.
18. For WiFi instead of the cable, start it with the iPhone's IP: `receiver/cleancam-receive.sh <iPhone IP>`.
19. Confirm the webcam receives video with `ffprobe -hide_banner -loglevel error -f v4l2 -show_entries stream=width,height -of compact "/dev/video${VIDEO_NR:-10}"`.
20. Confirm the microphone and the speaker exist with `wpctl status | grep CleanCam`, or on PulseAudio with `pactl list short sources` and `pactl list short sinks`.
21. Ask the user to pick "CleanCam" as the camera, the microphone and the speaker in the video app, restarting the app when it opened before the stream.
22. Tell the user to keep CleanCam open, since iOS stops the camera when the screen locks or the app leaves the foreground; its Screen off button only dims the screen.
23. Renew the 7-day free signing by repeating step 13 when the app stops opening.
24. Fix a failed step by its symptom in `reference/troubleshooting.md`.
