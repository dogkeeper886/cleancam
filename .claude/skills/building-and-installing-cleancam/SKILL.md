---
description: >-
  An agent installs the current CleanCam code on the attached iPhone by its own
  ideas. The steps never change: check the phone, pick the app by its iOS,
  build or fetch the IPA, then sign and install it. Worked out again each
  session, they cost a dozen tool calls and questions the user has answered
  before. This skill asks the agent to run tools/deploy.sh, which does every
  fixed step in one call, by the steps below.
---

Build and install CleanCam on the attached iPhone:
1. Set up the PC and the Apple ID with the `developing-cleancam` skill first.
2. Run `tools/deploy.sh` with a 10-minute timeout, since an iOS 15 phone waits for the GitHub Actions build.
3. Relay the line it stops on to the user, since it names the one step only the user can do.
4. Run it again once the user has done that step.
5. Ask the user to log in from their own terminal when it finds no Apple ID, keeping the password and 2FA code out of the chat, since plumesign echoes the password.
6. Ask the user before committing and pushing when it asks for the main app's changes on GitHub.
7. Look up any other error it prints in `.claude/skills/developing-cleancam/reference/troubleshooting.md`, with the full output in `build/deploy.log`.
8. Relay its last two lines, which name the installed build, its signing deadline and what to do on the phone.
9. Run it again to renew the 7-day signing when the app stops opening.
