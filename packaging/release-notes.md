# Zulangue 0.2.0

This release turns Zulangue into a more focused multilingual live-captioning
workspace, with independent translation lanes, selectable audio input, and a
simpler path from setup to an audience-ready session.

- **Three languages stay live without waiting for one another.** Each selected
  translation language advances independently on the shared audio timeline, so
  a slow provider response in one column no longer blocks the others. Tail
  updates reconcile cleanly instead of repeating or erasing already visible
  text.
- **Fast speech remains time-aligned.** Source and translation ownership is
  explicit across the canonical and auxiliary streams, preventing competing
  lanes from rewriting the same subtitle while preserving provider timing.
- **Choose the microphone or audio device for each session.** Notebook capture
  can switch among available inputs, remembers a valid choice, and handles
  device changes without silently recording from the wrong source.
- **Knowledge profiles are easier to create and reuse.** A dedicated library
  organizes transcription context, while notebook selection and run snapshots
  keep each session's knowledge configuration predictable.
- **Soniox setup is shorter and clearer.** Onboarding focuses on the credential
  and connection states needed to start; low-level diagnostics no longer crowd
  the everyday settings experience.
- **Updates can arrive in the background.** Sparkle checks and prepares signed
  updates without interrupting a live session, leaving installation and restart
  under the user's control.
- **Korean is now available throughout the application.** The interface and
  release entry points now include Korean alongside the existing localizations.
- **The menu bar window opens more reliably.** Opening it no longer depends on
  an application activation sequence that could steal or lose focus.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
