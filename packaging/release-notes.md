# ZuTalk 0.5.1

A recording no longer ends because the network did.

ZuTalk requires macOS 12.5 or later.

- **Realtime transcription survives an outage instead of ending at it.**
  ZuTalk used to give up after three quick reconnect attempts, so losing the
  network for more than a few seconds ended transcription for the rest of the
  recording — usually without saying so. It now keeps reconnecting for as long
  as the recording runs, and picks the same transcript back up when the network
  returns. Refusals that cannot be retried, such as an expired invitation,
  still stop the lane immediately and say why.

- **A recording no longer ends at an arbitrary minute.** Realtime providers end
  a session on their own clock — a community invitation's shared time budget
  most often. ZuTalk now treats that as a handover: the last words of the
  finished session are kept, and the recording continues on a fresh connection.

- **Untranscribed stretches are shown, not silently skipped.** When realtime
  transcription misses audio during an outage, the transcript shows a
  time-labeled gap between the surrounding lines instead of running the
  neighbouring lines together. The audio itself is still recorded, and
  transcribing after stopping fills the gap in.

- **The Record button chooses its own languages.** Recording languages can be
  set from Home before starting an unfiled recording, up to three per session,
  and the last choice becomes the default for the next one.
