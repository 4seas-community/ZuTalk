# ZuTalk 0.7.5

Stopping a long recording no longer takes longer the longer you recorded,
and a recording writes far less to your disk while it runs.

ZuTalk requires macOS 12.5 or later.

## Stopping

- **The audio is saved as you record.** Each finished minute is stored in
  its final form while the recording runs, so Stop only has the last
  minute left to save — about the same short wait for a ten-minute call as
  for a three-hour lecture. Before, Stop went through the whole recording
  again.
- **A crash still loses nothing.** ZuTalk keeps its running safety copy of
  the audio exactly as before and recovers from it after a crash or power
  loss. If anything about the saved minutes looks wrong at Stop, it falls
  back to that copy.

## While recording

- **Much less writing to your disk.** The live transcript used to rewrite
  the topic's whole transcript — every recording in it — each time new
  sentences arrived; in a busy topic that was more than a gigabyte over
  one long meeting. It now adds only the new sentences, and the full
  transcript is written once when the recording stops.
