---
description: >-
  An agent sets up CleanCam on an old iPhone by its own ideas. The main app
  needs iOS 15, while a 32-bit iPhone such as the iPhone 5 stops at iOS 10
  and runs CleanCamLegacy, a second app that builds on the Linux PC instead
  of GitHub Actions. A step copied from the main app installs an IPA the
  phone refuses, waits for a Developer Mode iOS 10 lacks, or changes Swift
  code the old phone never runs. This skill asks the agent to build, set up,
  renew and change CleanCamLegacy by the steps below.
---

Set up CleanCamLegacy on a 32-bit iPhone and Linux PC:
1. Use this skill for a 32-bit iPhone on iOS 10, such as the iPhone 5 or 5c, and the `developing-cleancam` skill for iOS 15 or later.
2. Tell the user that a phone stuck between them, such as the iPhone 5s, 6 or 6 Plus on iOS 12, runs neither app, since iOS 11 dropped 32-bit apps and the main app needs iOS 15.
3. Set up the PC's tools from `.claude/skills/developing-cleancam/reference/host-setup.md`, including podman or docker, curl and zip for the build.
4. Ask the user to plug in only the old iPhone, straight into the PC without a hub, so `idevice_id -l | head -1` and the receiver's `iproxy` pick it.
5. Ask the user to unlock it, tap "Trust This Computer" and enter the passcode.
6. Confirm the pairing and the phone's iOS with `idevicepair validate` and `ideviceinfo -k ProductVersion`.
7. Ask the user to log in from their own terminal with `tools/plumesign.sh account login -u <their Apple ID>` when `tools/plumesign.sh account list` shows none, keeping the password and 2FA code out of the chat.
8. Leave the login's output and any container log unread, since plumesign echoes the password.
9. Fetch `CleanCam-legacy.ipa` from the latest release with `gh release download -R dogkeeper886/cleancam -p CleanCam-legacy.ipa -D build`, or build `build/CleanCam-legacy.ipa` with `tools/build-legacy.sh`, which downloads the pinned iOS 11.4 SDK and theos toolchain once and compiles in a container.
10. Sign and install with `tools/plumesign.sh sign --package build/CleanCam-legacy.ipa --apple-id --register-and-install --udid "$(idevice_id -l | head -1)" < /dev/null 2>&1 | grep -v DEBUG | tail -5`.
11. On a first install, ask the user to trust the developer in Settings → General → Device Management, named Profiles & Device Management on some phones, since iOS 10 has no Developer Mode.
12. Ask the user to open CleanCam and allow the camera and microphone prompts; iOS 10 asks no local network question.
13. Start `receiver/cleancam-receive.sh` unchanged, since CleanCamLegacy serves the main app's ports and formats.
14. Confirm the video with `ffprobe -hide_banner -loglevel error -f h264 -i tcp://127.0.0.1:5000 -show_entries stream=profile,width,height -of compact`, which works even while a video app holds the webcam.
15. Confirm the microphone and the speaker exist with `wpctl status | grep CleanCam`, or on PulseAudio with `pactl list short sources` and `pactl list short sinks`.
16. Ask the user to pick "CleanCam" as the camera, the microphone and the speaker in the video app, restarting the app when it opened before the stream.
17. Tell the user to keep CleanCam open and use its Screen off button, since iOS stops the camera when the screen locks.
18. Renew the 7-day free signing by repeating step 10 with the same IPA when the app stops opening.
19. Change the app in the Objective-C code in `CleanCamLegacy/`, then rebuild with step 9 and reinstall with step 10.
20. Keep a change within iOS 10's APIs, since the app's minimum is iOS 10.0 and clang warns about newer ones.
21. Add a framework the code starts using to the `-framework` list in `tools/build-legacy.sh`, since clang without Xcode links only the frameworks it is given.
22. Port a change to the main app's Swift code into `CleanCamLegacy/` when the old iPhone should get it too.
23. Find why the app closes at launch in the phone's log from `idevicesyslog`, saved outside the repo, since it names the phone's owner.
24. Fix a failed step by its symptom in `.claude/skills/developing-cleancam/reference/troubleshooting.md`.
