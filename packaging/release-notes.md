# Zulangue 0.2.3

This release makes the main window remember where you left it, gives the
audience subtitle window a proper maximize, finishes localizing the knowledge
base, and rebuilds how a community invitation authorizes live transcription.

- **The main window opens where you left it.** Size and position are restored
  across launches, and every window in the app now follows one shared window
  specification instead of each surface deciding for itself.
- **The audience subtitle window can be maximized and restored.** Presenting to
  a room no longer means living with whatever size the window opened at.
- **The knowledge base is localized in every shipped language.** Localization
  parity is now enforced by a build gate, so a string can no longer ship in
  some languages and not others.
- **Software updates show their download.** The sidebar reports progress while
  an update is being fetched, instead of only announcing the result once it is
  ready to install.
- **Community invitations authorize each connection separately.** An invited
  partner's live transcription now takes a single-use key per connection
  rather than one shared key for the whole recording. Recordings longer than
  an hour no longer depend on refreshing a credential before it expires, and a
  key that escapes is worth at most one stream for a few minutes.
- **After-stop transcription always runs on your own key.** Invitation time
  covers live transcription and translation. Transcribing a recorded file
  uploads that recording to the speech provider, so Zulangue asks for your own
  API key instead of doing it under someone else's account.
- **Remaining invitation time is honest about translation.** Shared time is
  spent once per translation lane, so the sidebar now reports how long you can
  actually record with the languages you have selected.

Zulangue requires macOS 15.5 or later.

This build is not notarized by Apple. If macOS blocks the first launch, open
Zulangue from Finder with **Control-click → Open**, or allow it in
**System Settings → Privacy & Security**.
