# Zulangue 0.1.10

This release rebuilds live multilingual subtitles around the capture
timeline. Translations now appear the moment the provider produces them,
flow onto the canvas at reading speed, and a single bad connection can no
longer take down a session.

- **Every selected language stays on the audience canvas.** Translations no
  longer wait to be matched against a transcription row before they may
  appear — each language runs as its own column of time-anchored cards, so
  a long speech in one language cannot leave the other columns empty. In a
  recorded session from the field, 93% of Thai and 91% of English
  translations had arrived but never reached the screen; the same session
  replays completely under the new engine.
- **Translations flow instead of landing in blocks.** The provider delivers
  translations in bursts about every 1.4 seconds; a reveal cursor now walks
  each burst onto the canvas at reading speed, so words appear continuously
  in every column. Text you have already read is never replayed or
  rewritten by later provider revisions.
- **Stuck translations recover themselves.** Upgrading reprocesses past
  sessions on first launch: translations that arrived but never bound to a
  row are matched again with word evidence and, where several fragments
  belong to one sentence, joined in spoken order. In the same field
  session, 306 of 316 stuck translations were recovered.
- **One unstable connection no longer stops the session.** Each translation
  language runs on its own connection; when one drops, its column pauses
  and catches up on its own while transcription and every other language
  keep running. The operator's hover bar names any language that is behind
  or unavailable — the audience never sees an error.
- **Stopping is safe after a connection failure.** Ending a recording after
  a translation connection had died no longer cuts off the transcript tail
  that was still arriving.
- **Narrow windows and large projector fonts keep every language visible.**
  When languages stack vertically, each language now owns an equal slice of
  the canvas anchored to its newest words, instead of the last language
  crowding the others off screen.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
