# ZuTalk 0.7.12

Long speeches keep breaking into readable lines, even when the connection is slow.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Long speeches break at pauses more reliably.** Now and then the
  transcription service did not answer ZuTalk's request to end a line, and
  ZuTalk waited for that answer for up to a minute; a speech could then run
  on as one line of 20 seconds or more. ZuTalk now asks again at the next
  pause.
- **Lines break as soon after a pause on a slow connection.** When the
  service ran a few seconds behind, each new line had to run those extra
  seconds before it could be ended. Lines are now timed from where the
  service actually ended the last one.
- **Translations keep their place when the service skips an answer.** A
  missed answer could have shifted every later line's timing, putting
  translations against the wrong lines. The timing now stays correct.
