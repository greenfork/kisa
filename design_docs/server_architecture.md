# Server architecture

## Architecture

This section is volatile and may change frequently.

![Architecture diagram](docs/assets/architecture.png)

Examples of a Generic Plugin:
- Language Server Protocol
- Autocompletion
- Pair autoinsertion
- Jumping inside a file

### Why client-server architecture?

Short answer: because it's fun, more opportunities, and it doesn't promise
to be too overwhelming. Longer answer:

* Frontends must only speak JSON, they can be written in any language.
* Commandline tools can interact with a running Server session in the same way
  as Clients do, it is already present.
* Switching to Client-Server architecture later is almost equal to a complete
  rewrite of the system, so why not just do it from the start.

Also see:
* [neovim-remote]
* [foot server daemon mode]

[neovim-remote]: https://github.com/mhinz/neovim-remote
[foot server daemon mode]: https://codeberg.org/dnkl/foot#server-daemon-mode

## Request-Respond loop

Server is implemented as a traditional while true loop. It listens on a Unix
domain socket and waits for Client connections. Once the Client is connected,
the Server initializes some state for this Client and keeps its socket,
listening for both incoming Clients and message from the new Client. Every
Client has a consistent connection to the Server and it only interrupts when the
Client session ends.

Server speaks JSON-RPC 2.0 protocol but it does not solely act as a "Server",
meaning that it does not _only_ accepts requests, it can also initiate
requests to the Client, such as "the current file being edited has changed"
if program change the file. So the Server expects the Client to also listen
for any requests. In this sense both Client and Server both send and respond to
requests.

Every request from the Client is resolved asynchronously.
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

Every request from the Server is resolved in 3 phases, with the first one
being a non-blocking request to the Client, and then the Client does its
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
small to the Client, so the the Client can ask for that something.
This is how we do non-blocking send.

Now, why do we need non-blocking send? This is to avoid deadlocks. On the Server
we always expect some requests from Clients and if we end up in a situation when
the Server and the Client simultaneously send their request, we have a deadlock
where both are waiting for a response from both sides at the same time. The
non-blocking send resolves this situation since at no point in time we block on
the call to `send` in user space.

### Implications

Client and Server just _have_ to speak through this JSON interface. And because
of while-true loops it is impossible to run in a single thread since they both
have their own while-true loop. However we can do cooperative multitasking in a
single thread where each of them seizes the to the other loop via an "event
loop" mechanism. But currently this mechanism is in "beta" state in the Zig
standard library and it is not a priority. But it is a viable option, should we
have such requirements.

Another idea is to remove the while-true loop for the Client altogether so the
Server is the only while-true loop and in the end of this loop it gives control
to the Client so it does its drawing things. Though this significantly impairs
the available functionality.
