# ZuTalk 更新历史

每一版的发布说明按时间倒序排列。当前正在准备的那一版在
`packaging/release-notes.md`,发布后由 `just bump` 归档到这里。

条目按当时发布的原文归档,不做事后修饰 —— 所以偶尔会看到标题落后于
它实际发布的标签(每条开头的 `tag:` 注释是准的)。

---

<!-- tag: v0.5.1 -->
# ZuTalk 0.5.1

A recording no longer ends because the network did.

ZuTalk requires macOS 12.5 or later.

- **Realtime transcription survives an outage instead of ending at it.**
  ZuTalk used to give up after three quick reconnect attempts, so losing the
  network for more than a few seconds ended transcription for the rest of the
  recording — usually without saying so. It now keeps reconnecting for as long
  as the recording runs, and picks the same transcript back up when the network
  returns. Refusals that cannot be retried, such as an expired invitation,
  still stop the lane immediately and say why.

- **A recording no longer ends at an arbitrary minute.** Realtime providers end
  a session on their own clock — a community invitation's shared time budget
  most often. ZuTalk now treats that as a handover: the last words of the
  finished session are kept, and the recording continues on a fresh connection.

- **Untranscribed stretches are shown, not silently skipped.** When realtime
  transcription misses audio during an outage, the transcript shows a
  time-labeled gap between the surrounding lines instead of running the
  neighbouring lines together. The audio itself is still recorded, and
  transcribing after stopping fills the gap in.

- **The Record button chooses its own languages.** Recording languages can be
  set from Home before starting an unfiled recording, up to three per session,
  and the last choice becomes the default for the next one.

---

<!-- tag: v0.5.0 -->
# ZuTalk 0.5.0

Every recording now has one durable Session home, from capture through
transcripts, notes, settings, and later research.

ZuTalk requires macOS 12.5 or later.

- **Home is now a searchable timeline of every Recording and Session.** You can
  find sessions by metadata or local transcript text, filter them by Topic,
  open an unfiled recording immediately, and file it into a Topic later.

- **Topics are a first-class workspace instead of a prerequisite for
  recording.** Start a quick recording from Home without creating or choosing
  a Topic. Inside a Topic, Resources brings together its sessions, imports,
  shared Topic Notes, recording defaults, and a deterministic research bundle
  made from selected transcripts.

- **Each Session has its own focused workspace.** Live Transcript, Processed
  Transcript, Session Notes, and the settings captured when recording began
  stay attached to that Session. Opening one Session no longer loads or falls
  back to a neighbouring recording from the same Topic.

- **Starting and stopping recording does less duplicate work.** ZuTalk resolves
  only the selected microphone, obtains realtime lane credentials in one
  batch, and shares one start operation across double-clicks or view changes.
  When recording stops, already-received remote events are drained before the
  connection closes so late final words are not silently left behind.

- **Invite and recording settings are applied in a predictable order.** An
  active community invitation can authorize realtime transcription when a
  recording starts; without one, Home quick capture explicitly returns to
  local-only mode instead of inheriting a stale remote setting. Post-recording
  asynchronous transcription remains an explicit action and still requires a
  personal provider key.

- **Session data is safer and more durable.** Session Notes survive closing and
  reopening the app. Transcript availability reflects durable content rather
  than a placeholder projection, historical capture settings remain immutable,
  and audio deletion verifies that the encrypted resource is actually gone
  while preserving transcripts and notes.

- **ZuTalk now supports macOS Monterey 12.5.** Adaptive layouts, scroll
  behaviour, build metadata, Rust libraries, and the Universal arm64/x86_64
  application are all built against the 12.5 deployment target.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.8 -->
# ZuTalk 0.4.8

Past recordings can reach asynchronous transcription again.

ZuTalk requires macOS 15.5 or later.

- **The asynchronous transcription action no longer disappears.** Choosing an
  asynchronous transcript from Resources now opens that exact recording in
  the asynchronous tab. The Resources view closes, and ZuTalk shows either
  the start action, the personal-key setup action, or the recording's current
  transcription state.

- **Your recording selection follows you between transcript tabs.** When no
  recording is active, selecting an older recording in realtime history and
  then switching to asynchronous transcription keeps that recording selected.

