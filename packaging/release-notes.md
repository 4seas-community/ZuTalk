# ZuTalk 0.7.1

Long recordings stop in a moment instead of sitting on "Finishing", a Mac
that goes to sleep ends the recording cleanly, and a transcript you kept
after a live link can now be taken down.

ZuTalk requires macOS 12.5 or later.

## Stopping a recording

- **Stopping a long recording is much faster.** Saving a two-hour
  recording took about five seconds on Apple silicon; it now takes well
  under one. Audio is sealed with the Mac's built-in encryption hardware,
  which ZuTalk was not using before — recording itself does less work too.
- **The recording bar says what Stop is doing:** *Saving recording… 3 s*,
  instead of a bare "Finishing" with no end in sight.
- **Stop no longer waits on a transcription connection that has already
  dropped.**

## When the Mac sleeps

- **Closing the lid or putting the Mac to sleep ends the recording,** saved
  exactly as if you had pressed Stop. When the Mac wakes, ZuTalk tells you
  the recording ended and how long it was. Before, the microphone picked up
  again after wake while live captions stayed dead for the rest of the
  meeting.

## Live caption links

- **A transcript kept after a live link ends can now be revoked.** With
  *Keep the transcript after it ends* on, the transcript stays on the link
  for about 24 hours — but once the live link stopped, it showed up nowhere
  and could not be taken down. It now appears in the recording's **Share…**
  and in **Settings › Sharing**, where **Revoke** removes it at once.
