# Zulangue 0.1.9

This release makes audio deletion verifiable, fixes audio-file transcription
timeouts, and keeps every language visible on the subtitle canvas.

- Deleted audio now shows as **Deleted** in the Resources tab instead of
  looking like it was never recorded. A verify button recomputes the
  destruction receipt on the spot — encrypted chunks overwritten and removed,
  encryption key destroyed, no files left behind — and opens the storage
  folder in Finder so you can check for yourself.
- Transcribing a recorded audio file no longer fails with a provider timeout:
  the transcription window now accounts for the provider finishing its
  backlog after the audio has been streamed.
- On the subtitle canvas, languages of very different lengths no longer push
  each other out of view: every language keeps its most recent words anchored
  to the bottom edge, even when one translation runs much longer than the
  others.
- Includes the improvements from the 0.1.7 and 0.1.8 builds: the event-canvas
  subtitle overlay with hover controls, the redesigned Notebook settings and
  Resources tabs, per-recording audio destruction, community-invite time that
  survives multi-language capture and interrupted sessions, and the drafts
  tab renamed to personal notes.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