- **Saved interrupted recordings can be transcribed.** If recording stopped
  unexpectedly but ZuTalk retained the encrypted audio, the same explicit
  asynchronous action is now available instead of failing before the upload
  task can be created.

- **Work in progress and failures stay visible.** Pending jobs remain on the
  transcript surface with their progress. Failed provider jobs show their
  stored error without offering a retry that cannot yet safely re-upload the
  audio; local projection failures still offer the existing local retry.

- **Live transcript rows are cleaner.** ZuTalk no longer freezes words that the
  provider has not committed, which avoids duplicate partial sentences, and it
  no longer stores a transcript row containing only a space.

Asynchronous transcription remains an explicit per-recording action: ZuTalk
does not upload a saved recording until you choose to start it.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.7 -->
# ZuTalk 0.4.7

Translations now appear next to the sentence they translate, or not at all.

ZuTalk requires macOS 15.5 or later.

- **A translation no longer lands on the wrong line.** With three or more
  languages, each translation arrives on its own connection to the
  transcription service, and those connections do not agree on the clock —
  they drift a second or two apart over a few minutes. Deciding which
  transcript line a translation belonged to could fall back to that clock, and
  in conversation, where lines are about two seconds apart, a drifted
  translation lands on the next line and looks entirely convincing there. In
  one recording, two thirds of the translations shown were on the wrong line,
  a third of them exactly one line late — which reads as a translation column
  that has slipped and never recovers.

  Which line a translation belongs to is now decided by the words. Timings
  still order the candidates and still rule out lines that were spoken at a
  different moment, but they can no longer choose a line on their own.

- **Some lines will now show no translation where they used to show one.**
  This is the intended trade. A translation with nothing to tie it to a
  specific line is held rather than guessed, and a later correction from the
  service can still place it. A translation put on the wrong line cannot be
  taken back — it is on screen, next to words it does not translate. Very short
  lines are the ones most often left blank: "yes", "right", a name on its own
  carry too little to identify which line they came from.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.6 -->
# ZuTalk 0.4.6

Translations in a three-language recording stop far less often, and recover
when they do.

ZuTalk requires macOS 15.5 or later.

- **A recording with three or more languages keeps its translations.** Every
  connection to the transcription service needs its own key, and a community
  invitation issues a limited number per recording. A brief network hiccup
  retries the connection three times, and each retry was taking another key —
  even the attempts that never reached the service and so never used the key
  they were given. Four hiccups could exhaust a whole recording's supply, after
  which the next translation stream to reconnect was refused and stayed dark
  for the rest of the session. In a 49-minute recording, translation coverage
  held steady for twelve minutes and then went to zero. A retry now reuses the
  key its failed attempt never spent, so a hiccup costs one key instead of
  three. Recordings with one or two languages were never affected: they open a
  single connection.
- **A translation stream that is reopened now gets time to come back.** 0.4.5
  began reopening a stream that had been stopped, but allowed three attempts
  with no delay between them — all three were spent in a third of a second,
  before the replacement had finished connecting. Attempts are now spaced out,
  so a stream that fails once an hour is reopened every time, while one failing
  every fraction of a second is left alone within seconds instead of being
  hammered.
- **Diagnostics say which failure happened.** A stream that ended and a stream
  running fifty seconds behind are opposite problems, and the log recorded both
  with the same sentence. They now say which.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.5 -->
# ZuTalk 0.4.5

A translation column that stops now starts again, says so if it cannot, and the
subtitle window can be a strip across the top of the screen.

ZuTalk requires macOS 15.5 or later.

- **A translation that stops now comes back.** When local audio cannot reach a
  translation stream without a gap, that stream is stopped rather than
  continued on a timeline it no longer matches. Until now it stayed stopped:
  transcription carried on, the translation column simply never grew again, and
  nothing said why. A replacement stream is now opened at the live edge, so the
  column resumes. The words spoken during the gap are not recovered — that part
  is genuinely lost — but the rest of the recording is translated.
- **If it cannot come back, the app says which language stopped.** After a few
  failed attempts a stream is left alone rather than reconnected forever. The
  notebook page and the menu-bar popover now name the languages that ended, and
  say that restarting the recording is what brings them back.
