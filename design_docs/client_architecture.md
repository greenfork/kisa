# Client design

## Server vs Client responsibility

Since we have Client and Server who communicate with each other, we have a
constant question: "Who is responsible for X?" This X includes but is not
limited to:
* Line numbering
* Line wrapping 
* Git blame output 
* LSP/linter output 
* Indentation guides

Each case has its own pros and cons.

### Line numbering

Figures (usually at the left) of the main window with text which indicate the
number of the corresponding line.

On the Server advantages: 
* Client doesn't need to handle different options and settings. For example,
  there are several ways to display line numbers: absolute and relative values.
  This setting won't have to be implemented on each client, the server has to
  only implement it once and for all.

On the Client advantages: 
* Different clients might have different ideas about how to display the data.
  Making implementation client-specific adds more configurability and more
  choices to the implementators of clients which might make it more appealing to
  develop a third-party frontend.

Conclusion: on the **Server**. Even though Clients have more freedom otherwise,
it is not the most particularly interesting thing to implement in my opinion. We
would win more from uniform data, Clients can handle different display options
still. Later we can optionally provide the data in 2 separate streams: line
numbers and text buffer, - so that clients have full control over it, but for
the start we should minimize our efforts.

### Line wrapping

When text in the main window is too long and we decide to wrap the text line to
the next display line so that we don't need to scroll horizontally.

On the Server advantages: 
* With soft wrapping of lines moving the cursor up and down is implemented on
  the server, it is easier for Clients. This is a hard problem to solve since
  proper calculation may include calculating grapheme clusters which is not
  trivial at all.

On the Client advantages: 
* Data to draw is more uniform, there's no special case for wrapped lines.

Conclusion: on the **Server**. Calculating grapheme clusters is really not the
domain of a Client, it is horrible of the Server to ask the Client to implement
it. Server must send the data where the soft-wrapping occurs.

### Git blame output

`git blame` is a Git version control command which displays the meta-data of
commits corresponding to each line in the file.

Conclusion: calculate on the **Server**, display control is fully on the
**Client**. We will have to communicate with the `git` command-line program and
this is better done on the Server. But the Server will send the data separately
from the draw data, so the Client will be able to display it however it
pleases. There's a problem that, for example, line wrapping interferes with this
functionality if the Client decides to display blame data side-by-side with the
code. How to solve it? Client must send to the Server updated main window width
after it will display the blame data, so the Server will do the wrapping with an
updated window width.

### LSP/linter output

Language server protocol and different linters provide contextual information
which is usually attached to the lines of code and displayed on the left or as
underline of the relevant piece of code.

Conclusion: calculate on the **Server**, display control is fully on the
**Client**. Reasoning is same as for **Git blame output** since the Server does
communication with the LSP/linter and Client only sends the correct dimensions
to the Server.

### Indentation guides

Indentation guides are lines or colored blocks inside the main window which
indicate the current indentation level of code. This is especially useful for
languages with significant indentation such as Python, Nim, but it is also
useful for any language because they all keep correct indentation as a good
syntax rule.

Conclusion: on the **Client**. Since the only thing we have to do is to replace
spaces with colored blocks or some Unicode characters which are going to
indicate the indentation level, there's not much work to do. The Server doesn't
need to know about it at all.

## Communicating changes to the server

Client will send each key press to the server and wait for response back.
This might seem slow and inefficient but there's no way to implement some
features without it like autocompletion. Nowadays computers should be
fast enough to handle it. It is also the way how remote terminals work
in some implementations.

This can make it unusable for network editing when the server is somewhere
on the internet. And it can also make a difference for low-end hardware,
where the problem could be a visible lag between key presses.

But we have a solution. The solution is to provide a "threaded" mode which will
only handle a single pair Client-Server without any way to attach additional
Clients to the Server. In "threaded" mode Client-Server pair will be just
different threads and not different processes. This will allow them to use some
other form of IPC instead of TCP sockets. But this is still very far in the
future. Are we even going to hit the barrier when the editor is going to be slow
and communication is going to be the slowest part? I don't know. Let's try to
move to this direction once it happens. But "threaded" mode is still better for
development since it is easier to debug a single-process application. Would be
even better to have a single-threaded application but the Server architecture
does not really allow for it that easily. IPC - let's leave it for later, for
now TCP sockets are our friends.

