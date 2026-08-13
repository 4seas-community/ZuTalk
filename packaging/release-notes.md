# ZuTalk 0.4.7

Translations now appear next to the sentence they translate, or not at all.

ZuTalk requires macOS 15.5 or later.

- **A translation no longer lands on the wrong line.** With three or more
  languages, each translation arrives on its own connection to the
  transcription service, and those connections do not agree on the clock —
  they drift a second or two apart over a few minutes. Deciding which
  transcript line a translation belonged to could fall back to that clock, and
  in conversation, where lines are about two seconds apart, a drifted
  translation lands on the next line and looks entirely convincing there. In
  one recording, two thirds of the translations shown were on the wrong line,
  a third of them exactly one line late — which reads as a translation column
  that has slipped and never recovers.

  Which line a translation belongs to is now decided by the words. Timings
  still order the candidates and still rule out lines that were spoken at a
  different moment, but they can no longer choose a line on their own.

- **Some lines will now show no translation where they used to show one.**
  This is the intended trade. A translation with nothing to tie it to a
  specific line is held rather than guessed, and a later correction from the
  service can still place it. A translation put on the wrong line cannot be
  taken back — it is on screen, next to words it does not translate. Very short
  lines are the ones most often left blank: "yes", "right", a name on its own
  carry too little to identify which line they came from.

Still on 0.3.x? Those installs cannot be updated automatically — 0.4.0 renamed
the app and its bundle identifier together, so Sparkle no longer recognises the
update as a replacement for what is on disk. Download the DMG once by hand and
automatic updates resume from there.
