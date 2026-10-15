# ZuTalk 0.7.8

Three-language recordings keep every translation, and Stop always stops.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Every translation reaches the transcript.** In recordings with three
  languages, some translations never appeared: a short reply between two
  sentences, a sentence the translation split differently from the
  transcript, or anything translated right after a reconnect. Each
  translation now finds its line as soon as the transcript has caught up
  with it, and the line is chosen by when it was said.
- **Long multi-language recordings stay live.** After about twenty minutes,
  a three-language recording could fall into reconnecting every half
  minute, losing translations each time. ZuTalk's own bookkeeping grew with
  the length of the recording, and its connections mistook falling behind
  for the service lagging. The work no longer grows as you record, and a
  connection never waits for ZuTalk to catch up.
- **Stop always stops.** If stopping, pausing or resuming does not finish
  within 15 seconds, Stop becomes available again, and pressing it ends the
  recording. Everything recorded is kept. Quitting ZuTalk no longer waits
  indefinitely for a recording that will not stop.
- **"Translated in the line above".** When one translated sentence covers
  two lines of the transcript, the line without words of its own now says
  where they are instead of showing a dash.

## Community invitations

- **No more "community service unavailable" after a crash.** An invitation
  no longer refuses a new recording because earlier ones were not settled.
- **Invitation time is settled however a recording ends.** Stopped,
  interrupted, quit, or — on the next launch — after a crash, a recording
  is charged for the time it actually recorded.
- **Clearer reasons when a recording cannot start**: the invitation's time
  is used up, too many people are recording at once, or the invitation no
  longer works.
