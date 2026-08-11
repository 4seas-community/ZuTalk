# Audio fixtures

These files contain synthetic test audio only.

- `test_speech_16k_mono.wav` is generated with the macOS system speech
  synthesizer from a generic English test sentence.
- The remaining audio files are generated from sine waves and converted to the
  sample rate, channel count, and container named by each fixture.
- `test_44k_stereo.m4a` merges two different sine tones into a stereo AAC
  track whose MP4 header omits the channel configuration, so the decoder must
  report the channel count it actually produced.
- No fixture contains a recording of a real person or private conversation.

The fixtures exist only to validate decoding, import, encryption, export, and
opt-in provider integration tests.
