# ZuTalk 0.7.6

The recording bar stays still while you record.

ZuTalk requires macOS 12.5 or later.

## While recording

- **No more flickering "Captions behind" notice.** After the live
  transcription reconnected, the recording bar could flip between
  "Captions 16 s behind" and nothing several times a second, shifting
  every button beside it. The notice now shows only while captions really
  are behind, with how far they are behind right now.
- **A fresh connection starts with a clean slate.** When the live
  transcription reconnects, it no longer reports the delay of the
  connection it replaced.
