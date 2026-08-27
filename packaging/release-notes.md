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
