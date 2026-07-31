# Zulangue 0.1.5

This release fixes a bug that could freeze live transcription mid-recording
and makes software updates and invite codes easier to manage.

- Fixes a live-capture freeze: a translation arriving for an
  already-translated sentence no longer aborts the recording or leaves the
  transcript stuck in a failed projection state.
- Retries interrupted update downloads automatically and ships small delta
  updates for recent versions, so updating works on unstable networks.
- Community invite codes can now be entered and disabled in Settings, and
  your own Soniox key always takes priority over invite keys when both are
  present.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
