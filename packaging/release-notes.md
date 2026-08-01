# Zulangue 0.2.1

This release makes long-running Notebook work smoother, adds direct navigation
across recordings, and rounds out knowledge and window controls.

- **Long live transcripts stay responsive.** Historical summaries load away
  from the main interface, only the selected recording is hydrated, and rapid
  words, translation cues, and lane-health updates share a bounded rendering
  budget while always delivering the newest frame.
- **Every recording is easy to revisit.** A run navigator keeps completed,
  interrupted, active, and even empty recordings addressable without mounting
  every transcript at once.
- **Knowledge libraries can be imported as JSON.** Portable library documents
  preserve source order and identity checks, and imports remain revision-safe
  when edited in Zulangue.
- **Zulangue returns to the last Notebook.** A valid recent Notebook is restored
  automatically, while missing or deleted entries fall back safely.
- **Notebook navigation remains stable.** The built-in tab bar stays fixed above
  changing content instead of moving with each page.
- **Subtitle backgrounds are adjustable.** The audience window can be made more
  transparent without fading its text, while Reduce Transparency remains
  respected.
- **Window controls no longer reveal a second title bar.** Hovering the custom
  traffic lights keeps the native title bar hidden and preserves the intended
  window layout.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
