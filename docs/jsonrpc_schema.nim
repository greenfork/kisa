import strformat

# Partial JSON-RPC specification in types.
type
  ParamKind* = enum
    pkVoid, pkBool, pkInteger, pkFloat, pkString, pkArray
  Parameter* = object
    case kind*: ParamKind
    of pkVoid: vVal*: void
    of pkBool: bVal*: bool
    of pkInteger: iVal*: int
    of pkFloat: fVal*: float
    of pkString: sVal*: string
    of pkArray: aVal*: seq[Parameter]
  Request* = object
    `method`*: string
    params*: Parameter
    notification*: bool ## notifications in json-rpc don't have an `id` element
  ErrorObj* = object
    code*: int
    message*: string
  ResponseKind* = enum
    rkResult, rkError
  Response* = object
    notification: bool
    case kind*: ResponseKind
    of rkResult: result*: Parameter
    of rkError: error*: ErrorObj
  StepKind* = enum
    skRequest, skResponse, skOther
  TargetKind* = enum
    tkClient, tkServer
  Step* = object
    description*: string
    case kind*: StepKind
    of skRequest:
      request*: Request
      to*: TargetKind
    of skResponse:
      response*: Response
      `from`*: TargetKind
    of skOther:
      other*: string
  Interaction* = object
    title*: string
    description*: string
    steps*: seq[Step]

func quoteString(str: string): string =
  for ch in str:
    if ch == '"':
      result.add '\\'
      result.add '"'
    else:
      result.add ch

func toCode(p: Parameter): string =
  case p.kind
  of pkVoid: assert false
  of pkBool: result = $p.bVal
  of pkInteger: result = $p.iVal
  of pkFloat: result = $p.fVal
  of pkString: result = fmt""""{quoteString(p.sVal)}""""
  of pkArray:
    result = "["
    for parameter in p.aVal:
      result &= parameter.toCode
      result &= ", "
    result &= "]"

func toCode(e: ErrorObj): string =
  fmt"""{{"code": {e.code}, "message": "{e.message}"}}"""

func toCode*(r: Request): string =
  result = fmt"""{{"jsonrpc": "2.0", "method": "{r.`method`}""""
  if r.params.kind != pkVoid:
    result &= fmt""", "params": {r.params.toCode}"""
  if not r.notification:
    result &= """, "id": 1"""
  result &= "}"

func toCode*(r: Response): string =
  result = """{"jsonrpc": "2.0""""
  case r.kind
  of rkResult:
    result &= fmt""", "result": {r.result.toCode}"""
  of rkError:
    result &= r.error.toCode
  if not r.notification:
    result &= fmt""", "id": 1"""
  result &= "}"

var interactions*: seq[Interaction] = @[]

interactions.add(
  Interaction(
    title: "Initialize a client",
    description: """
The first thing the client should do is to connect to the server and receive and ID.
""",
    steps: @[
      Step(
        kind: skOther,
        description: """
The first thing to do is to send a connection request to unix domain socket which
is located at user runtime directory inside `kisa` directory with an <ID> of a
currently running session (by convention it is the process ID of the server).
Below is an example for a Zig language, see documentation of
[socket(2)] and [connect(2)] for more information.

[socket(2)]: https://linux.die.net/man/2/socket
[connect(2)]: https://linux.die.net/man/2/connect
""",
        other: """
const std = @import("std");
const os = std.os;
const allocator = ...;
const address = allocator.create(std.net.Address);
address.* = try std.net.Address.initUnix("/var/run/user/1000/kisa/<ID>");
const socket = try os.socket(
    os.AF_UNIX,
    os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
    os.PF_UNIX,
);
os.connect(socket, &address.any, address.getOsSockLen());
"""
      ),
      Step(
        kind: skRequest,
        description: """
After that the server notifies the client that the connection was accepted
and sends a notification saying that the client must ask for its ID.
""",
        to: tkClient,
        request: Request(
          `method`: "shouldAskId",
          params: Parameter(kind: pkVoid),
          notification: true
        )
      ),
      Step(
        kind: skRequest,
        description: """
After receiving a notification, the client asks for an ID.
""",
        to: tkServer,
        request: Request(
          `method`: "askId",
          params: Parameter(kind: pkVoid)
        )
      ),
      Step(
        kind: skResponse,
        description: """
Server sends an ID which it assigned to the client.
""",
        `from`: tkServer,
        response: Response(
          kind: rkResult,
          result: Parameter(kind: pkBool, bVal: true)
        )
      )
    ]
  )
)
