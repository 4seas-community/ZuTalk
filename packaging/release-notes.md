# ZuTalk 0.5.3

Recordings take half the disk space they used to.

ZuTalk requires macOS 12.5 or later.

- **New recordings are stored at half the previous size.** ZuTalk's encrypted
  audio store kept every 16-bit microphone sample widened to 32 bits — twice
  the bytes for the same sound. Recordings made from this version on are
  stored at the microphone's own width: about 115 MB per hour instead of 230.

- **Existing recordings are untouched.** Everything recorded before this
  version stays exactly as it is on disk and remains fully readable —
  playback, export, and after-stop transcription all handle both the old and
  the new storage width, chosen per recording.

- **Nothing else changes.** Transcription quality, exports, and the audio
  itself are identical; the removed 32-bit widening carried no information —
  the microphone is a 16-bit source.
