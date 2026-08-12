# ZuTalk 0.4.6

Translations in a three-language recording stop far less often, and recover
when they do.

ZuTalk requires macOS 15.5 or later.

- **A recording with three or more languages keeps its translations.** Every
  connection to the transcription service needs its own key, and a community
  invitation issues a limited number per recording. A brief network hiccup
  retries the connection three times, and each retry was taking another key —
  even the attempts that never reached the service and so never used the key
  they were given. Four hiccups could exhaust a whole recording's supply, after
  which the next translation stream to reconnect was refused and stayed dark
  for the rest of the session. In a 49-minute recording, translation coverage
  held steady for twelve minutes and then went to zero. A retry now reuses the
  key its failed attempt never spent, so a hiccup costs one key instead of
  three. Recordings with one or two languages were never affected: they open a
  single connection.
- **A translation stream that is reopened now gets time to come back.** 0.4.5
  began reopening a stream that had been stopped, but allowed three attempts
  with no delay between them — all three were spent in a third of a second,
  before the replacement had finished connecting. Attempts are now spaced out,
  so a stream that fails once an hour is reopened every time, while one failing
  every fraction of a second is left alone within seconds instead of being
  hammered.
- **Diagnostics say which failure happened.** A stream that ended and a stream
  running fifty seconds behind are opposite problems, and the log recorded both
  with the same sentence. They now say which.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.