Another solution is to go full async: process updates asynchrounously but it has
a really big spike in complexity, mainly because we need Operational
Transformation or CRDT or another smart word to resolve the difference between
the changes the client has made so far with the data that the server knows
about.

It is wise to structure the client and the server in a way which will
allow to eventually switch to this approach but right now it is definitely
not the right time to implement it.

See [xi editor revelations](https://github.com/xi-editor/xi-editor/issues/1187#issuecomment-491473599).

### Terminal display and input library

Editors written in other than C languages such as Go ([micro], [qedit]) or Rust
([helix], [amp]) use their own library which implements terminal display
routines. C/C++ based editors largely use [ncurses] library ([vis], [neovim]),
but there's a good exception to this rule which is [kakoune]. Since current
editor's language of choice is Zig, there are 2 choices: port ncurses library
and write our own. I tried to [port the ncurses library] but eventually gave up
because of infinite confusion with it. The code is also quite and quite hard to
understand, there's an [attempt to make it better] but it is sadly not packaged
at least on Arch Linux distribution which could be a problem. I decided that we
should implement the library that is going to provide just the necessary for us
features. But here we are not alone, a fellow _zigger_ presented the [mibu]
library which implements low-level terminal routines, just what we need. In any
case, we can always fork and extend it.

Terminal input story is similar, other than C languages implement their own
libraries which seems necessary for them anyway. The C land has [libtermkey]
which is contrary to ncurses has pretty good source code, it is used at least by
[neovim] and [vis]. But the state of this library is a little bit questionable,
end-of-life was declared for it at least since 2016 and the original author
advertises their new [libtickit] library which tries to be an alternative
library to ncurses but as I see it didn't get wide adoption. Libtermkey is alive
as a [neovim fork] however so this could be a viable option nonetheless. But
again, implementing this library seems rather straightforward as demonstrated by
[kakoune] and there are some new ideas about the full and proper representation
of keypresses, see [keyboard terminal extension] by the kitty terminal. I think
it is okay to try to port the libtermkey library at first and see how it goes,
but further down the road I think it is still valuable to have our own library,
in Zig.

We will do everything in Zig (eventually). Hooray.

[ncurses]: https://en.wikipedia.org/wiki/Ncurses
[libtermkey]: http://www.leonerd.org.uk/code/libtermkey/
[port the ncurses library]: https://github.com/greenfork/zig-ncurses
[libtickit]: http://www.leonerd.org.uk/code/libtickit/
[neovim fork]: https://github.com/neovim/libtermkey
[keyboard terminal extension]: https://sw.kovidgoyal.net/kitty/keyboard-protocol.html
[attempt to make it better]: https://github.com/sabotage-linux/netbsd-curses
[mibu]: https://github.com/xyaman/mibu

[Kakoune]: https://github.com/mawww/kakoune
[amp]: https://github.com/jmacdonald/amp
[vis]: https://github.com/martanne/vis
[micro]: https://github.com/zyedidia/micro
[vy]: https://github.com/vyapp/vy
[neovim]: https://github.com/neovim/neovim
[helix]: https://github.com/helix-editor/helix
[xi]: https://xi-editor.io/
[qedit]: https://github.com/fivemoreminix/qedit
[kilo]: https://github.com/antirez/kilo
[moe]: https://github.com/fox0430/moe
[paravim]: https://github.com/paranim/paravim
[focus]: https://github.com/jamii/focus
[Emacs]: https://www.gnu.org/software/emacs/
[joe]: https://joe-editor.sourceforge.io/
[TextMate grammar]: https://macromates.com/manual/en/language_grammars


### Where is it going to run?

Since the initial implementation is going to be a terminal-based client, we
will strive for the highest common denominator of all terminals, some popular
choices:

* [Foot]
* [Alacritty]
* [Kitty]
* [Urxvt]
* [iTerm2]
* [tmux]
* [xterm]... oops sorry, [this is the one]
* [cygwin] - this is a terminal for Windows, a hard battle for sure

[Foot]: https://codeberg.org/dnkl/foot
[Alacritty]: https://github.com/alacritty/alacritty
[Kitty]: https://sw.kovidgoyal.net/kitty/
[Urxvt]: https://wiki.archlinux.org/title/Rxvt-unicode
[iTerm2]: https://iterm2.com/
[tmux]: https://github.com/tmux/tmux
[xterm]: https://github.com/xtermjs/xterm.js/
[this is the one]: https://invisible-island.net/xterm/
[cygwin]: https://www.cygwin.com/
