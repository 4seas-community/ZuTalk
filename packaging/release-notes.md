# ZuTalk 0.4.1

This update finishes the move to the ZuTalk name, including the services used
for sharing, web captions, and community invites. It also keeps a live-caption
row in speaking order when the transcription provider omits its timestamp.

ZuTalk requires macOS 15.5 or later.

- **Update before starting a new shared room.** Sharing, web captions, and
  community invites now use ZuTalk service addresses. Versions 0.4.0 and older
  still contain the retired Zulangue addresses, so those online services stop
  working for them after the service move. Macs that share across networks
  should update together.
- **Create a new web-caption link after updating.** QR codes and viewer links
  created by older versions contain the retired caption address and cannot be
  redirected. Start a new web share in 0.4.1 to create a working link.
- **An untimed live-caption row stays where it was spoken.** A provider response
  can occasionally omit timing metadata. That row used to fall to the bottom of
  the audience canvas, below sentences spoken minutes later. It now inherits an
  ordering bound from the row ahead of it, without inventing a timestamp or
  changing the saved transcript and subtitle exports.
- **The icon caught up with the name.** 0.4.0 renamed the app everywhere the
  name was text — menus, windows, the shared caption page. It could not rename
  the one place the name was a picture: the lettering is drawn into the icon's
  pixels, so the Dock, Finder, the About window and the update prompt all kept
  showing the old name. They now say ZuTalk.
- **If you still see the old icon, macOS is showing you a cached copy.** Log
  out and back in, or restart, and it will refresh. Nothing is wrong with the
  update.
