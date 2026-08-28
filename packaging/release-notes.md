# ZuTalk 0.5.5

Fixes note corruption when typing Chinese, Japanese, or Korean.

ZuTalk requires macOS 12.5 or later.

- **Typing with an input method no longer duplicates what you wrote.** In
  0.5.4, composing a word — the moment between typing the sounds and the
  characters appearing — could be interrupted by the editor, and the input
  method would then commit the same word repeatedly. Every intermediate
  state was saved, so reopening the note showed the same mess. The editor
  now stays completely out of the way until composition finishes.

- **Notes damaged by 0.5.4 still hold their content.** The repeated lines
  were added, not written over what you had. Select across them and delete
  in one go.

- **Typing is lighter.** Keystrokes are gathered for a moment before being
  saved, instead of each key making its own round trip and its own undo
  step. Anything still pending is saved before a note closes.
