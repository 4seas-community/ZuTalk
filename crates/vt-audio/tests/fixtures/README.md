# Audio fixtures

These files contain synthetic test audio only.

- `test_speech_16k_mono.wav` is generated with the macOS system speech
  synthesizer from a generic English test sentence.
- The remaining audio files are generated from sine waves and converted to the
  sample rate, channel count, and container named by each fixture.
- No fixture contains a recording of a real person or private conversation.

The fixtures exist only to validate decoding, import, encryption, export, and
opt-in provider integration tests.
