# Zulangue 0.2.2

This release hardens long-running live transcription, makes stopping a capture
recoverable, and reduces the storage and time required for local and CI builds.

- **Long sessions remain responsive.** Transcript delivery, rendering, and the
  audience subtitle window now use bounded, revision-safe projections instead
  of repeatedly rebuilding unbounded history as a recording grows.
- **Stopping no longer gets stuck indefinitely.** If local persistence fails
  while a capture is draining, Zulangue preserves recoverable audio, releases
  capture ownership safely, and exposes a clear retryable failure state.
- **Live subtitles keep the display awake.** The Mac no longer dims or sleeps
  while the audience subtitle window is actively presenting a capture.
- **Compare mode is cleaner.** Repeated language labels are hidden so the
  transcript columns can focus on the spoken content.
- **The application uses the new ZuLangue identity.** The refreshed app icon
  and size-optimized logo assets are included throughout the release.
- **Builds use substantially less disk space.** Rust integration tests share
  fewer binaries, development artifacts are size-limited, and GitHub Actions
  reuses a controlled compiler cache without changing product behavior.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
