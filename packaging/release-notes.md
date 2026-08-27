# ZuTalk 0.5.2

Live captions stay at the live edge, even when the provider cannot keep up.

ZuTalk requires macOS 12.5 or later.

- **A multi-language recording no longer loses transcription partway
  through.** With three recording languages, the realtime provider can fall
  behind the room and never catch up; captions drifted further and further
  behind and then stopped entirely, usually ten to fifteen minutes in, while
  the recording kept going. A lane that falls too far behind now skips ahead
  and rejoins at the live edge. Replaying a real 31-minute three-language
  session that had lost half its transcript: 99.8% transcribed, end to end.

- **What a skip misses is shown honestly.** Each skip leaves a time-labeled
  gap divider in the transcript covering exactly the untranscribed stretch —
  starting from the last transcribed words, not from where the connection
  was cut. The audio itself is still recorded, and transcribing after
  stopping fills the gap in.

- **Subtitle timing no longer drifts after an outage.** Audio dropped while
  skipping ahead now advances the transcript clock, so the words after a
  recovery land at the moment they were said instead of a few seconds early.
