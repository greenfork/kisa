# Windowing design

In some work flows it is desirable to have several editor windows open
side-by-side: either implementation and test file, or different parts
of the same file in case it's 10k lines long. Certainly there are tools
to help with that such as a list of opened files and switching between
current and last opened file, but sometimes it doesn't cut all the cases.

I see 2 main approaches to windowing: leaving it to the third-party tools
and integrating it into the editor.

## Third-party tool approach

There are a lot of approaches:
* Delegating it to the window manager, probably tiling, from [dwm] and [i3wm]
  for X to [Sway] and [river] for Wayland and million others, pick your poison
* Delegating it to the terminal multiplexer such as [tmux], [screen] or [dvtm]
* Delegating it to the virtual terminal emulator such as [kitty], [Terminator]
  or [Tilix]

[dwm]: https://dwm.suckless.org/
[i3wm]: https://i3wm.org/
[Sway]: https://swaywm.org/
[river]: https://github.com/ifreund/river
[tmux]: https://github.com/tmux/tmux
[dvtm]: https://www.brain-dump.org/projects/dvtm/
[screen]: https://www.gnu.org/software/screen/
[kitty]: https://sw.kovidgoyal.net/kitty/
[Terminator]: https://gnome-terminator.org/
[Tilix]: https://gnunn1.github.io/tilix-web/

The main requirement is to be able to hook the new editor session into the
existing session. Since this editor has a client-server architecture, this
is no problem, we just need to supply a server identifier. This approach
is easy and mostly solved by others, we can as well capitalize on their
success.

## Builtin windowing functionality

There are several use cases for having windowing functionality builtin into
the editor:
* Temporary windows with error messages or help windows
* There are interactions such as searching which can be applied across
  several windows
* Some people prefer all-in-one experience for a text editor, such as
  [VSCode]
* GUI clients won't have most of the niceties which are available for
  terminal clients

[VSCode]: https://code.visualstudio.com/

Looking at it from this point there are definite benefits of integrating
windows into the editor. Even with all the third-party tools in the world
it would be convenient to have temporary windows for tool integrations
and better communication with the user of the editor about errors or
help messages.

A note on tabs. I have no idea how to use tabs more than just switching
between them. This is a sign that tabs are probably not integral to the
editor and can be off-handed to external tools: for terminal clients it
would be a large ecosystem of all the solutions listed above, for GUI
clients unfortunately they will have to implement this functionality
themselves.

There's also a choice whether the server needs to know about windows or
if the windows should be fully offloaded to the client. This is likely
to be determined during implementation, TODO.

There are several types of interactions we would like to have with the
windows, let's enumerate them.

### Consistent windows with information

Consistent windows are only closed when the user specifically issues
a command to close the window. Examples:
* Another window for editing and opening files
* grep search buffer
* git diff
* Help buffer

These are just usual windows which don't require any specific functionality.

### Temporary info windows

Temporary info windows appear and close based on some events happening
in the editor. Examples:
* Compilation errors
* Test failures

These windows will have to be somehow identified and remembered when they
are created and later closed as a consequence of processing events on the
server. Most of the complexity of implementing these windows lies in
the event processing but should be doable.

### Temporary prompt windows

Temporary prompt windows require some user action before they are closed,
typically the result of an action is then somehow used. Examples:
* Fuzzy search with a third-party utility like [fzf] or [skim] and then
  opening of a file
* Writing commit messages with version control tool

[fzf]: https://github.com/junegunn/fzf
[skim]: https://github.com/lotabout/skim

The window should be opened which gives full control to the third-party tool
and the result is later piped into the editor and used appropriately. This
is the most complicated implementation but at the same time it should be
worth it. Alternative implementations have to either [rely on
extension language], they have to be [overly complicated] or they
have to use [scary bash scripts]. Every option seems subpar for such a common
workflow.

[rely on extension language]: https://git.sr.ht/~mcepl/vis-fzf-open/tree/master/item/init.lua
[overly complicated]: https://github.com/andreyorst/fzf.kak/blob/master/rc/fzf.kak
[scary bash scripts]: https://github.com/greenfork/dotfiles/blob/efeeda144639cbbd11e3fe68d3e78145080be47a/.config/kak/kakrc#L180-L188

It is worth saying that [fzf] and similar programs provide quite a core
workflow of finding specific files in the project either by content or
by filename.
