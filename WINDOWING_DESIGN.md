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
