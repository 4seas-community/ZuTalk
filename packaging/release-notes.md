# ZuTalk 0.7.15

When your Mac is offline, ZuTalk now says so, instead of making it look like
the transcription service is down.

ZuTalk requires macOS 12.5 or later.

## When there is no network

- **The Start Recording page warns you first.** If live captions are on
  and your Mac isn't connected to the internet, the page says so before you
  press Record, and reminds you that you can turn captions off and record
  without them.
- **The recording bar says "No network".** If the connection drops during
  a recording, the captions status shows "No network" instead of "Captions
  connecting", and a line under the header explains that recording
  continues and captions pick up again by themselves once you're back
  online.
- **Invite codes no longer blame the code or the service.** Without a
  connection, entering an invite code used to say the code was invalid,
  and starting a recording with captions said the community service was
  unavailable. Both now say your Mac is offline. ZuTalk also no longer
  switches such a recording to your own saved key, which could not have
  connected either.
