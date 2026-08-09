# Zulangue 0.3.5

Web share, refined by watching a real meeting through it.

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

Fixes in the web page: a column for the language being spoken is no
longer blank — the original text fills it, because nothing translates
Chinese into Chinese; finalized sentences no longer appeared twice;
each column now shows only its own language, so language-detection
drift and stray fragments no longer pile up under the first heading;
a language left over from an earlier session no longer occupies a
column you couldn't remove; host notes now span the columns instead of
being repeated in each; and scanning the code mid-meeting now shows
every recording shared so far, not only the one still running.

Zulangue requires macOS 15.5 or later.
