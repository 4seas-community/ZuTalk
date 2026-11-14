# ZuTalk 0.8.5

Recording now uses Soniox's newest speech models, v6, for live text and for
refining.

ZuTalk requires macOS 12.5 or later.

## Soniox v6

- **Live text and refining move to v6.** New recordings stream to
  `stt-rt-v6`, and Refine sends audio to `stt-async-v6`. Soniox describes v6
  as more accurate, with better speaker separation and translation. Nothing
  changes in how you record, and the invite code works as before.
- **Recordings you already have keep their record.** Each recording notes
  the model it was made with; ones made before this version still say v5,
  and that is not rewritten. Settings › Advanced shows the models new
  recordings use.
- **A refine that had not finished before the update starts again on v6.**
  Refining always starts again from the audio, so nothing is lost.

## Recordings from a Mac on a newer version

- **The library now accepts any Soniox model of the right kind.** Until now
  the library accepted the exact model names of the version that wrote it,
  so a recording made with a newer model could not be stored by a Mac still
  on the older version. From this version, a recording synced from a Mac
  that has moved to a later Soniox model is received as it is.
- Macs on 0.8.4 or earlier still refuse recordings made with v6. Update every
  Mac you sync between.

The first launch after the update takes a moment longer while the library
is updated.

Checked against Soniox's live service for live text (with two-way
translation, using both a project key and the kind of short-lived key the
invite code hands out) and for refining, using synthetic English speech.
Nothing in this version was clicked through in a running app before
release.
