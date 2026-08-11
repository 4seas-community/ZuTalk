# ZuTalk 0.4.3

The floating subtitle canvas stays on the words being spoken.

ZuTalk requires macOS 15.5 or later.

- **Subtitles follow the live edge instead of stopping mid-transcript.** The
  canvas placed itself at the bottom when it opened and then stayed at that
  offset. As rows grew and older ones aged off the top, the view drifted: it
  parked partway up the transcript while speech carried on below it, and once a
  long line left the visible window it showed blank canvas — the viewport was
  looking at a place the text no longer occupied. Closing and reopening the
  overlay appeared to fix it because that built a new scroll view. The canvas
  now tracks the newest words, and still lets you scroll back and rejoin the
  live edge on your own.
- **Three languages no longer cost three times the work per revision.** In
  conversation mode every incoming revision re-sorted the whole set of
  translation cues once per language, to answer three questions about a set that
  had not changed. It is sorted once now.
- **A dense-script lane no longer re-lays out the whole row per character.**
  Chinese and Thai arrive a token at a time, so the live row was being rebuilt
  for roughly every character — measured at 27,367 revisions carrying 32,738
  characters across one 107-minute recording, against 40 characters per revision
  on the English lane beside it. The live row now refreshes on the same reading
  budget the audience canvas has always used. Nothing is delayed: a line stops
  being the live edge the moment the next one begins, and settles immediately.
- **A translation that cannot be filed stops trying forever.** When a
  translation segment was matched to a line whose lane had already been settled,
  the match was refused and then recomputed identically on the next audio event,
  because nothing about the refusal changed the evidence that produced it. One
  recording retried the same impossible write 2,048 times in 158 seconds, and
  would have continued until the recording stopped. Refusals are remembered now.
  The translation itself is not lost — it stays on file and can still be placed
  later.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.
