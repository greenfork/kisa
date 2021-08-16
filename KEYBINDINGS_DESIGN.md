# Keybindings design

Keybindings should allow the user of the editor to quickly navigate and edit
file as well as provide capabilities for composing green field projects
efficiently. Modal text editing is in generally more
convenient for modifying and navigation whereas modeless editing
is more convenient for when one needs to write a lot of text
[[Merle F. Poller and Susan K. Garter. 1983. A comparative study of moded and modeless text editing by experienced editor user]].
This is a modal text editor, hence we should excel at modifying and navigating
the text, this is the main priority. Consequently making writing projects from
scratch convenient is not the highest priority but there's still a lot of room
for improvement upon the simplest "can insert in Insert mode" case.

Next we define several modes
of user input which we use to compactly and intuitively assign keys to actions:
* Action - just as simple as it sounds, a key press results in an
  immediate action.
* Activate/enable mini-mode - pressing the key enters a mini-mode
  which has its own keybindings and the next key press (or all next keys pressed
  until exited if we "enable" it, not just "activate") is interpreted
  according to the mini-mode keymap.
* Number modifier - pressing numbers creates a numeric argument which will be
  passed to the next command if that command accepts such an argument.
* Prompt - pressing the key expects further input, longer than 1 character.
  Example can be searching or entering a command.

The logic for assigning keys to actions is as follows: the most frequently
used actions must be the easiest ones to type. There are some keys which we
can inherit from the Vim editor like cursor movement with hjkl. Keys which
activate mini-modes must be mnemonic as opposed to keys which do just a single
action - these keys are generally learned and it is only beneficial to make
them mnemonic for learning purposes.

**I don't have information regarding the validity of the following claim,
only empirical evidence**.
There are expected to be a lot of 2-key combination for commands from the
sequence "activate mini-mode"->"action", it is beneficial to make them
easy to type. General strategies are:
* 2 buttons are pressed by different hands with the second hand using point
  finger or middle finger.
* 2 buttons are pressed by the same hand with first finger being the point
  finger.
* 1st button is a space, then hands can conveniently press any other button.
  This is the only universal solution which works for Qwerty, Dvorak, Workman,
  Colemak and whatnot other English language keyboard layout.

Modifier keys (Ctrl, Shift, Alt) should have minimal usage in Normal mode,
2 button combination via mini-mode should be preferred. The reason is that
modifier key can be counted as a key press but in addition to 2 button
combination you also have to keep the button pressed which is suboptimal
for ergonomics. But in Insert mode modifier keys can be used for cursor
movement (readline-style or emacs-style) and different operations since
there's really no other choice. Some examples for Insert mode:
* Ctrl-n - move cursor down
* Ctrl-p - move cursor up
* Ctrl-f - move cursor forward
* Ctrl-b - move cursor backward

Some considerations on using Shift modifier key in Normal mode: it is used
to define an "opposite" or "reversed" action for the small-letter counterpart.
Examples, but not necessarily current keybindings:
* u, U - undo, redo
* n, N - search forward, search backward
* s, S - save, save as
* w, W - move forward one `word`, move forward one `WORD`, same for b, B
* z, Z - activate mini-mode, enable mini-mode

Exceptions:
* /, ? - should probably mean different things. So the rule only works for
  letters.

Other than English languages can have their keymaps too. We don't need to
support it extensively but there's a neat solution in Vis editor (maybe others)
with command `:langmap ролд hjkl` which maps 4 not English characters to their
English counterpart. Alternatively we can allow non-ascii characters in keymap
config file. These solutions are not applicable to all languages and maybe
for now this is alright.

[Merle F. Poller and Susan K. Garter. 1983. A comparative study of moded and modeless text editing by experienced editor user]: https://doi.org/10.1145/800045.801603

## Frequent actions
Will be assigned a single key press.

* Move cursor up
* Move cursor down
* Move cursor left
* Move cursor right
* ...

## Not so frequent actions
Will be grouped together into a mini-mode where possible, used with a Shift
modifier or assigned one of ~!@#$%^&*()_+ buttons (also with Shift :) ).

* Move cursor to the end of line
* Move cursor to the start of line
* Move cursor to the first non-space character of a line
* Move cursor to the first line of a buffer
* Move cursor to the last line of a buffer
* List buffers
* Switch to buffer [buffer]
* Switch to last opened buffer
* Switch to next buffer
* Switch to previous buffer
* Switch to scratch buffer
* Switch to debug buffer
* Delete current buffer
* Delete buffer [buffer]
* Delete all buffers but current
* Edit file [path]
* ...

## Infrequent actions
Will only be available via a manual command prompt where you have to type the
name of the command in order to execute it. This is also more flexible since
some commands may require an argument. Although it is possible to pass an
argument to a command in the config file.

All the commands above should be available via manual prompt of a command
(as when pressin `:` in Vim). Any additional actions are available here
as well as available to be bound to a key in the config file.
