# Server architecture design

## Request-Respond loop

Server is implemented as a traditional while true loop. It listens on a Unix
domain socket and waits for client connections. Once the client is connected,
the server initializes some state for this client and keeps its socket,
listening for both incoming clients and message from the new client. Every
client has a consistent connection to the server and it only interrupts when the
client session ends.

Server speaks JSON-RPC 2.0 protocol but it does not solely act as a "Server",
meaning that it does not _only_ accepts requests, it can also initiate
requests to the client, such as "the current file being edited has changed"
if program change the file. So the server expects the client to also listen
for any requests. In this sense both client and server both send and respond to
requests.

Every request from the client is resolved asynchronously.
```
Client requests -->
Client waits
<-- Server responds
Client receives the response and continues
```

In theory this should be fast enough and in worst case there could be a
visible lag. Unfortunately we will only experience the lag when we
implement it. And at that point we will be too deep into the design so
we will have to either optimize everything out of its guts which may
increase the complexity exponentially, or reimplement everything from
scratch, resuing some existing code and decisions. I really hope we
won't have to go this route.

Every request from the server is resolved in 3 phases, with the first one
being a non-blocking request to the client, and then the client does its
usual synchronous request.
```
Server requests, non-blocking ->
Client receives, does not respond
Client requests -->
Client waits
<-- Server responds
Client receives the response and continues
```

The idea is that in order to send something in a non-blocking way, that
something must be all fit into `SO_SNDBUF` which is OS-dependent. On my
machine for Unix domain sockets it is 208KB which is very enough but we
probably shouldn't rely on this fact. So the idea is to send something
small to the client, so the the client can ask for that something.
This is how we do non-blocking send.

Now, why do we need non-blocking send? This is to avoid deadlocks. On the
server we always expect some requests from clients and if we end up in a
situation when the server and the client simultaneously send their request,
we have a deadlock where both are waiting for a response from both sides
at the same time. The non-blocking send resolves this situation since at
no point in time we block on the call to `send` in user space.

## Event-based system

Every action is an event (except for initialization and deinitialization),
which gets resolved to a further action. Client specifically sends messages
`fire_event` and sends key presses, which gets resolved to certain events
from configuration file. In this sense a lot of actions are duplicated
with the same-named events.

The reason is to decouple the command execution and a place for different
extensions to hook up to these commands. In other words the "event" can do
several things: fire another event, issue several commands, execute
extension-registered hooks to do some more events or commands. And the
"command" usually mutates or queries the current state. This distinction
should make it possible to easily add and remove different in-memory
extensions. To the best of my knowledge, this is also a usual solution
for graphical and terminal user interfaces.

Example:
1. Client sends a keypress event with left bracket `(`
2. Server resolves it with keymap config into the `insert_character` event
3. Event dispatcher processes this event
4. During processing a "pair bracket" extension kicks in and sends another event
   `insert_character` with `)`
5. Original event is resolved, command `insertCharacter` is issued with `(`
6. Event from "pair bracket" extension is resolved, command `insertCharacter`
   is issued with `)`
7. Result is that the client sees `()` being inserted when it only pressed
   a single bracket key `(`
