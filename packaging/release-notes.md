# ZuTalk 0.7.11

Translations stay on the right line in Thai, Chinese and English, however long the meeting runs.

ZuTalk requires macOS 12.5 or later.

## While recording in three languages

- **Translations no longer slide onto the next speaker's line.** Each
  language's translation is timed on its own connection, and that timing
  slipped a little later every time a sentence ended. After a few minutes of
  quick back-and-forth, translations landed one line too late and some lines
  were left with none. Every connection now keeps the same time.
- **Short replies get their own translation.** A one-word answer such as
  "Thanks." or "ครับ" no longer has its translation attached to a line two
  rows back.
- **No half-finished copy of a line.** A line such as "Of cours" no longer
  stays above the finished "Of course." when the service ends a sentence
  while it is still guessing the next words.

## In every language pair

- **Long speeches break at pauses.** A long passage, Thai above all, now
  ends a line where the speaker pauses instead of running on for 25 seconds
  and breaking mid-sentence, so its translations settle sooner.
- **Words stay whole.** A word is no longer split across two lines, whether
  the speaker label changes in the middle of it or the service sends an
  English word in pieces. Thai text stays in the Thai column even when it
  was labelled as another language, and an English word or two inside a Thai
  or Chinese sentence, or a number, stays in that sentence.

## Translations

- **No stray spaces in Chinese translated from English.**
- **Thai translations no longer guess who is speaking.** The service ended
  Thai sentences with ค่ะ or ครับ, choosing a gender for the speaker; ZuTalk
  now leaves them out.
