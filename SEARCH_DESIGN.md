# Search design

Searching is referred to searching for a string inside a file or multiple
files.

There are several types of standard searching algorithms:
* Exact - search string should appear exactly in the file, most simple.
* Regex - use full power of regular expressions for searching.

But there are more ideas:
* Exact with word boundaries - exact search but it must not be surrounded by
  any other characters, so `content` does not match `contents` because of the
  "s" at the end.
* Camel-Kebab-Pascal-Snake-case-insensitive - `text_buffer` search items will
  match all of `text_buffer`, `TextBuffer`, `textBuffer`, `text-buffer`.

In GUI editors the search is often coupled with "replace" functionality and
looks like for a good reason. So maybe this is a good idea to do search
first and then provide an option to move from here to replace these things?
* Exact - exact replacement, nothing fancy
* Regex - provide handles for groups such as `\1` or `$1` for the first group
* Exact with word boundaries - same as Exact, exact replacement
* Camel-Kebab-Pascal-Snake-case-insensitive - replace with the same style as
  the original style is

How to do exact but case-insensitive search? Probably with regex, popular
engines use `(?i)` prefix. This could also be same as Camel-Kebab-Pascal-Snake-case-insensitive
in some cases.

## Keymap configuration

We will probably settle at the following configuration:
```
settings:
  default_search: exact

keymap:
  normal:
    /: search_default
    <space>:
      s:
        e: search_exact
        r: search_regex
        b: search_exact_with_boundaries
        i: search_camel_kebab_pascal_snake_case_insensitive
  search:
    default: insert_character
    ctrl-r: search_and_replace
```

So there's a way to choose a default search kind and use it by hitting `/` and
if one needs another kind of search, one can access it by hitting in sequence
Space-s and choose the preferred way. And while searching, one can hit Ctrl-r
to enter a replace mode.

TODO: spec out replace mode.

## Project-wide searching

Another case is project-wide searching. It is probably best achieved by the
combination of external tools such as `ripgrep` + `fzf` so for now the
decision is to be limited by these external tools. We can write one for
ourselves if we really need to, I definitely see a case for project-wide
search-and-replace of Camel-Kebab-Pascal-Snake-case-insensitive words.
