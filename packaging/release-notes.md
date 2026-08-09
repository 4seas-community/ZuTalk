# Zulangue 0.3.4

This release makes sharing feel like being in the same room — whether the
other person runs Zulangue or just has a browser.

## Joining a room now feels like something

- The 分享 notebook is where received content lives: while a room is
  active it shows the host's captions as a live multilingual canvas —
  the same lanes, translations, and per-language status the host sees —
  and the transcripts you received stay there after the room ends.
- While you are in someone's room, the record button becomes an
  "in a shared room" state (your captions come from them; leave the room
  to record), and the sidebar's Share item carries a green in-room dot.
- The floating subtitle window now works for viewers too, fed by the
  host's live captions.

## Share a QR code with people who don't have the app

- While hosting, the Share page can start a **web share**: scan the QR
  code and the live transcript opens in any browser. Pick up to three
  languages and read them side by side in columns; the page follows the
  live captions and keeps the transcript after the share ends.
- The page speaks Simplified Chinese, Thai, and English, chosen from
  the browser language and switchable at any time.
- Plain talk, stated before you start and while it runs: caption text
  passes through the caption server unencrypted, and anyone with the
  link can read along. Audio is never shared — same rule as always.

## Fixes

- Captions from a host's second recording in the same room no longer
  freeze the viewer's screen.
- Multilingual detail (language lanes, live translation segments,
  per-language status) now survives the trip to viewers instead of
  being flattened to a single translation line.

Zulangue requires macOS 15.5 or later.
