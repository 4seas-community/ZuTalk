# ZuTalk 0.5.4

Session notes are an editor now.

ZuTalk requires macOS 12.5 or later.

- **You can select across lines.** Selecting a passage that spans several
  lines and copying it was previously impossible — every line was its own
  input field, and a selection could not leave one. The notes surface is now
  a single text view, which also brings back cut, drag-to-move text, spell
  checking, input-method candidates, and Find (⌘F).

- **Return splits a line where the cursor is.** It used to commit the whole
  line and add an empty one below, wherever the cursor happened to be. Text
  after the cursor now moves to the new line, and the cursor lands there.

- **Typing right after Return or a merge no longer loses characters.** Focus
  used to arrive a beat late, and anything typed in that gap went to the
  previous line — which is what made fast typing feel unreliable.

- **Pasting a list gives you a list.** Multi-line text used to land in one
  line as a single run with newline characters in it. Each pasted line now
  becomes its own line, headings and checkboxes included.

- **Up and down arrows move between lines** instead of stopping at the edge
  of one.

- **Bold, italic, inline code, links, and @mentions render inside a line**,
  and a line can be a code block. Links open only for http and https.

- **Undo, redo, and indent are visible buttons** above the notes, with their
  keyboard shortcuts in the tooltips. They existed before, reachable only if
  you already knew the shortcut.
