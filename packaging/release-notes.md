# ZuTalk 0.8.3

Every screen was gone through with one rule: a control says what it is in a
word and shows its current value, and nothing asks to be read before it can
be used. Filing to a city's archive changes too: marks are no longer filed,
and a recording's audio can be.

ZuTalk requires macOS 12.5 or later.

## Filing to a city's archive

- **Audio can be filed, and is by default.** When a recording is filed to a
  city event, its audio now goes with the transcript, so the archive page
  plays it. Turn it off for everything in Settings › Account › Archive, or
  for one recording from the event control on Home, from the recording bar
  while you record, or from the recording's Share sheet afterwards. A
  recording filed before this version gets its audio only when you choose
  Add audio.
- **What that means.** Filed audio is public to anyone with the page, and
  nothing in ZuTalk or on the city's page can delete it today: withdrawing a
  recording takes it off the archive page, and the text and audio already
  filed stay in the city's records. The city's hosts can also have it
  transcribed again from that audio. Share links, sync between your Macs and
  handing a transcript to a nearby Mac still never carry audio.
- **Marks are no longer filed.** The option is gone. Marks filed by earlier
  versions stay in the city's records.
- **Audio has its own status.** A recording shows whether its audio is being
  sent, was filed, is waiting, or was not accepted; text that was filed is
  never reported as failed because its audio was not.
- **Deleting a recording's audio says what it does.** If that audio was
  already filed, the question now adds that the copy in the city stays.

## Starting a recording

- **The settings are on the card.** Under Start Recording, each language is
  a pill you remove with × and add with +. A second row holds the sound
  source, live text, the topic and hosting; a third row appears while you
  host, with the event. There is nothing to expand, and no sentences to
  read; what a control does is in its tooltip.
- **Import** sits at the end of the first row.

## The same treatment everywhere

- **Recordings list.** A row is a name, its languages and its topic, with at
  most one status. Filters shorten long topic names and fold the rest into
  one menu.
- **After Stop.** The card is a title and one row: Copy, Export, Share,
  Refine, and the archive status.
- **A recording.** A pill shows which version you are reading. The ⋯ menu is
  short words: Copy, Share, Export · Rename, Topic, Details · Delete audio,
  Delete. Details are three groups of plain rows.
- **Topics.** A topic's options are four rows: languages (the same pills as
  on Home), sound, terms and background, audio. Topics, Trash, terms and
  collaboration lost their paragraphs.
- **A transcript's two versions** are called the live version and the
  refined transcript everywhere; in Chinese the live one is now 现场稿.
- **Showing captions and sharing.** The panels show the code, the link and
  the actions, with three facts in a line — no audio, end-to-end encrypted,
  how long it is kept — and the details behind an ⓘ.
- **Caption window.** Hovering shows the status, the recording controls,
  the layout switch and the text size; the rest is in one ⋯ menu.
- **Settings and first launch.** Rows are a name and a control. Account is
  four groups: Identity, Live text, Devices, Archive. Each first-launch step
  is a title and its control.
- **Explanations moved, none were dropped.** What used to sit under a
  control is in its tooltip; anything you need to know before something
  leaves this Mac or cannot be undone is behind an ⓘ beside the control or
  in the confirmation.

## Fixes

- Sentences that said audio never leaves this Mac, or only stays on the Mac
  that recorded it, now say exactly what they cover: links, sync and
  nearby hand-off carry no audio. One status word in Chinese that read as
  "confiscated" was replaced.

- The topic page's Start Recording button no longer looks like a recording
  in progress.
- The caption window's layout switch no longer stretches its hover bar.

Nothing in this version was clicked through in a running app before
release; it was checked with tests and rendered screens. Wording in
languages other than Chinese and English was written and reviewed by
models, not by native speakers.
