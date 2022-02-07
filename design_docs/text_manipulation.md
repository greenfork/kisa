# Text manipulation design

There are 3 commands to directly manipulate the selection of
text in the buffer (even if the selection is of size 1):
* Delete - just remove the text from the buffer
* Cut - remove the text from the buffer and insert it into a cut history
* Paste - put the text in the buffer from the cut history

Normally you would want to cut the text instead of deleting so that it
is saved in the history and can be later used for insertion.

After pasting the text there's another command Paste-Cycle which changes
the inserted text to the older entry in the cut history.

## Clipboard integration

Clipboard integration is active by default but it can be deactivated.

Each expansion/detraction of the selection with the size of more than 1
also copies this text to the "primary" selection of the system if that
selection is supported. On X system this selection can be pasted to other
applications by clicking a mouse middle button.

Delete command does not interact with the system clipboard.

Cut command also puts the text into the "clipboard" selection of the system.
This selection can be normally inserted with the Ctrl-v shortcut.

Paste command first checks the "clipboard" selection of the system, and if
there's text present, it is inserted to the buffer. If there's none, then
the text is inserted from the cut history.
