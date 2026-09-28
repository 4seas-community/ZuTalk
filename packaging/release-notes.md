# ZuTalk 0.5.9

Long recordings keep recording, and ZuTalk is simpler to run while they do.

ZuTalk requires macOS 12.5 or later.

## Recording you can rely on

- **Recordings no longer end on their own after twenty-odd minutes.** A
  brief stall on the Mac — another app busy, the window hidden, the display
  asleep — could fill a small audio buffer, and the recording was stopped
  outright. The buffer is four times larger; if it does fill, the missed
  instant is kept as silence and recording carries on. ZuTalk also tells
  macOS a recording is running, so the Mac does not throttle or idle-sleep
  it mid-meeting. If a recording ever does end by itself, you are told,
  with how much was saved.

- **A translation column that stops comes back.** When one language's
  translation dropped out, ZuTalk reopened it — but the reopened connection
  was never listened to, so the column stayed empty for the rest of the
  recording. It now fills again. And in three-language recordings, a column
  whose connection had to reconnect even once never placed another
  translation on its rows; it now keeps filling them.

- **A quoted phrase in another language no longer stops transcription.**
  The end of a line's translation arriving late could take transcription
  down for the rest of the recording. It is now added to its line.

- **Reconnect.** If live captions stop while you are still recording, the
  reason is shown in plain words with a *Reconnect* button beside it.
  Resuming from pause reconnects too.

- **Pause and Stop stay usable.** After pausing, the controls could stay
  greyed out and the menu bar could claim nothing was recording. A pause in
  progress now reads "Pausing…" instead of "Finishing".

## Three languages, fewer connections

- **Say which languages are spoken in the room.** With three languages,
  each can be marked "subtitles only". If two are spoken and one is only
  read, a recording uses two connections instead of four; if all three are
  spoken, three. Every row gets every column, and captions keep up with the
  speaker. The switch is on each language chip, in the topic's settings and
  in Home's language picker.

## Control a recording from anywhere

- **A recording bar above every page** while anything records: time, topic,
  whether captions are live and how far behind they are, and Mark, Pause,
  Stop. Reading an older recording or writing notes no longer hides them.
- **The menu bar controls the recording** — Mark, Pause, Stop, Reconnect —
  and starts one when nothing is recording.
- **The subtitle window has Mark, Pause and Stop** in its hover controls,
  and stops keeping the display awake once the recording ends.
- **⌃⌥R starts or stops a recording from any app**, ⌃⌥P pauses, ⌃⌥S marks
  the passage you just heard.
- **Live captions or recording only — chosen beside every Record button**
  and remembered. With an invite it shows how long the invite lasts. A
  topic's Record button now records instead of opening another page.

## Clearer everywhere

- **One set of words**, in every language: topics hold recordings; a
  recording has a live and a refined transcript, notes and marks.
- **The header shows where you are** — Topics › topic › recording, with its
  length and languages — instead of three rows repeating it.
- **Recordings are listed by what was said.** Untitled recordings show their
  first words; a badge appears only when something needs attention; lengths
  read as lengths and languages by their own names (中文 · English · ไทย).
- **The transcript names its columns**, shows the speaker when the speaker
  changes, and switches between *Side by side* and *Original only* in view.
- **Naming a speaker once is enough.** After live captions reconnect,
  speakers are numbered again, so one person could show up as two
  "Speaker 1"s and need naming twice; naming one now names the other too
  unless you untick it.
- **Rename recordings and topics, and delete topics.** Deleting a topic keeps
  its recordings: they move to "No topic".
- **Optional: tidy a marked passage.** With a language model key in
  Settings and the switch turned on, a marked passage is cleaned up into
  readable sentences a few seconds after you mark it. Only marked passages
  are sent, never audio; turning the switch off also deletes what came back.
- **Plain language** instead of internal terms, and no promises the app did
  not keep — Trash no longer claims to empty itself after 30 days.

## Sharing that works for anyone with a phone

Sharing used to need ZuTalk on a Mac at the other end, a join code over a
hundred characters long, and a network that let two computers find each
other. Almost nobody in a real room could get in. Now it takes a browser.

- **Share live captions from the recording bar.** People scan the QR code
  or open the link and follow the captions and translations on their phone
  or computer — no app, no sign-in. On a phone each sentence is shown with
  its translation underneath. *Show large QR code* opens it in its own
  window, ready for the projector.
- **End-to-end encrypted.** The key is in the part of the link after `#`,
  which browsers never send to a server, so ZuTalk's server only relays
  text it can't read. Anyone with the link can view it; audio never leaves
  your Mac.
- **See how many are watching, lock the share** so no one new gets in, or
  **replace the link** to shut out anyone who shouldn't be there.
- **Nothing stays behind by default.** When you stop — or the recording
  ends — the link stops working and its content is deleted from the server.
  Turn on *Keep the transcript after it ends* and viewers can still read and
  download it for about 24 hours.
- **Share a finished recording** from its menu or its header: send the
  transcript as a Markdown or subtitle (SRT) file through AirDrop, Messages
  or Mail, or create a read-only link. Links expire after 24 hours and you
  can revoke one at any time.
- **Peer-to-peer sharing is gone,** along with the Received page, join codes
  and nearby discovery. Transcripts already received that way stay on your
  Mac.
