# Lines design

## Numbering

* Absolute line numbers.
* Relative line numbers.
* Visual absolute line numbers which account for folding.
* Visual relative line numbers which account for folding.

Some considerations:
* A special case of folding is narrowing, when only a specific part of the file
  is visible in the buffer. However it doesn't add a new type of numbering.

## Wrapping

* Don't wrap, display indicator that the line is longer than the screen.
* Wrap at the visual line end.
* Wrap at the nearest to the line end blank character.
* Wrap at the nearest to the line end blank character but also redefine
  various commands to operate on visual lines instead of logical lines.

Some considerations:
* There could be a setting which inserts newlines when the line becomes too long.

## Questions
* Which commands operate on logical lines and which commands operate on visual
  lines? In Vim there's a special sequence for up/down keys to operate on visual
  lines. In Emacs up/down by default operates on visual lines but all other
  commands always operate on logical lines. Are there any others commands which
  make sense to also customize with different operation modes?
