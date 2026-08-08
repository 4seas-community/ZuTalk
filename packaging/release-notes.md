# Zulangue 0.3.2

Sharing a room now tells you what it is doing, notes gained real structure,
and deleting a recording finally means the same thing everywhere in the app.

- **Rooms of three or more work.** A correction made by one watcher never
  reached the others: the host kept it to itself instead of passing it on.
  Everyone in the room now sees everyone's corrections.
- **A dropped update no longer stalls the room.** The two Macs compare
  versions every couple of seconds and fill in whatever the other is missing,
  so a single lost message cannot leave a transcript frozen at an old version.
- **You can always tell when captions are leaving your Mac.** The recording
  bar, the menu bar popover, and the floating pill each carry the indicator,
  and any of them can mute this recording without ending the share.
- **Someone knocking gets your attention.** Join requests now appear wherever
  you are in the app, not only on the Share page.
- **The Share page knows which side you are on.** Hosting and joining are
  separate from the first screen, the join box takes a code and the Return
  key, and each scope says plainly what the other person ends up with.
- **Watchers can leave, and know when the host has.** The viewer gets a Leave
  button rather than the host's Stop, and is told when the host ends the room
  instead of watching a transcript quietly stop moving.
- **Received transcripts are yours to manage.** Each one carries the time it
  arrived and can be deleted on its own.
- **One room at a time.** Starting a share while watching someone else's — or
  hosting two rooms at once — is refused instead of producing a room state
  that no screen can describe. Switching rooms says goodbye to the old one, so
  nobody waits for a timeout to learn you left.
- **Notes are a real outline.** Undo and redo work the way they do everywhere
  else, Tab and Shift-Tab indent, and a line can become a heading, quote,
  to-do, or divider — type `#`, `>`, or `- [ ]` and the marker turns into the
  block. There is a "Turn into" menu for when you would rather not remember
  the shortcuts.
- **Deleting a recording means deleting it.** A recording in the Trash no
  longer turns up in search results, no longer counts towards its notebook,
  and no longer leaves its transcript sections on the notebook's tabs.
  Restoring brings all of it back.
- **A recording that is still recording cannot be deleted.** Stop it first —
  the delete option says so rather than failing after the fact.

Zulangue requires macOS 15.5 or later.
