# Highlighting design

"Every modern and old code editor includes some kind of coloring for the text
so the programmer is generally more perceptive of the code structure and
it makes code comprehension better" - this claim is unsupported, and as I
understand, completely unsupported.

We should still provide a familiar user experience, even if the claim is
unsupported, the most comfortable environment for learning is when little
things change from the previous editor. And it looks nice.

## Color schemes

Let's put it out of the way. Color scheme is just a bunch of variables and
colors assigned to them. This editor will support every conceivable color
scheme in this universe which has under 2^32 color variants (let's not
have 2^32-1 colors though please). Good color schemes are preferred to
bad ones, this editor can ship a number of popular choices and some
opinionated choices. Choosing the "correct" coloring scheme is left to
the user of this editor and the user will be provided good interface
to tweak everything.

## Traditional coloring scheme

As a default there will be a standard syntax highlighting which is implemented
in most editors where we use fancy colors to highlight different tokens based
on their syntactic meaning.

## Semantic and structural highlighting

A reasonable claim about colors is that they attract our attention to them
and they better convey a meaningful information. I don't necessarily think
that syntax information is that important for us but there are reasons to
think that semantic or structural information is more useful.

* https://buttondown.email/hillelwayne/archive/46a17205-e38c-44f9-b048-793c180c6e84
* https://www.crockford.com/contextcoloring.html

"Semantic" means conveying the meaning, some knowledge about the code, for
example knowing which variables are local and which are global is a semantic
knowlege. Semantic highlighting is not necessarily related to "Semantic tokens"
from the Language Server Protocol (LSP) but carries a similar idea.

"Structural" means conveying the overall structure of a code, for example
knowing where one function begins and another function ends.

There could be different kinds of semantic highlighting, each emphasizing
and communicating just a single thing or looking at the code from a single
perspective. In order to combine and compose them, they will be applied in
order from highest to lowest, we can call them "highlighting tower", for
instance:
1. Rainbow delimiters
2. Imported symbols
3. Not matched delimiters

In this case we will color things in this order:
1. Start with default foreground on background color, just 2 colors
2. Color delimiters like parenthesis according to their level of nesting
3. Color imported symbols from other files, no conflict with the previous one
4. Conflict not matching delimiters like parenthesis. Now let's imagine that
   we indeed have a not matching parenthesis and this highliter colors them
   bright red. This means that since this highlighter is below, it is applied
   later and we will re-color the paren from step 1 to the bright red color.

Of course some coloring modes may conflict in a sense they they color only
a part of the previously colored region or in some other bizarre ways.
These conflicts are left for the user to decide and tweak.
Though this editor will provide a convenient interface to manipualte
different highlighting levels at run-time.

A note should be taken that not all highlighting levels are general-purpose.
Some of them will have to be implemented individually for each language,
some will not make sense for other languages at all, some of them are too
ambitious to implement efficiently while retaining the low latency of an
editor.

Below are some ideas which will be implemented as separate levels of the
highlighting tower. Not everything is guaranteed to be implemented.

### Rainbow delimiters

Have a set of 7 colors (in my world rainbow has 7 colors, duh) and apply it
to each level of delimiters, cycling from the first color if there are more
than 7 nesting levels. For example, this will have 4 nesting levels, each
level is prefixed with a number, in Emacs Lisp:

```
1(use-package elpher
  :hook
  2(elpher-mode . 3(lambda 4() 4(text-scale-set 1))))
```

Delimiters mean more than just brackets: also quotes for string literals,
html tags, do..end syntax structures in some languages. Not every delimiter
is reasonable to implement though.

* Vim https://github.com/luochen1990/rainbow
* Emacs https://www.emacswiki.org/emacs/RainbowDelimiters

### Rainbow indentation

Similar idea, have a look above at how many colors a rainbow has, this time
we color the indentation level each with new color. It can be useful for
indentation-based syntax languages like Python and for others since not using
indentation is socially inappropriate nowadays. Example, where `r` means
colored with read and `b` means colored with blue, in Python:

```
def add(a, b):
rrrrif (True):
rrrrbbbbprint(2)
```

* VSCode https://github.com/oderwat/vscode-indent-rainbow

### Imported symbols

**Language-specific**

General use case is analyzing a particular file for dependencies. It would be
good to see all the functions/variables/types used from different
files/packages. For example, imagine that everything between asterisks `*`
is colored green and between pipes `|` is colored yellow, in Nim:

```
import *strutils*, |times|

if "mystring".*endsWith*("ing"):
  echo |now|()
```

### Bound variables, scopes of variables

**Language-specific** **Opinionated**

