# ZuTalk 0.7.10

Translations land on the right line, and captions keep going until you stop.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Captions no longer stop in the middle of a recording.** When the
  translation service took back part of a sentence it had already sent,
  the whole translation column for that line was emptied, and the moment
  the line was finished ZuTalk stopped transcribing until the recording
  was restarted. Only the part taken back is removed now, and
  transcription carries on.
- **Translations land on the line they belong to.** The translation of a
  sentence no longer sticks to the line before it, a short "Okay" no
  longer takes the translation of the sentence that follows, and a
  translation that moves to a better line no longer makes its old line
  disappear.
- **A line heard in the wrong language is corrected.** When Chinese was
  recognised as Thai, the Thai translation went missing and Chinese
  appeared in the Thai column. ZuTalk now notices when a line's words are
  not written in the language it was given and takes the language the
  translation heard.
- **Translations stay in time after a dropped connection.** Translations
  no longer drift onto earlier lines after a reconnect, words are no
  longer repeated where a connection was replaced, and after a long drop
  the captions catch up at twice the speed of speech. A translation
  service that times out reconnects instead of falling silent for the
  rest of the recording.
- **Nothing said is lost while ZuTalk reconnects.** Pausing or stopping
  while a translation was reconnecting could drop the speech just before
  it. It is now sent first.
- **Lines no longer go missing or come back.** A line ZuTalk could not
  read in time is fetched again during the recording instead of after it,
  and a line the service took back no longer reappears.
- **The subtitle window stops waiting in silence.** The "…" for a
  translation that is not coming any more now clears, and a line whose
  language was not identified stays in the column of the line before it.
- **Speaker names appear during the recording**, and Copy is available
  only once there is a line to copy.

## Stopping

- **Stop no longer crashes when a translation does not answer.** And when
  the service never confirms the last words, that stretch is kept as a gap
  that is transcribed again after the recording, instead of being lost.

## Text

- **Thai is searchable.** Words inside a Thai sentence are now found,
  including in recordings made before this version.
- **Thai ำ is written the standard way**, so Thai text copied out of
  ZuTalk matches what you would type.
- **No stray spaces in Chinese.** The spaces the service put after "。"
  and "，" are gone.

## Watching a nearby recording

- **Choosing a language shows everything said in it**, not only what was
  translated into it, and the same line no longer appears twice.
