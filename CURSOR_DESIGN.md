# Cursor design

Cursor is always a part of a selection, where cursor is at the head of a
selection and anchor is at the end of a selection. There's always at least
a single selection present, called "primary" selection. Selection is
a range of characters between the cursor and the anchor. In the simplest
case cursor and anchor are at the same position, so the selection is only
1 character.

Here `&` is an anchor, `|` is a cursor, `.` are any characters in between them:
```
&...|
^ anchor
    ^ cursor
^~~~~ selection of 5 characters
```

Initially cursor and anchor are at the same position and move together but the
selection can be "anchored", then only cursor's position is updated.

## Movement

Moving up and down one line should do what is says if there's a character
displayed one line above or below. If there's no character right above/below
the cursor, the cursor should move to the last character of the line.

During the whole movement of up and down, the cursor should save the column
at which it started moving, meaning that the column shouldn't be reset to 1
if the there's an empty line above and cursor makes movement up, down. The
column should only be reset when moving left, right and doing any other
command that changes its position.

Following considerations apply when the cursor is at the end of a line:
- At the position of a newline "\n" character - cursor should move to the
  newline character above or below if the current line is longer. Option
  `track-eol` makes the cursor always follow the end of line, no matter
  the line length.
- At the position of the last character in a line, right before the newline
  "\n" character - cursor should move to the last character of the line if
  the current line is longer.

Moving up and down should move one line above and below, where line means
an array of bytes ending with a newline "\n" character. But there should
also be a special "display movement" which moves up/down one "displayed"
line which takes effect when line wrapping is enabled.

### Examples

In format: initial state, commands, final state, where `|` describes the
character position.

1.
```
1 first line
2 second long lin|e
```
`up`
```
1 first lin|e
2 second long line
```

2.
```
1 first line
2 second long line|
```
`up`
```
1 first line|
2 second long line
```

3.
```
1 lo|ng long long wrapped
  line
2 second line
```
`down`
```
1 long long long wrapped
  line
2 se|cond line
```

4.
```
1 lo|ng long long wrapped
  line
2 second line
```
`display down`
```
1 long long long wrapped
  li|ne
2 second line
```

## Multiple cursors

Multiple cursors - an interactive way of executing substitute/delete/add
operations.

One and only one cursor is always "primary" which means that it gets a
special treatment when we add or delete new "secondary" cursors.

There are 3 main ways of creating multiple cursors:
1. Create a cursor above current primary cursor - primary cursor moves 1 line up,
   secondary cursor is placed in its previous place.
2. Create a cursor below current primary cursor - primary cursor moves 1 line down,
   secondary cursor is placed in its previous place.
3. Create cursors which match the entered expression - in the selected area, or
   in the whole file (line?) if nothing is selected, run a regex expression and place
   1 cursor at the beginning of each matched string.

Cursor movement described above also applies to cursor creation (1) and (2).
There's no way to create multiple cursors at `display down` location. When
doing reverse operations, for example after (1) follows (2), the previous
operation should be cancelled. In simpler terms it means that the primary
cursor "eats" secondary cursors in this case.

After executing (3) the primary cursor is placed at the very last match of a
selection/file, all previous cursors are secondary. This may also include
cases when secondary cursors are off the visible area of the screen. The
screen display always follows the primary cursor.

### Examples

In format: initial state, commands, final state, where `|` describes the
primary cursor and `&` describes secondary cursors.

1.
```
1 fir|st line
2 second long line
3 third line
```
`create-cursor-down`
```
1 fir&st line
2 sec|ond long line
3 third line
```
`create-cursor-down`
```
1 fir&st line
2 sec&ond long line
3 thi|rd line
```
`create-cursor-up`
```
1 fir&st line
2 sec|ond long line
3 third line
```

2.
```
1 fir|st line
2 second long line
3 third line
```
`select l[io]n[eg]`
```
1 first &line
2 second &long &line
3 third |line
```
