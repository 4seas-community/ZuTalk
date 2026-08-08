# Zulangue 更新历史

每一版的发布说明按时间倒序排列。当前正在准备的那一版在
`packaging/release-notes.md`,发布后由 `just bump` 归档到这里。

条目按当时发布的原文归档,不做事后修饰 —— 所以偶尔会看到标题落后于
它实际发布的标签(每条开头的 `tag:` 注释是准的)。

---

<!-- tag: v0.3.2 -->
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

<!-- tag: v0.3.1 -->
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

<!-- tag: v0.3.0 -->
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

<!-- tag: v0.2.3 -->
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

<!-- tag: v0.2.2 -->
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

<!-- tag: v0.2.1 -->
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

<!-- tag: v0.2.0 -->
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

<!-- tag: v0.1.11 -->
# Zulangue 0.1.11

This release makes long, fast-moving multilingual captions easier to follow
on both desk-sized windows and large audience displays.

- **Audience mode is now the default and appears first.** Existing explicit
  mode choices remain saved, while new and reset installations open directly
  into the live audience view.
- **Fast Chinese captions stay visually stable.** High-frequency interim
  hypotheses are coalesced into readable refreshes, final corrections still
  appear immediately, and whole-paragraph fade animations no longer create
  ghosted text during rapid speech.
- **The subtitle canvas adapts to its actual size.** Automatic type sizing is
  enabled by default, conversation history grows with the available canvas,
  and projector-sized windows use their space instead of leaving a fixed
  empty region.
- **Long translations remain visible in every language.** Audience columns
  anchor their newest text to the bottom, while notebook language columns can
  expand to fit unequal English, Chinese, Thai, and other translation lengths.
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

<!-- tag: v0.1.10 -->
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

<!-- tag: v0.1.9 -->
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

<!-- tag: v0.1.7 -->
# Zulangue 0.1.6

This release brings Zulangue to seven languages.

- The app interface is now available in English, ไทย (Thai), 日本語
  (Japanese), Français, Español, Deutsch, and 简体中文
  (Simplified Chinese). Pick your language in **Settings → General**.
- Error messages from the transcription engine are localized into the same
  seven languages.
- The project README is available in all seven languages as well.
- Fills in a handful of interface strings that were missing from the
  Japanese localization.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.6 -->
# Zulangue 0.1.6

This release brings Zulangue to eight languages.

- The app interface is now available in English, ไทย (Thai), မြန်မာ
  (Burmese), 日本語 (Japanese), Français, Español, Deutsch, and 简体中文
  (Simplified Chinese). Pick your language in **Settings → General**.
- Error messages from the transcription engine are localized into the same
  eight languages.
- The project README is available in all eight languages as well.
- Fills in a handful of interface strings that were missing from the
  Japanese localization.
- Continues to verify updates with the project-specific Sparkle signing key.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.

---

<!-- tag: v0.1.5 -->
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

<!-- tag: v0.1.4 -->
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

<!-- tag: v0.1.3 -->
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

<!-- tag: v0.1.2 -->
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

<!-- tag: v0.1.1 -->
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
