# ZuTalk 0.4.8

Past recordings can reach asynchronous transcription again.

ZuTalk requires macOS 15.5 or later.

- **The asynchronous transcription action no longer disappears.** Choosing an
  asynchronous transcript from Resources now opens that exact recording in
  the asynchronous tab. The Resources view closes, and ZuTalk shows either
  the start action, the personal-key setup action, or the recording's current
  transcription state.

- **Your recording selection follows you between transcript tabs.** When no
  recording is active, selecting an older recording in realtime history and
  then switching to asynchronous transcription keeps that recording selected.

- **Saved interrupted recordings can be transcribed.** If recording stopped
  unexpectedly but ZuTalk retained the encrypted audio, the same explicit
  asynchronous action is now available instead of failing before the upload
  task can be created.

- **Work in progress and failures stay visible.** Pending jobs remain on the
  transcript surface with their progress. Failed provider jobs show their
  stored error without offering a retry that cannot yet safely re-upload the
  audio; local projection failures still offer the existing local retry.

- **Live transcript rows are cleaner.** ZuTalk no longer freezes words that the
  provider has not committed, which avoids duplicate partial sentences, and it
  no longer stores a transcript row containing only a space.

Asynchronous transcription remains an explicit per-recording action: ZuTalk
does not upload a saved recording until you choose to start it.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.
