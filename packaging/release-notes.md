# ZuTalk 0.4.0

Zulangue is now ZuTalk — same app, same recordings, new name. Plus web
share, refined by watching a real meeting through it.

## The new name

- **Your recordings, notes, and settings come across by themselves.**
  The first time ZuTalk opens it moves the data folder and your
  preferences over: recording history, editor documents, window and
  subtitle layout, and a redeemed invite code all carry over. Nothing to
  export or re-import.
- **Drag the old Zulangue app to the trash.** macOS treats ZuTalk as a
  different app, so the old one stays in /Applications and will not
  receive updates again. Open ZuTalk first, check your recordings are
  there, then delete it.
- **Sharing needs both Macs on 0.4.0.** The rename goes all the way down
  into the connection and document formats, so a ZuTalk Mac and a
  Zulangue Mac cannot see each other at all. Update together.

## Web share

- **Recording breaks are visible.** Pausing draws a line on the web page
  and stops the captions there; resuming draws a line stamped with the
  time the recording picked up again. Everything above stays as it was.
- **Read up to three languages side by side.** Language buttons are
  multi-select now — each pick adds a column, including one for the
  original text — with sticky headers and the choice remembered.
- **The interface speaks your language.** Simplified Chinese, Thai, and
  English, chosen from the browser and switchable at any time.
- **The live text reads like the app's own recording view**: it
  continues under the transcript and refreshes in place instead of
  sitting in a quoted block.
- **You can see who is speaking.** Both the web page and the floating
  subtitle window label each turn, using the name you gave the speaker
  when you have given one, and "Speaker 2" in the reader's own language
  when you have not.
- **Watching someone's room looks like your own recording.** The
  floating subtitle window used to fall back to a single scrolling list
  for viewers; it now draws the same per-language columns the host sees,
  built from the languages the host is actually running.
- **The transcript outlives the meeting.** Stopping the share used to
  turn the link into a dead end that instant, and restarting the caption
  server voided every code in the room at once. The transcript now stays
  readable at its link for about a day after the last words arrive, and
  survives a server restart. Say so plainly: caption text passes through
  the server unencrypted **and is kept there for that while** — the
  start-sharing screen says it, and the page itself tells readers how
  long the link has left.

## Captions that stay lined up, and translation that stays quick

- **Long recordings stop bogging down.** Translation used to grow
  sluggish after a while, and the cause was not the translation at all:
  every new sentence made the app rewrite the entire transcript it had
  already written. It now writes only what changed. At around 800 lines
  — roughly a ninety-minute recording — that work went from 8.6 seconds
  a sentence to under ten milliseconds.
- **The languages line up again.** A window slightly too narrow for
  three columns used to collapse to one, stacking the languages instead
  of setting them side by side; it now drops to two, then one. Columns
  also account for their own padding, so a canvas that says it fits
  three really does.
- **The newest line sits on the same edge in every column.** A language
  running a beat behind showed a small ellipsis, and that ellipsis was
  pushing its current line up out of alignment with the others.
- **Stray spaces are gone.** Chinese and Thai sentences no longer pick
  up a space in the middle, a Latin word next to Chinese no longer
  collides with it, and the original-language column no longer sits
  indented one space from its neighbours.
- **The floating window stopped explaining itself.** A line whose
  language had not been identified yet used to appear as a labelled
  status row, which broke the columns and told the room something only
  an operator can act on. It now appears as what it is — speech. The
  saved transcript still says when an identity was never established.
- **Older recordings finish filling in their translations.** Some
  recordings held translated fragments that were waiting to be attached
  to a line and never were — quietly, with nothing to see. Opening the
  app now completes them, and tidies up the stray spaces those lines
  were saved with. If you share such a recording, viewers get the
  completed version too.

Also fixed: a transcription service that went quiet without closing the
connection would leave the app holding every second of audio it had sent
since — up to about 115 MB an hour, in an app whose whole posture is that
audio does not stick around. It now keeps only the few seconds a
reconnect could actually use.

Fixes in the web page: the live text at the bottom now bottom-aligns
across columns the way the app's own window does; a column for the
language being spoken is no
longer blank — the original text fills it, because nothing translates
Chinese into Chinese; finalized sentences no longer appeared twice;
each column now shows only its own language, so language-detection
drift and stray fragments no longer pile up under the first heading;
a language left over from an earlier session no longer occupies a
column you couldn't remove; host notes now span the columns instead of
being repeated in each; and scanning the code mid-meeting now shows
every recording shared so far, not only the one still running.

ZuTalk requires macOS 15.5 or later.
