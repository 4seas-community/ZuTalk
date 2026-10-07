# ZuTalk 0.7.4

ZuTalk stays responsive while it records. In earlier versions a long
recording kept a whole processor core busy redrawing the live transcript,
so opening a recording or its settings during a meeting could hang.

ZuTalk requires macOS 12.5 or later.

## While recording

- **The live transcript no longer redraws itself in the background all
  meeting long.** Its header used to be measured hundreds of times on every
  update, and far more with Chinese text than with English. It is now laid
  out once per update.
- **The recording clock no longer redraws the whole window every second.**
  Only the recording bar and the sidebar, which show it, update with it.
- **A transcript you are not looking at is not laid out.** While you write
  notes or open settings during a recording, the hidden transcript waits.
- **Opening a recording's settings is lighter.** The list of microphones is
  read in the background.
- **Less disk writing during a recording.** The topic's transcript document
  is saved at most every 10 seconds instead of after every sentence.

## Stopping

- **Stopping does less work.** Matching the last translations to the
  transcript used to re-read every translation for each line; it now reads
  them once. Audio bookkeeping is saved in one step instead of one per
  minute of audio.
- **ZuTalk keeps working at full speed until Stop has finished,** even if
  you switch to another app while it saves.
- Stopping now records how long each step takes, so a stop that is still
  slow on your Mac can be traced from its log.
