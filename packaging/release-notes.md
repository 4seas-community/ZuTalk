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