- **Subtitle rows no longer run for minutes.** A row was closed only when the
  speaker paused long enough for the transcription service to notice, and
  continuous delivery does not reliably give it one. In a 93-minute lecture the
  longest row held 5,377 characters. Rows are now closed after 25 seconds of
  speech regardless, which also lets translations find the line they belong to:
  in that same recording, 1,691 translated segments were transcribed, returned,
  and then dropped for want of a row the right size to sit in.
- **The subtitle window can be a strip across the top of the screen.** The
  existing control fills the whole display, which covers the slide. The new one
  puts the captions in a band along the top at the full width of the display,
  with the slide visible underneath. Drag its lower edge to the height you
  want; that height is remembered. Both placements now follow the window when
  you drag it onto a projector, instead of staying sized for the laptop.
- **Settings shows whether this Mac is allowed through the relay.** Sharing
  across networks needs the relay, the relay admits only Macs enrolled against
  an invitation, and a Mac it refuses is refused silently — sharing keeps
  working on the same network and simply never connects to anyone elsewhere.
  The invitation card now shows that state and can retry the enrolment.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.4 -->
# ZuTalk 0.4.4

The subtitle window's controls no longer stretch across the room's view.

ZuTalk requires macOS 15.5 or later.

- **The operator controls are a corner panel, not a banner.** The bar that
  appears when you move the pointer over the subtitle window used to span its
  full width, with the status at one end, the controls at the other, and an
  opaque stripe joining them. Projected onto a wall it read as part of the
  slide, and most of what the room saw was the empty middle. The same controls
  now sit together in the top-right corner, on two compact rows, taking about
  half the width. Nothing was removed except the window's own title, which named
  the window to a room already looking at it.
- **The controls stay put while you use them.** With the window filling a
  display, the strip that brings the controls back was shorter than the controls
  themselves, so reaching for anything on their lower half dismissed them under
  the pointer. The strip is measured from the controls now.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.3 -->
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

---

<!-- tag: v0.4.2 -->
# ZuTalk 0.4.2

Imported stereo recordings are transcribed as what they actually sound like,
and subtitle exports now say how many lines they had to leave out.

ZuTalk requires macOS 15.5 or later.

- **Stereo .m4a and .mp4 imports are transcribed correctly.** An AAC track
  keeps its channel count inside the audio, not in the file header, and ZuTalk
  read the header. Stereo recordings were treated as mono: a 93-minute lecture
  showed up as 186 minutes, and the audio sent for transcription was the
  recording at half speed with the left and right channels braided together.
  What came back was not a poor transcript, it was a transcript of a different
  sound. Nothing warned about it, because nothing failed. Re-import any stereo
  file you transcribed before this version.
- **Subtitle exports tell you what could not be written.** A line whose words
  arrived without a usable time range cannot become a subtitle cue, so it was
  dropped — silently, and if that happened to every line you got an empty
  `transcript.srt`, usually discovered long afterwards. The export now finishes
  with a warning carrying the count, and says the saved transcript still holds
  those lines. They are not lost; they just have nowhere to sit on a timeline.
- **Updates are checked against the identity your copy is looking for.**
  Sparkle finds the app to replace by the names the installed copy holds. When
  a release changes both the app's file name and its bundle identifier, no
  installed copy can find it any more, and the failure is reported as a signing
  error even though every signature is valid. Releases are now blocked before
  packaging if the app inside would be unreachable that way.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.

---

<!-- tag: v0.4.1 -->
# ZuTalk 0.4.1

The app icon now reads ZuTalk, and a live-caption row stays in speaking order
when the transcription provider omits its timestamp.

ZuTalk requires macOS 15.5 or later.

- **An untimed live-caption row stays where it was spoken.** A provider response
  can occasionally omit timing metadata. That row used to fall to the bottom of
  the audience canvas, below sentences spoken minutes later. It now inherits an
  ordering bound from the row ahead of it, without inventing a timestamp or
  changing the saved transcript and subtitle exports.
- **The icon caught up with the name.** 0.4.0 renamed the app everywhere the
  name was text — menus, windows, the shared caption page. It could not rename
  the one place the name was a picture: the lettering is drawn into the icon's
  pixels, so the Dock, Finder, the About window and the update prompt all kept
  showing the old name. They now say ZuTalk.
