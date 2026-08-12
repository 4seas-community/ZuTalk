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
