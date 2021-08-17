# Configuration design

Currently the format for file configuration is [zzz], it is a YAML-like
syntax with a representation like a tree, allows duplicated keys and
carries no distinction between the keys and values. It is flexible enough
to meet all our needs for now but we may reconsider it in the future.

You are advised to skim through [zzz] spec since there are some unusual
syntactic structures which we will abuse. But also feel free to reference
it later once you see any uncomprehensible black magic in the config example.

[zzz]: https://github.com/gruebite/zzz

Configuration files are searched and applied in the following order,
later take precedence over former:
1. `etc/kisa/kisarc.zzz`
2. `$HOME/.kisarc.zzz`
3. `$XDG_CONFIG/kisa/kisarc.zzz`
4. `$(pwd)/kisarc.zzz`

where in (3) `$XDG_CONFIG` is usually `$HOME/.config` and `$(pwd)` means
current working directory.

File is read from top to bottom, since settings can be duplicated, settings
below in the file take precedence over settings above. Duplicated keys
are resolved in the following fashion:
* Top-level keys are always strictly defined, duplicated top-level keys
  have their values appended
* All the other keys are replaced according to precedence rules

A list of allowed top-level keys, all other keys are forbidden:
* `keymap`
* `scopes`
* name of a scope
* `settings`

All the top-level keys are allowed either at the top level or right under a
"name of a scope" key. Name of a scope can not be inside another name of
a scope.

Configuration can be separated into different categories and they all can
be approached differently.

## Keymap, bindings

We need to consider these points:
1. There are different modes (Normal, Insert, ...)
2. There are mini-modes, see KEYBINDINGS_DESIGN.md
3. There are global bindings and filetype-specific bindings
4. There are modifier keys, such as Ctrl, Shift, Alt
5. Keys must resolve to a defined set of commands
6. Some commands may take an argument
7. Some keys might be in a foreign language
8. Keys can execute multiple commands at a time
9. Keys can have documentation for interactive help

Point (3) will be addressed in Scopes section. All other points are
demonstrated below using zzz file format:
```
keymap:                          # top-level key
  normal:                        # mode name
    default: nop                 # default if no key matches
    j: move_down                 # usual keybinding
    h: move_left; l: move_right  # on the same line using `;` to move up 1 level
    л: move_up                   # Cyrillic letter
    b: minimode: buffers         # start a mini-mode and give it a name
      doc: Buffer manipulations  # documentation for the key `b`
      n: buffer_next             # n will only be available in the mini-mode
      p: buffer_prev
    n:
      search_forward             # command can be on a separate line
      select_word                # multiple commands can be executed for 1 key
      doc: Search and select     # documentation for the key `n`
    N: search_backward           # optionally shift-n
    # command `open_buffer` takes an argument `*scratch*`
    S: open_buffer: *scratch*
  insert:
    default: insert_character
    ctrl-n: move_down   # keybinding with a modifier key
    ctrl-p: move_up
```
 *

TODO: describe the parsing algorithm

## Scopes

There are some cases where we only want to bind the keys for a specific
programming language file like Ruby or Rust. Scopes make this dream come
true. Settings in the scope are kept in a separate from a general config
bucket but otherwise they follow all the precedence rules described
above.

Scopes have 2 different syntaxes for 2 use cases: scope definition and
scope usage.

### Scope definition

Scopes are tried in order from top to bottom, first matched scope is
applied, all later ones are not tried. Scope name can be any name
except for a reserved set of top-level keys.

```
scopes:                        # top-level key
  ruby:                        # scope name
    filename: .*\.rb, Gemfile  # matching on the name with regex, must match
                               # the whole file name
    mimetype: text/x-ruby      # matching with file metadata
  bash:
    filename: .*\.sh, .*\.bash
    # multiple matching on file contents, full string match
    contents: #!/usr/bin/bash, #!/usr/bin/sh, #!/usr/bin/env bash
  xz:
    contents: 7zXZ             # matching on binary data (why on Earth)
```
 *

### Scope usage

Scope names can only appear at the top level, they can be repeated multiple
times throughout the config file.

```
ruby:
  keymap:                          # imagine it's the top level here
    normal:
      r:                           # start a mini-mode
        minimode: rubocop          # give it a name
        l: shell_command: rubocop  # execution of a shell command `rubocop`
        # documentation for the key `a` by using `;;` to jump 2 levels up
        a: shell_command: rubocop -a;; doc: Run rubocop safe autocorrect
        A: shell_command: rubocop -A;; doc: Run rubocop unsafe autocorrect
  settings:
    tab_width: 2
```
 *

## Settings

Settings for things like indentation, line numbering, et cetera. Expressed
as a simple key-value.

TODO: document all settings

Example:
```
settings:
  line_numbers: absolute      # none, absolute, relative
  shell: /bin/sh              # any valid path to executable
  insert_final_newline: true  # true, false
  trim_spaces: on_save        # on_save, on_switch_to_normal, false
  tab_width: 8                # positive number
  expand_tab: smart           # true, false, smart
```
 *

## Extensions

TODO

## Hooks

TODO?
