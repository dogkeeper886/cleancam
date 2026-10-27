---
description: >-
  An agent writes release notes by its own ideas. The agent lists what
  changed, pull request by pull request, or leaves only the downloads. The
  list tells the user what changed but not what it solves for them. The user
  reads every line to decide whether to upgrade. This skill asks the agent to
  write release notes by the steps below.
---

Write release notes:
1. Collect the changes since the previous release from its tag, the merged pull requests and the issues they close.
2. Open the release notes with an SCQA opening structure: {what the current version does}. {what will become a problem}. {what the problem costs}. {what the new release provides}.
3. Give each group of changes, grouped by what they provide, a section in the order the reader needs them.
4. Open each section with the step 2 structure, written for its group of changes.
5. End with the release's downloads and their checksums, when the release has any.
6. Review the words with the `rewrite-phrasing` skill.
7. Review the look with the `reviewing-typography` skill.
8. Print the release notes in the session.
9. Publish the release notes on the release only on the user's yes.
10. Report with the `reporting-outcomes` skill.
