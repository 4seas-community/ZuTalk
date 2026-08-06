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
