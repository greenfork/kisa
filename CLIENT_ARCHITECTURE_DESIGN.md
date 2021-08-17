# Client design

## Wrapping of long lines

There are 2 main options to consider in the design.

### Server knows about wrapping
Server calculates correct positions of wrapping lines and sends them with
other line data. This generalizes to other use cases, such as:
- Displaying of small context windows like autocompletion candidates

Advantages:
- Calculating the necessary amount of data to send is easier, server will
  not send excessive data.
- With soft wrapping of lines moving the cursor up and down is implemented
  on the server, it is easier for clients. This is a hard problem to solve
  since proper handling of wrapping requires interpreting of unicode symbols
  and considering their width which can be different from amount of bytes.

### Server doesn't know about wrapping
Client is responsible for asking the correct number of lines and draws them.

Advantages:
- Data to draw is more uniform, there's no special case for wrapped lines.
- Client has more control of how to display the data which is naturally a
  client's comain.

## Line numbering

There are 2 main options to consider in the design. This also reflects other
additional data that can be connected to the currently displayed line such as:
- Git blame output
- LSP/linter output
- Indentation guides

### Server sends line numbers in draw data
Together with other data like code and highlighting, the server will send the
line numbers.

Advantages:
- More uniform draw data, there's less work for the client to figure out how
  to draw line numbers.
- Client doesn't need to handle different options and settings. For example,
  there are several ways to display line numbers: absolute and relative values.
  This setting won't have to be implemented on each client, the server has to
  only implement it once and for all.

### Client draws line numbers itself
Server sends line numbers as a structured data separate from contents to draw.

Advantages:
- This is naturally a client's domain how to display the data.
- Different clients might have different ideas about how to display the data.
  Making implementation client-specific adds more configurability and more
  choices to the implementators of clients which might make it more
  appealing to develop a third-party frontend.

## Communicating changes to the server

Client will send each key press to the server and wait for response back.
This might seem slow and inefficient but there's no way to implement some
features without it like autocompletion. Nowadays computers should be
fast enough to handle it. It is also the way how remote terminals work
in some implementations.

This can make it unusable for network editing when the server is somewhere
on the internet. And it can also make a difference for low-end hardware,
where the problem could be a visible lag between key presses.

For now this problem is out of scope because solving it involves some real
complexity:
* We need asynchronous communication from the client to the server, so
  that client doesn't have to wait from the server to respond immediately
* We need Operational Transformation or CRDT or another smart word to
  resolve the difference between the changes the client has made so far
  with the data that the server knows about

It is wise to structure the client and the server in a way which will
allow to eventually switch to this approach but right now it is definitely
not the right time to implement it.

See [xi editor revelations](https://github.com/xi-editor/xi-editor/issues/1187#issuecomment-491473599).
