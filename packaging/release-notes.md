# ZuTalk 0.7.7

Long recordings keep their live transcript past the third hour.

ZuTalk requires macOS 12.5 or later.

## While recording

- **Live transcription no longer stops after three hours on an
  invitation.** On an invitation, each connection to the transcription
  service may run only for a limited time — three hours, and less with
  several languages (100 minutes with three spoken languages). When that
  time ran out, ZuTalk took the closed connection for a rejected key,
  stopped transcribing for the rest of the recording and told you the
  service had rejected your key. Now every connection, in one language or
  several, moves on to a fresh one before its time is up.
- **The change-over is seamless.** ZuTalk switches connections at a pause
  in speech, after the service has confirmed everything it heard, so no
  words are lost or written twice where one connection ends and the next
  begins, and the recording bar does not flash "connecting".
- **Your own key carries on too.** The transcription service also ends any
  connection after its own maximum length; recordings on your own key now
  continue past it.
- **When invitation time really runs out, ZuTalk says so.** The recording
  bar now reads "Your invitation's time is used up" instead of claiming the
  key was rejected, and a rejected key no longer suggests your invitation
  time might be gone.

## After recording

- **The part that was not transcribed is marked.** If live transcription
  had stopped before you stopped recording, the stretch from the last
  transcribed line to the end of the recording now appears as a gap in the
  transcript, so it is clear what still needs a full transcription.