We would like to highlight each symbol that is bound to global scope,
to local scope or to function argument. We don't necessarily care about
typos (which might be a convenient thing to have for fast typers, but
ultimately it is well-catched by the compilers/interpreters), and more
about conveying the information about which particular scopes are used
at the current place of code. For example, imagine that everything between
asterisks `*` is colored red (global variable), between pipes `|` is colored
yellow (function or loop variable) and between underscores `_` is colored
blue (local variable), in TypeScript:

```
const *listener* = Deno.listen({ port: 8000 });
for await (const |conn| of *listener*) {
  (async () => {
    const _requests_ = Deno.serveHttp(|conn|);
    for await (const { |respondWith| } of _requests_) {
      |respondWith|(new Response("Hello world"));
    }
  })();
}
```


Meaning will probably vary a lot between different languages and there could
be opinionated implementations of this feature. Hopefully there's an option
to implement it once but make it configurable enough.

### Error handling

**Language-specific**

There are a lot of different approaches to implement this. It is almost
opinionated, but the approaches don't seem to conflict with each other
so there's no serious conflict. Some choices:
* Highlight all `raise` or `throw` or `try` keywords
* Highlight all functions which `raise` but don't handle the raised error
  in any way

Basically any way we can have a perspective at how "safe" the program is.
For example, imagine that everything between `*` is green (good, `try` has
a matching `errdefer`) and between `&` is red (bad `try` does not have a
matching `errdefer`), in Zig:
```
// somewhere inside the function
        var text_buffer = *try* self.createTextBuffer(text_buffer_init_params);
        *errdefer* self.destroyTextBuffer(text_buffer.data.id);
        var display_window = &try& self.createDisplayWindow();
        var window_pane = *try* self.createWindowPane(window_pane_init_params);
        *errdefer* self.destroyWindowPane(window_pane.data.id);
// ...
```

### Memory handling

**Language-specific** **Opinionated**

For low-level languages it is usually important to correctly do memory
handling which can be allocate/free analysis (which is hard to do and
probably is still a research project), deciding whether the memory is
being allocated on the stack or on the heap. So there are some ideas:
* Highlight all the functions that do memory allocations on the heap
* Highlight all the functions with unsafe memory access

For example, we can have a list of all the C functions that make memory
allocations and color them red (easy option) as well as transitive
functions that use them (hard option). Same goes for Rust, we can
highlight functions that are _definitely_ safe versus functions that
directly or transitively use `unsafe` blocks.

### Tests integration

**Language-specific** **Opinionated**

Right after running the test, in addition to jumping to the errored test line:
* Highlight the line which exactly failed the test and show the condensed
  error message (not so exciting and probably more about the preference)
* Highlight all the functions which caused the fail

Test-driven development folks will be just astonished, I'm sure. Maybe even
make every now-passed-previously-failed test green. For example, imagine that
`=` is dark red highlighted line and `*` is a function highlighted bright red,
in Ruby:
```
# Test file
test "should not send cookie emails" do
  cookie = cookies(:cinnamon)

  perform_enqueued_jobs do
====assert_no_emails=do===============================
      cookie.*sendChocolateEmails*
    end
  end
end

# `Cookie` class file
class Cookie
  def *sendChocolateEmails*
    chocolate_cookies.each(&:send_email)
  end
end
```

## Architecture

TODO

- https://lobste.rs/s/jembrx
- https://xi-editor.io/docs/rope_science_11.html

## Overview of existing solutions

### Kakoune

[Kakoune] uses regex with slight modifications to allow code reuse and nested structures.
Looks almost good enough: usually it is hard to edit and some rare constructs
seem hard to implement (I couldn't implement highlighting for [slim], but
maybe I'm not that smart).

[slim]: https://github.com/slim-template/slim

### amp

[amp] reuses [TextMate grammar] syntax highlighting configurations.
The config files look as a mix of regex and some kind of pushdown automata.
Extremely interesting option but needs more research.

### vis

[vis] it has direct integration with Lua and uses Parsing Grammar Expressions (PEG)
in combination with the Lua language features. Looks very neat and powerful.

### Emacs

[Emacs] it doesn't have anything in particular, just uses some regex together with
the power of Emacs-Lisp language. The editor is the Lisp machine, it doesn't
really need anything special.

### joe

[joe] uses a full-blown description of a state machine that parses the text with
simplified grammar rules. Quite large files, for example C grammar takes
300 loc, Ruby grammar takes 600 loc (Ruby has complicated grammar). Although
the grammar is correct (e.g. Kakoune grammar is not 100% correct), it takes
some dedication to create such a grammar file.

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
