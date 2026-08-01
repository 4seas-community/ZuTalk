# Zulangue 0.1.11

This release makes long, fast-moving multilingual captions easier to follow
on both desk-sized windows and large audience displays.

- **Audience mode is now the default and appears first.** Existing explicit
  mode choices remain saved, while new and reset installations open directly
  into the live audience view.
- **Fast Chinese captions stay visually stable.** High-frequency interim
  hypotheses are coalesced into readable refreshes, final corrections still
  appear immediately, and whole-paragraph fade animations no longer create
  ghosted text during rapid speech.
- **The subtitle canvas adapts to its actual size.** Automatic type sizing is
  enabled by default, conversation history grows with the available canvas,
  and projector-sized windows use their space instead of leaving a fixed
  empty region.
- **Long translations remain visible in every language.** Audience columns
  anchor their newest text to the bottom, while notebook language columns can
  expand to fit unequal English, Chinese, Thai, and other translation lengths.
- **Notebook language columns keep up with live subtitles.** A newly arrived
  translation cue is shown immediately even before it binds to a durable
  transcript row, then hands off cleanly once that row catches up.
- **The menu bar popover opens reliably.** Opening it no longer depends on an
  unnecessary application activation step that could steal or lose focus.
- **Knowledge-base transcription is more predictable.** Selecting a knowledge
  base binds it directly to the notebook, and both live and imported-audio
  transcription use the context snapshot captured when the run begins.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
