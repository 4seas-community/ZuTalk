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