- **If you still see the old icon, macOS is showing you a cached copy.** Log
  out and back in, or restart, and it will refresh. Nothing is wrong with the
  update.

---

<!-- tag: v0.4.0 -->
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

---

<!-- tag: v0.3.4 -->
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

---

<!-- tag: v0.3.3 · 2026-08-08 -->
# Zulangue 0.3.3

A maintenance release. Nothing in the app looks or behaves differently from
0.3.2 — this version exists to exercise the release process end to end, and
carries the accumulated test and tooling work behind it.

Zulangue requires macOS 15.5 or later.

---

<!-- tag: v0.3.2 · 2026-08-08 -->
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

---

<!-- tag: v0.3.1 · 2026-08-07 -->
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

---

<!-- tag: v0.3.0 · 2026-08-06 -->
# Zulangue 0.3.0

This release adds sharing. A new Share tab lets one Mac carry its live captions
to the others in the room, and lets everyone work on the same notes at once.

- **Share captions with the room.** Start sharing a notebook, hand out the
  share code, and whatever this Mac is transcribing appears live on every Mac
  that joins. On a shared Wi-Fi this needs no internet at all — the code
  carries the addresses, so a meeting keeps working when the network does not.
- **Work on the same notes together.** Documents in a shared notebook stay in
  sync as people type. Choose whether everyone can edit or only you can; each
  Mac enforces that choice before merging a change, and the part of a
  transcript the recording owns stays off limits to everyone.
- **Audio is never shared.** Not by default — at all. The sharing code cannot
  decrypt a recording or reach live audio, so no setting and no mistake can
  send one. Transcripts and notes travel; recordings stay on the Mac that made
  them.
- **Stopping stops what comes next.** Ending a share halts further updates. It
  cannot delete what someone already received, and the app says so rather than
  letting you assume otherwise.
- **Find people on the same network.** Macs on one Wi-Fi discover each other
  directly. macOS asks for local network permission the first time; declining
  leaves share codes working.
- **Sharing settings.** Settings › Sharing shows this Mac's share key and
  configures the relay used when two Macs cannot reach each other directly.
  The relay can be replaced or removed entirely. A relay only forwards —
  traffic stays end-to-end encrypted, so it cannot read what passes through.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.2.3 · 2026-08-05 -->
# Zulangue 0.2.3

This release makes the main window remember where you left it, gives the
audience subtitle window a proper maximize, finishes localizing the knowledge
base, and rebuilds how a community invitation authorizes live transcription.

- **The main window opens where you left it.** Size and position are restored
  across launches, and every window in the app now follows one shared window
  specification instead of each surface deciding for itself.
- **The audience subtitle window can be maximized and restored.** Presenting to
  a room no longer means living with whatever size the window opened at.
- **The knowledge base is localized in every shipped language.** Localization
  parity is now enforced by a build gate, so a string can no longer ship in
  some languages and not others.
- **Software updates show their download.** The sidebar reports progress while
  an update is being fetched, instead of only announcing the result once it is
  ready to install.
- **Community invitations authorize each connection separately.** An invited
  partner's live transcription now takes a single-use key per connection
  rather than one shared key for the whole recording. Recordings longer than
  an hour no longer depend on refreshing a credential before it expires, and a
  key that escapes is worth at most one stream for a few minutes.
- **After-stop transcription always runs on your own key.** Invitation time
  covers live transcription and translation. Transcribing a recorded file
  uploads that recording to the speech provider, so Zulangue asks for your own
  API key instead of doing it under someone else's account.
- **Remaining invitation time is honest about translation.** Shared time is
  spent once per translation lane, so the sidebar now reports how long you can
  actually record with the languages you have selected.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.2.2 · 2026-08-02 -->
# Zulangue 0.2.2

This release hardens long-running live transcription, makes stopping a capture
recoverable, and reduces the storage and time required for local and CI builds.

- **Long sessions remain responsive.** Transcript delivery, rendering, and the
  audience subtitle window now use bounded, revision-safe projections instead
  of repeatedly rebuilding unbounded history as a recording grows.
- **Stopping no longer gets stuck indefinitely.** If local persistence fails
  while a capture is draining, Zulangue preserves recoverable audio, releases
  capture ownership safely, and exposes a clear retryable failure state.
