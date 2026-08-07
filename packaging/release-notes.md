# Zulangue 0.3.1

Shared recordings now outlive the room, and the app's notes and transcripts
moved to a sturdier document foundation.

- **A shared recording is yours to keep.** When someone shares a single
  recording, the transcript arrives as a copy on your Mac and stays after the
  room closes. Find it in the Share tab under Shared transcripts.
- **Correct a transcript together.** In rooms where everyone may write,
  corrections to the transcript's text and translations sync between Macs as
  they are typed, and a correction someone made by hand is never overwritten
  by the machine. Read-only rooms show a lock instead.
- **See how you are connected.** While viewing a share, a green bolt means a
  direct connection; an amber antenna means traffic is relayed. This tells
  apart a slow room from an isolated Wi-Fi.
- **Outline editing grows up.** Backspace at the start of a line merges it
  into the one above; drag the handle beside a line to move it — its indented
  children move with it.
- **Move a recording to another notebook.** The recording moves whole — both
  transcripts, the note, and the audio — and lands in time order.
- **A sturdier document foundation.** Transcripts and notes now live in a
  block-structured document store. Existing transcripts migrate automatically
  and verifiably the first time they are opened; the previous files are kept
  alongside as .pre-epoch2 backups.

Zulangue requires macOS 15.5 or later.
