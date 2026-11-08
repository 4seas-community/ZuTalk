# ZuTalk 0.7.14

Recordings write their sound to disk once instead of twice.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Recordings write half as much audio to disk.** ZuTalk used to save
  every recording's sound twice: once as it came in, so that nothing would
  be lost if ZuTalk stopped unexpectedly, and then again, minute by minute,
  into the files it keeps. It now saves each moment once, straight into
  those files, encrypted as before. A three-hour recording writes about
  350 MB less; together with the change in 0.7.13, a long recording now
  writes roughly a third less than it did before.
- **An interrupted recording is still recovered in full.** If ZuTalk or
  your Mac stops during a recording, everything saved until then comes back
  the next time ZuTalk opens, each part at the time it was recorded.