- **Live subtitles keep the display awake.** The Mac no longer dims or sleeps
  while the audience subtitle window is actively presenting a capture.
- **Compare mode is cleaner.** Repeated language labels are hidden so the
  transcript columns can focus on the spoken content.
- **The application uses the new ZuLangue identity.** The refreshed app icon
  and size-optimized logo assets are included throughout the release.
- **Builds use substantially less disk space.** Rust integration tests share
  fewer binaries, development artifacts are size-limited, and GitHub Actions
  reuses a controlled compiler cache without changing product behavior.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.2.1 · 2026-08-01 -->
# Zulangue 0.2.1

This release makes long-running Notebook work smoother, adds direct navigation
across recordings, and rounds out knowledge and window controls.

- **Long live transcripts stay responsive.** Historical summaries load away
  from the main interface, only the selected recording is hydrated, and rapid
  words, translation cues, and lane-health updates share a bounded rendering
  budget while always delivering the newest frame.
- **Every recording is easy to revisit.** A run navigator keeps completed,
  interrupted, active, and even empty recordings addressable without mounting
  every transcript at once.
- **Knowledge libraries can be imported as JSON.** Portable library documents
  preserve source order and identity checks, and imports remain revision-safe
  when edited in Zulangue.
- **Zulangue returns to the last Notebook.** A valid recent Notebook is restored
  automatically, while missing or deleted entries fall back safely.
- **Notebook navigation remains stable.** The built-in tab bar stays fixed above
  changing content instead of moving with each page.
- **Subtitle backgrounds are adjustable.** The audience window can be made more
  transparent without fading its text, while Reduce Transparency remains
  respected.
- **Window controls no longer reveal a second title bar.** Hovering the custom
  traffic lights keeps the native title bar hidden and preserves the intended
  window layout.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.2.0 · 2026-08-01 -->
# Zulangue 0.2.0

This release turns Zulangue into a more focused multilingual live-captioning
workspace, with independent translation lanes, selectable audio input, and a
simpler path from setup to an audience-ready session.

- **Three languages stay live without waiting for one another.** Each selected
  translation language advances independently on the shared audio timeline, so
  a slow provider response in one column no longer blocks the others. Tail
  updates reconcile cleanly instead of repeating or erasing already visible
  text.
- **Fast speech remains time-aligned.** Source and translation ownership is
  explicit across the canonical and auxiliary streams, preventing competing
  lanes from rewriting the same subtitle while preserving provider timing.
- **Choose the microphone or audio device for each session.** Notebook capture
  can switch among available inputs, remembers a valid choice, and handles
  device changes without silently recording from the wrong source.
- **Knowledge profiles are easier to create and reuse.** A dedicated library
  organizes transcription context, while notebook selection and run snapshots
  keep each session's knowledge configuration predictable.
- **Soniox setup is shorter and clearer.** Onboarding focuses on the credential
  and connection states needed to start; low-level diagnostics no longer crowd
  the everyday settings experience.
- **Updates can arrive in the background.** Sparkle checks and prepares signed
  updates without interrupting a live session, leaving installation and restart
  under the user's control.
- **Korean is now available throughout the application.** The interface and
  release entry points now include Korean alongside the existing localizations.
- **The menu bar window opens more reliably.** Opening it no longer depends on
  an application activation sequence that could steal or lose focus.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.11 · 2026-08-01 -->
# Zulangue 0.1.11

This release makes long, fast-moving multilingual captions easier to follow
on both desk-sized windows and large audience displays.

- **Audience mode is now the default and appears first.** Existing explicit
  mode choices remain saved, while new and reset installations open directly
  into the live audience view.
- **Fast-moving captions stay visually stable.** High-frequency interim
  hypotheses are coalesced into readable refreshes, final corrections still
  appear immediately, and whole-paragraph fade animations no longer create
  ghosted text during rapid speech.
- **The subtitle canvas adapts to its actual size.** Automatic type sizing is
  enabled by default, conversation history grows with the available canvas,
  and projector-sized windows use their space instead of leaving a fixed
  empty region.
- **Long translations remain visible in every language.** Audience columns
  anchor their newest text to the bottom, while notebook language columns can
  expand to fit translations of very different lengths.
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

