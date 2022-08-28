# Events design

Event-based system is a mechanism for integration with internal and external
plugins, generally with everything that is not in the "core" of the editor. The
editor core emits events at the strategic points of execution and the editor
allows to "hook up" into these events and do different actions based on event
types and any metadata they carry.

This concept is also known as a "hook" or "callback", a general idea of an
executable piece of code which will be run after a certain event was fired like
inserting a character or switching panes. It is a nice way to allow for
configuration options but it can also go badly. Let's read my sad story
about Kakoune:

[Kakoune] is an example with a minimal domain-specific language for
configuration, the main idea is to use integrations written in any language the
user wants to, and the "Kakoune language" just enables easier
inter-operation. The result is that most of the scripts are written in Bash (:
And the more complicated ones use a myriad of languages such as Guile, Perl,
Python, Crystal, Rust. Although it is feasible to use them, the most common
denominator is Bash and this is sad.

[Kakoune]: https://github.com/mawww/kakoune

But let's not be sad and leave the discussion about the problems with Bash and
similar things for another document. Next we will discuss "the way" to do
events.

## What is an event?

An event captures any modification to the system. But what about non-modifying
events that happen? For example, when an editor tries to redraw the screen, it
asks the server for the display information - this doesn't modify the state. But
it could still be useful to record such actions. For such information we will
use a simple [Audit log](https://martinfowler.com/eaaDev/AuditLog.html) which
can be later used as a secondary to events debugging source.

## Event streaming

Event streaming and processing is a relatively well-researched area with popular
tools such as [RabbitMQ], [Apache Kafka], [NATS] and plenty of others. A general
idea is to have several queues/streams/partitions where specific events
are emitted by producers/publishers and processed by consumers/subscribers.

[RabbitMQ]: https://www.rabbitmq.com
[Apache Kafka]: https://kafka.apache.org
[NATS]: https://nats.io

## Event sourcing

Event sourcing is an extension to the idea of event streaming in that instead of
using a persistent storage such as a database as a source of truth, we use the
very stream of events as the source of truth. We can still have a database as a
current snapshot of the most recent state of the system, this is very useful for
simple querying and optimizing performance. But also has an additional benefit of
debuggability of the system. We can replay the events in order to get to any state
of the system at any point in time.

With a text editor there's a tricky part - we probably don't want to store the
content of an entire file when we open it, so this bit of information will
probably be lost and the whole idea will not be too useful if we try to apply it
to the history of the file. Although it could be a fine idea to keep the content
of the whole file in the event if it is less than 8 MB (configurable), given
that we will discard any events between the editor sessions, or just scrub large
events such as opening files and replace them with an md5 hash of the file for
brevity.

Some use cases for event sourcing besides file history:
- Debugging configuration changes - all the configuration changes are also
  recorded as events, so it would be easier to detect conflicting plugins
  which change same configuration options.
- Debugging user functions - all the actions which affect the state of the
  editor will necessarily emit events, so things such as bugs in the user/plugin
  functions, bugs in the core functions are easily detected. Given the easy
  debuggability of the source code, it feels much safer to introduce unobvious
  and usually shunned upon concepts such as user-defined hooks and, God forbid,
  goto constructs (just a thought experiment, not an actual idea).

Additional resources:
- [MemoryImage](https://martinfowler.com/bliki/MemoryImage.html) pattern by Martin Fowler

## Asynchronous extensions

Replayability of events plays a big role in event sourcing. Let's review a case with an asynchronous plugin which inserts indentation. The approach with CRDT and "edit priority" is described in the documents for the Xi editor: [docs page](https://xi-editor.io/xi-editor/docs/rope_science_10.html) and [github comment](https://github.com/xi-editor/xi-editor/issues/933#issuecomment-431216575). Copied example from there:

Start quote.
***

Let's say the buffer is in this state (we'll just use | to reprsent the caret
position):

```
{|}
```

The user presses Enter, putting the buffer in this state:

```
{
|}
```

At this point, language plugin inserts whitespace, four spaces before the caret
and a newline after:

```
{
    |
}
```

Concurrently, the user types "println". Let's say, though, that the plugin is
slow, and the insertions are delayed. So, for a moment, the buffer is in this
state:

```
{println|}
```

Finally, the plugin edits catch up. There are effectively three inserts at the
caret: " " at the lowest priority, "println" at the next priority, (implicitly
the caret), and a newline at the last priority. So the final buffer is, as
desired:

```
{
    println|
}
```

The goal is to allow the language plugin to be slow without causing text insertion to block on the calculation of automatically inserted whitespace.

***
End quote.

Also a quote from the [docs](https://xi-editor.io/xi-editor/docs/rope_science_10.html):

>You could imagine trying to do some kind of replay of the user’s keystrokes so
>eventually you get the sequential answer, but that makes the system even more
>complicated in ways I find unappealing, and also fails to scale to actual
>collaborative editing.

So in our case we actually **do** have a replay of events ready, let's model the
events for this kind of workflow. So in our world the case of a delayed
asynchronous indentation plugin would work like this, with a minor correction
from the original example, here are events with a minor description:

1. `file_opened` - contains the whole file content

```
{|}
```

2. `newline_inserted`

```
{
|}
```

3. Our asynchronous indentation plugin sees the previous event and starts
   calculating the correct indentation for some time.

4. `character_inserted` - for each letter, let's just use two letters

```
{
pr|}
```

5. The plugin finally calculated the correct indentation and starts doing its
   magic.

So the events at this point are as follows:

```
1. file_opened
2. newline_inserted
3. character_inserted (p)
4. character_inserted (r)
```

So what the plugin does is just inserts some events and asks to replay them:

```
1. file_opened
2. newline_inserted
3. newline_inserted (after cursor)   NEW
4. character_inserted ( )            NEW
5. character_inserted ( )            NEW
6. character_inserted ( )            NEW
7. character_inserted ( )            NEW
8. character_inserted (p)
9. character_inserted (r)
```

so the final state is what we wanted:

```
{
    pr|
}
```

This works well but there are of course some assumptions that might make this
too easy, so let's address them:

Q: `file_opened` event contains the whole file content, so what if it is 200MB
in size?

A: You are in bad luck, your disk usage has just increased with 200MB in size
and also your memory occupies 200MB more. As a nice thing, you likely won't have
many files with 200MB in size. For "more realistic" scenarios such as 8MB files,
I will hope that you don't use a constrained hardware with 64KB memory and 512KB
disk space that you use for editing 8MB files. There are of course optimizations
possible: memory - use `mmap(2)` to just map the necessary memory to display the
current window worth of content with a but surplus, e.g. 30KB; disk space - same
idea with 30KB but truncating any content before and after 30KB range.

Q: What if the editing session on a single file lasts for days, weeks, months
and even years with millions of events, are we going to replay them all from the
start?

A: A caching layer would help, every N events there will be a `file_savepoint`
event which will contain a diff or full contents of a file, so with diffs we can
apply diffs sequentially in order, and with full file contents no work
needed. Probably should be configurable since this is a classic space/speed
trade-off for caching. There's also an alternative - make every event
reversible, in that case an event can save additional information that would be
useful only for reversing of this event, so the process is to reverse some
events and then replay the left events.

## Command-query responsibility segregation (CQRS)

CQRS is a pattern where reading and modifying data are two conceptually
different things. It works well for domains where reading and modifying
constitute very different programming interfaces or patterns. For example, the
editor will have a configuration which is simply saying a set of options, let's
say there's an option `blinking_cursor: true`. CQRS pattern will add an
additional complexity if we try to use it for managing our configuration since
reading and modifying it is the same pattern, we just call `set` and `get` to do
that. But let's look at the editing session where modifying the state usually
involves commands such as `move_cursor_forward`, `insert_character` but reading
the state is usually `show_visible_content` - these are very different patterns
for modifying and for reading the data, hence CQRS will fit there very well.

Using CQRS generally has two parts: commands and queries, we can record them
both and then match each command to each event it produced; for queries there's
no special logic required as just reading is essentially a simple operation. The
idea to have separate commands and events is an acknowledgement of a fact that a
command can fail and not produce the desired event. When the command failed, we
can produce a "failed event" instead of requiring the caller to synchronously
wait for the command to complete, the caller can always fetch all the events and
get the result for the previously sent command. This adds a bit of asynchronous
vibes to the communication of client and server of the editor, the implications
can be interesting but are not completely understood, since the client still
should asynchronously wait for the server to tell it what to draw on the
screen. This feature is more of an experimental endeavor towards a more
debuggable editor experience.

## Event batches

Events are quite simple and there's a benefit to keeping them simple, similar to
how you would want to keep a minimum number of bytecode instructions for a VM,
or how compilers "lower" the code by rewriting it to simpler constructs. Let's
have a "delete line" command which produces the following events (by issuing
responsible commands, we omit them here for simplicity):

```
cursor_position_saved
cursor_moved_beginning_of_line
cursor_anchored (to enable selection)
cursor_moved_end_of_line
cursor_moved_forward (the ending newline character)
selection_deleted
cursor_position_restored
```

It would be useful in certain circumstances to treat them all as a single
unit. Some use cases:
- "Undo" should reverse all the events at once, not just the last event.
- If some command to produce the event fails in the middle of a complex command,
  the whole command should be aborted instead of stopping in the middle.

All these events should be treated as a single unit in some circumstances, they
belong to a single batch. The "batch" could be an increasing integer. There must
not be any events inserted in-between the batch, events in a single batch are
always sequential.

## Modifying events

As mentioned in the **Asynchronous extensions** part, there may be a need to
modify the existing events, maybe insert new ones, maybe enrich existing ones
and delete them altogether. At the same time events are usually considered
immutable entities that should never be modified. The mechanism for "modifying"
events should leave the existing events untouched, the idea is very similar to
how the the [evolve](https://www.mercurial-scm.org/doc/evolution/) extension for
the [Mercurial](https://www.mercurial-scm.org) source control management system
approaches this topic.

We never delete events but mark them as obsolete instead. So in the example
where we transform this sequence of events

```
1. file_opened
2. newline_inserted
3. character_inserted (p)
4. character_inserted (r)
```

to this one

```
1. file_opened
2. newline_inserted
3. newline_inserted (after cursor)   NEW
4. character_inserted ( )            NEW
5. character_inserted ( )            NEW
6. character_inserted ( )            NEW
7. character_inserted ( )            NEW
8. character_inserted (p)
9. character_inserted (r)
```

what we do is actually mark the old events obsolete, and add new events after them:

```
1. file_opened
2. newline_inserted
3. character_inserted (p)            OBSOLETE
4. character_inserted (r)            OBSOLETE
5. newline_inserted (after cursor)   NEW
6. character_inserted ( )            NEW
7. character_inserted ( )            NEW
8. character_inserted ( )            NEW
9. character_inserted ( )            NEW
10. character_inserted (p)           NEW
11. character_inserted (r)           NEW
```

## Undo history

The approach is fairly straightforward, two options:
1. Replay all the events since the last savepoint.
2. Revert the event if all events are made reversible.

The challenge above is a no-brainer so let's talk about saving ALL the
history. It modern editors it is a common consideration that the history is not
linear because we usually undo some changes, redo some changes, make additional
changes and sometimes we want to get back to the previous state somewhere in the
middle of all these things we did. So the history is usually represented as a
directed acyclic graph (DAG) - this is also the option to go for with events, we
will have multiple branches of events, "alternative realities" if you will, that
we will be able to switch at our will be replaying all the events up to the
necessary point.

## Collaborative editing

Let's address the quote from the Xi editor
[docs](https://xi-editor.io/xi-editor/docs/rope_science_10.html):

>You could imagine trying to do some kind of replay of the user’s keystrokes so
>eventually you get the sequential answer, but that makes the system even more
>complicated in ways I find unappealing, and also fails to scale to actual
>collaborative editing.

There's no solution to collaborative editing at this point but I will try to add
more clarity to the problem. Common solutions include eventually consistent data
structures, Conflict-free Replicated Data Type approach (CRDT) and Operational
Transformation (OT) - I don't really understand any of it yet. I will focus on
the granularity of the data being considered:
- Conflict-free Replicated Data Type in the Xi editor in my understanding uses
  **text deltas** which are sent to the server.
- Operational Transformation uses **"insert"** and **"delete"** commands on the text to
  reason about its changing state.
- The quote is focused on replaying the user's **keystrokes**.

In our approach we operate on a level of an **event** which _may_ have several
benefits:
- We are not constrained to think of text changes just as a set of diffs.
- We have a richer set of operations than just inserting and deleting.
- We have an extended amount of information when we consider the whole events
  than just the keystrokes the user typed.

In the ideal world we would implement something akin to the distributed version
control systems such as Git, Mercurial or Bazaar: whenever we have conflicts, we
construct a directed acyclic graph (DAG) of different changes and try to
"smartly" merge them all together. A kind of distributed serverless approach of
consistently resolving very local changes is described in this paper: [Real time
group editors without Operational
transformation](https://hal.inria.fr/inria-00071240/document), which I don't
understand yet.
