# Kisa

Kisa is a hackable and batteries-included text editor of the new world.

Home repository is on [sourcehut] but there's also a mirror on [GitHub].

[sourcehut]: https://git.sr.ht/~greenfork/kisa/
[GitHub]: https://github.com/greenfork/kisa

Kisa is in its early stage and it is not usable at the moment. See [roadmap]
for the current progress.

[roadmap]: https://greenfork.github.io/kisa/ROADMAP.html

There's a growing set of design documents, beware most of it is not implemented.
It will be further moved to a more appropriate place.
* [Cursor design](CURSOR_DESIGN.md)
* [Client architecture design](CLIENT_ARCHITECTURE_DESIGN.md)
* [Configuration design](CONFIGURATION_DESIGN.md)
* [Highlighting design](HIGHLIGHTING_DESIGN.md)
* [Keybindings design](KEYBINDINGS_DESIGN.md)
* [Server architecture design](SERVER_ARCHITECTURE_DESIGN.md)
* [Windowing design](WINDOWING_DESIGN.md)
* [Search design](SEARCH_DESIGN.md)
* [Extensions design](EXTENSIONS_DESIGN.md)

## Purpose

I, greenfork, the one who started this project, would like to have a
supreme code editor. I want to edit code with pleasure, I want to know
that whenever I feel something is not right - I have enough power to fix it,
but with great power comes great responsibility. I shall wield this power
with caution and I shall encourage my peers and empower them to follow
my steps and eventually let them lead me instead of simply being led.

## Zen

* Programmer must be able to perfect their tool.
* Choice is burden.
* Choice is freedom.

## Goals

* Provide a powerful and flexible code editor - obvious but worth saying,
  we should not provide anything less than that.
* Identify common workflows and set them in stone - text editing has become
  quite sophisticated in this day and age, we have already discovered a lot
  of editing capabilities. Now is the time to make them easy to use and fully
  integrated with the rest of the features of the editor, not rely on
  third-party plugins to emulate the necessary features.
* Adhere to hybrid Unix/Apple philosophy - programs must be able to communicate
  with each other, the editor must make integrations with other tools possible,
  this is from Unix philosophy. At the same time the editor must be built from
  ground-up and have full control of all its core features to provide a
  single and uniform way of doing things, this is from Apple philosophy.
* Make it infinitely extensible by design, no hard assumptions - the only types of
  unimplementable features are those which were not accounted for from the
  very beginning and got hardblocked by design decisions which are interleaved
  with the rest of the editor, so changing it is not feasible. The solution
  is simple - layers and layers of abstractions, assumptions are strictly
  kept to minimum by careful thinking about the public API design of each layer.
* Make it hackable - I believe there are several key points to make an editor
  hackable: interesting design, clean code, extensive development documentation,
  friendly attitude to anyone trying.

## Communication

* <~greenfork/kisa-announce@lists.sr.ht> - readonly mailing list for rare
  announcements regarding this project, [web archive][announce-list]. Subscribe
  to this list by sending any email to
  <~greenfork/kisa-announce+subscribe@lists.sr.ht>.
* <~greenfork/kisa-devel@lists.sr.ht> - mailing list for discussions and
  sending patches, [web archive][devel-list]
* <hello@greenfork.me> - my personal email address
* [Discord] - real-time chatting experience
* [Twitch] - occasional streams including editor development
* [YouTube] - recordings of past streams and other related videos

Please be kind and understanding to everyone.

Are you new to mailing lists? Please check out [this tutorial](https://man.sr.ht/lists.sr.ht/).
There's also the [in-detail comparison video](https://youtu.be/XVe9SD3kSR0) of pull requests
versus patches.

[announce-list]: https://lists.sr.ht/~greenfork/kisa-announce
[devel-list]: https://lists.sr.ht/~greenfork/kisa-devel
[Discord]: https://discord.gg/p5892XNmAk
[Twitch]: https://www.twitch.tv/greenfork_gf
[YouTube]: https://www.youtube.com/channel/UCinLbIxD_iIrByWR9fvO2kQ/videos

## Contributing

Ideas are very welcome. At this stage of the project the main task is to
shape its design and provide proof-of-concept implementations of these ideas.
Code contributions without previous discussions are unlikely to be accepted
so please discuss the design first. Ideas should be in-line with current
goals and values of this editor. Many ideas will likely be rejected since not
all goals and values are identified, but nevertheless they will help us to
improve this situation.

For structured discussions please use <~greenfork/kisa-devel@lists.sr.ht> mailing list.

## How to build

Currently it is only relevant for the development, there's no usable
text editor (just yet).

Requirements:
- Zig version 0.8.0, download [here](https://ziglang.org/download/) as a single binary
- git

```
$ git clone --recurse-submodules https://github.com/greenfork/kisa
$ cd kisa
$ zig build test
$ zig build run
```

You can also run individual tests for files, for example for `main.zig` I often
only run `zig build test-main-nofork`, similar commands can be found in
[build.zig](build.zig).

## Is this a task for a mere mortal?

Code editor is a big project. I have a habit of abandoning projects, I moderately
lose interest to them. I am not religious but God give me strength.

In the interview on [Zig Showtime] Andreas Kling, the author of [SerenityOS],
talks about how important it is to lay just one brick at a time. Let's try that.

[Zig Showtime]: https://www.youtube.com/watch?v=e_hCJI__q_4
[SerenityOS]: https://github.com/SerenityOS/serenity