---

<!-- tag: v0.1.10 · 2026-08-01 -->
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

---

<!-- tag: v0.1.9 · 2026-07-31 -->
# Zulangue 0.1.9

This release makes audio deletion verifiable, fixes audio-file transcription
timeouts, and keeps every language visible on the subtitle canvas.

- Deleted audio now shows as **Deleted** in the Resources tab instead of
  looking like it was never recorded. A verify button recomputes the
  destruction receipt on the spot — encrypted chunks overwritten and removed,
  encryption key destroyed, no files left behind — and opens the storage
  folder in Finder so you can check for yourself.
- Transcribing a recorded audio file no longer fails with a provider timeout:
  the transcription window now accounts for the provider finishing its
  backlog after the audio has been streamed.
- On the subtitle canvas, languages of very different lengths no longer push
  each other out of view: every language keeps its most recent words anchored
  to the bottom edge, even when one translation runs much longer than the
  others.
- Includes the improvements from the 0.1.7 and 0.1.8 builds: the event-canvas
  subtitle overlay with hover controls, the redesigned Notebook settings and
  Resources tabs, per-recording audio destruction, community-invite time that
  survives multi-language capture and interrupted sessions, and the drafts
  tab renamed to personal notes.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.7 · 2026-07-31 -->
# Zulangue 0.1.7

这一版打了标签但没有发布页,也就没有留下发布说明。列在这里是为了让
版本序列不缺号。

---

<!-- tag: v0.1.6 · 2026-07-31 -->
# Zulangue 0.1.6

This release expands Zulangue's interface localization.

- The app interface and transcription-engine error messages are now available
  in additional languages. Pick your language in **Settings → General**.
- The project README is available in additional localized editions.
- Fills in a handful of interface strings that were missing from localized
  editions.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.5 · 2026-07-31 -->
# Zulangue 0.1.5

This release fixes a bug that could freeze live transcription mid-recording
and makes software updates and invite codes easier to manage.

- Fixes a live-capture freeze: a translation arriving for an
  already-translated sentence no longer aborts the recording or leaves the
  transcript stuck in a failed projection state.
- Retries interrupted update downloads automatically and ships small delta
  updates for recent versions, so updating works on unstable networks.
- Community invite codes can now be entered and disabled in Settings, and
  your own Soniox key always takes priority over invite keys when both are
  present.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.4 · 2026-07-31 -->
# Zulangue 0.1.4

This release keeps multilingual transcripts durable across restarts and
network interruptions.

- Persists realtime translation lanes so multilingual transcripts survive
  app restarts without losing corrections.
- Preserves captured audio across realtime network interruptions and records
  the gaps so the missing transcript can be repaired.
- Recovers realtime transcription automatically after temporary service
  interruptions.
- Audience subtitle mode now shows the latest utterance in up to three equal
  languages.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.3 · 2026-07-30 -->
# Zulangue 0.1.3

This release makes live multilingual transcription safer to edit and easier to
follow.

- Preserves transcript lanes that you have corrected while recording continues.
- Keeps finalized transcript lanes stable instead of rewriting them with stale
  provider updates.
- Improves live capture updates and multilingual subtitle presentation.
- Retains the movable, resizable, always-on-top subtitle window and Notebook
  resource timeline introduced in 0.1.2.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.2 · 2026-07-30 -->
# Zulangue 0.1.2

This release makes live multilingual work easier to follow and organize.

- Adds an always-on-top multilingual subtitle window for recordings.
- Lets you move and resize the subtitle window and adjust its text size.
- Opens or closes live subtitles from the recording view or menu bar.
- Adds a Notebook resource timeline for audio, live transcripts, processed
  transcripts, and personal notes.
- Keeps Sparkle update checks and signed update verification from 0.1.1.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.1 · 2026-07-30 -->
# Zulangue 0.1.1

This is the first Zulangue release with built-in update checks.

- Checks for new versions automatically and shows a native update prompt.
- Adds a manual **Check for Updates…** action in the app and menu-bar menus.
- Verifies downloaded updates before extraction and installation.
- Improves Soniox key setup and connection validation.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.0 · 2026-07-30 -->
**Full Changelog**: https://github.com/Zuddev/zulangue/commits/v0.1.0
