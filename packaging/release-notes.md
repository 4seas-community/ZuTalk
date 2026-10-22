# ZuTalk 0.7.9

Captions keep up however long you record, in every language.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Captions no longer fall behind as a recording grows.** In long
  recordings, especially with three languages, the transcript and the
  subtitle window slowed down a little more every minute, until the captions
  trailed the speech and ZuTalk had to be restarted. ZuTalk now redraws only
  the lines that change, so a two-hour recording stays as quick as its first
  minute.
- **Translations appear at the pace they arrive.** Subtitle translations
  are revealed against the clock and are never more than about a second
  behind, even while your Mac is busy. Thai is revealed whole word by whole
  word, with every vowel and tone mark kept on its letter; Chinese and
  Japanese character by character; English and other languages word by word.
- **No more pauses to reload a recording.** When ZuTalk was busy it could
  miss an update and reload the whole recording to recover it, which took
  longer the longer you recorded. Updates are now combined, never dropped.

## Keys

- **The model key is now a DeepSeek key.** The key you can add for cleaning
  up marked passages goes to the same service the community invitation
  uses, so a passage reads the same whichever one paid for it. A previously
  saved Anthropic key is no longer used; add a DeepSeek key instead.
- **Clearer key checks.** Each key card names its own service, and a failed
  check says once what went wrong and what to do next: add funds, raise the
  budget, replace the key, or try again later.
