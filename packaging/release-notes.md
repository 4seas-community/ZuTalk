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
- **Rename recordings and topics, and delete topics.** Deleting a topic keeps
  its recordings: they move to "No topic".
- **Optional: tidy a marked passage.** With a language model key in
  Settings and the switch turned on, a marked passage is cleaned up into
  readable sentences a few seconds after you mark it. Only marked passages
  are sent, never audio; turning the switch off also deletes what came back.
- **Plain language** instead of internal terms, and no promises the app did
  not keep — Trash no longer claims to empty itself after 30 days.

## Sharing, rebuilt around the recording

- **Only people with the join code can watch.** Live captions and shared
  transcripts used to be served to any ZuTalk on the same network that
  asked, code or no code, approved or not. Now a device has to prove it
  holds the code before anything is sent, and joining takes effect at once
  instead of sometimes hanging on "waiting".
- **Share live from the recording bar.** People you let in follow the
  captions and translations as you speak. By default nothing stays on their
  Mac when they leave; you can let them keep the transcript for that one
  share. The live share ends with the recording.
- **Share a finished recording from its menu** or from the recording's
  header: the people you let in get a copy of the transcript, read-only or
  correctable.
- **See who is watching, and remove someone.** A removed viewer is told
  so and can't come back with the same code.
- **Found nearby only if you say so.** Other Macs on the network see your
  share — with the name and title you chose to show — only when you turn
  that on, and you still approve each person.
- **Received** replaces the Share page: what you're watching, shares open
  nearby, joining with a code, and transcripts kept on this Mac with who
  shared them.
- **A web link says what it uploads** — live captions, or the whole
  transcript with speaker names if viewers may keep it — that it passes
  through ZuTalk's server in plain text, and that it stays at the link for
  about 24 hours.
- Starting a recording while watching someone's share asks first; the two
  can't run together.
