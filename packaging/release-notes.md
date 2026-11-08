# ZuTalk 0.7.13

A recording keeps going when another app takes the microphone.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Recordings no longer go silent when another app takes the
  microphone.** When an app such as a video-call or messaging app started
  using the microphone, macOS stopped ZuTalk's audio, and ZuTalk carried on
  showing a running recording while capturing nothing — in one case for 45
  minutes. ZuTalk now notices within a second, starts the microphone again,
  and keeps the recording's timeline in step with the clock. If the
  microphone cannot be brought back, the recording ends with a message that
  says so, and everything recorded until then is kept.
- **Long recordings write much less to disk.** Every live caption update
  rewrote parts of the database that had not changed. A three-hour,
  three-language recording wrote about 2 GB and made macOS report ZuTalk
  for heavy disk use; the same recording now writes roughly a fifth less.
- **Coming back to a recording's window is less likely to freeze it.**
  Returning to ZuTalk during a recording, for example from a full-screen
  video call, once froze the window for over twenty seconds. The most
  likely cause — the live transcript laying itself out again every time it
  scrolled — is gone: it now redraws only when following the newest line
  actually starts or stops.

## If ZuTalk stops responding

- **ZuTalk now records where it got stuck.** If its window stops
  responding for more than two seconds, ZuTalk saves a short technical
  sample of what it was doing to its log folder, so the cause can be found
  and fixed. The sample contains no part of your recordings or notes.
