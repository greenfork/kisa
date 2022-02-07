# Extensions design

This document is very incomplete.

See initial considerations of configuration in
[Configuration design](CONFIGURATION_DESIGN.md).

Configuration with a full API exposure can be considered as a plugin/script
extension. My idea is that we should have these things separate for a
number of reasons:
1. For large programs it could be very important to run asynchronously, so
   that a slow Ruby program would not freeze your editor while it tries to
   lint the code.
2. Large programs are more likely to invest into more sophisticated transport
   such as JSON-RPC via pipes or whatever we have. Thus we will not be subjected
   to implementing an "easy to use" interface via our config files.

Asynchrony traditionally adds a lot of complexity to the application. We will
explore whether we are able to solve this problem in our specific case and
not in general by providing a limited set of API endpoints to plugins. Otherwise
we might find ourselves solving the problem of simultaneous edits by
multiple users.

For additional notes see [xi article on plugins].

[xi article on plugins]: https://xi-editor.io/docs/plugin.html

As a side note there are some languages I considered as an embedded
extension language:
* [Lua]
* [Squirrel]
* [Wren]
* [PocketLang]
* [Chibi Scheme]
* [Guile]
* [mruby]
* [bog]
* [Fennel]
* [Janet]

[Lua]: https://www.lua.org/
[Wren]: https://wren.io/
[PocketLang]: https://github.com/ThakeeNathees/pocketlang
[Chibi Scheme]: https://github.com/ashinn/chibi-scheme
[Guile]: https://www.gnu.org/software/guile/
[Squirrel]: http://squirrel-lang.org/
[mruby]: http://mruby.org/
[bog]: https://github.com/Vexu/bog
[Fennel]: https://fennel-lang.org/
[Janet]: https://janet-lang.org/index.html
