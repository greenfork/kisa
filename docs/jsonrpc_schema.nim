import strformat
import tables
from strutils import repeat
from sequtils import mapIt
from ./poormanmarkdown import markdown

# Partial JSON-RPC 2.0 specification in types.
type
  ParamKind* = enum
    pkVoid, pkNull, pkBool, pkInteger, pkFloat, pkString, pkArray, pkObject
  Parameter* = object
    case kind*: ParamKind
    of pkVoid: vVal*: bool
    of pkNull: nVal*: bool
    of pkBool: bVal*: bool
    of pkInteger: iVal*: int
    of pkFloat: fVal*: float
    of pkString: sVal*: string
    of pkArray: aVal*: seq[Parameter]
    of pkObject: oVal*: seq[(string, Parameter)]
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
    notification: bool ## notifications in json-rpc don't have an `id` element
    case kind*: ResponseKind
    of rkResult: result*: Parameter
    of rkError: error*: ErrorObj
  StepKind* = enum
    skRequest, skResponse, skOther
  TargetKind* = enum
    tkClient, tkServer
  Step* = object
    description*: string
    pretty*: bool
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
  FaceAttribute = enum
    underline, reverse, bold, blink, dim, italic

func toParam(val: string): Parameter = Parameter(kind: pkString, sVal: val)
func toParam(val: bool): Parameter = Parameter(kind: pkBool, bVal: val)
func toParam(val: int): Parameter = Parameter(kind: pkInteger, iVal: val)
func toParam(val: float): Parameter = Parameter(kind: pkFloat, fVal: val)
func toParam(val: FaceAttribute): Parameter = ($val).toParam
func toParam[T](val: openArray[T]): Parameter =
  Parameter(kind: pkArray, aVal: val.mapIt(it.toParam))

func quoteString(str: string): string =
  for ch in str:
    if ch == '"':
      result.add '\\'
      result.add '"'
    else:
      result.add ch

const spacesPerIndentationLevel = 4

func toCode(p: Parameter, pretty = false, indentationLevel: Natural = 0): string =
  case p.kind
  of pkVoid: assert false
  of pkNull: result = "null"
  of pkBool: result = $p.bVal
  of pkInteger: result = $p.iVal
  of pkFloat: result = $p.fVal
  of pkString: result = fmt""""{quoteString(p.sVal)}""""
  of pkArray:
    result &= "["
    if p.aVal.len > 0:
      if pretty: result &= "\n"
      for idx, parameter in p.aVal:
        if idx != 0: result &= (if (pretty): ",\n" else: ", ")
        if pretty: result &= repeat(' ', indentationLevel * spacesPerIndentationLevel)
        result &= parameter.toCode(pretty, indentationLevel + 1)
      if pretty: result &= "\n"
      if pretty: result &= repeat(' ', (indentationLevel - 1) * spacesPerIndentationLevel)
    result &= "]"
  of pkObject:
    result &= "{"
    if p.oVal.len > 0:
      if pretty: result &= "\n"
      for idx, (key, parameter) in p.oVal:
        if idx != 0: result &= (if (pretty): ",\n" else: ", ")
        if pretty: result &= repeat(' ', indentationLevel * spacesPerIndentationLevel)
        result &= fmt""""{key}": {parameter.toCode(pretty, indentationLevel + 1)}"""
      if pretty: result &= "\n"
      if pretty: result &= repeat(' ', (indentationLevel - 1) * spacesPerIndentationLevel)
    result &= "}"

func toCode*(r: Request, pretty = false, indentationLevel: Natural = 0): string =
  assert r.params.kind in [pkArray, pkObject, pkVoid] # as per specification

  var rs = Parameter(
    kind: pkObject,
    oVal: @[("jsonrpc", "2.0".toParam)]
  )
  if not r.notification:
    rs.oVal.add ("id", 1.toParam)
  rs.oVal.add ("method", r.`method`.toParam)
  if r.params.kind != pkVoid:
    rs.oVal.add ("params", r.params)
  result = rs.toCode(pretty, indentationLevel)

func toCode*(r: Response, pretty = false, indentationLevel: Natural = 0): string =
  var rs = Parameter(
    kind: pkObject,
    oVal: @[("jsonrpc", "2.0".toParam)]
  )
  if not r.notification:
    rs.oVal.add ("id", 1.toParam)
  case r.kind
  of rkResult:
    rs.oVal.add ("result", r.result)
  of rkError:
    rs.oVal.add ("code", r.error.code.toParam)
    rs.oVal.add ("message", r.error.message.toParam)
  result = rs.toCode(pretty, indentationLevel)

func faceParam(fg: string, bg: string, attributes: openArray[FaceAttribute] = []): Parameter =
  result = Parameter(kind: pkObject)
  result.oVal.add ("fg", fg.toParam)
  result.oVal.add ("bg", bg.toParam)
  result.oVal.add ("attributes", attributes.toParam)

const interactions* = block:
  var interactions: seq[Interaction]


  # interactions.add(
  #   Interaction(
  #     title: "Testing",
  #     steps: @[
  #       Step(
  #         kind: skRequest,
  #         to: tkClient,
  #         request: Request(
  #           `method`: "shouldAskId",
  #           params: [1,2,3].toParam,
  #           notification: true
  #         )
  #       ),
  #       Step(
  #         kind: skRequest,
  #         to: tkServer,
  #         request: Request(
  #           `method`: "askId",
  #           params: Parameter(kind: pkVoid)
  #         )
  #       ),
  #       Step(
  #         kind: skResponse,
  #         `from`: tkServer,
  #         response: Response(
  #           kind: rkResult,
  #           result: true.toParam
  #         )
  #       )
  #     ]
  #   )
  # )

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
            result: true.toParam
          )
        )
      ]
    )
  )

  interactions.add(
    Interaction(
      title: "Receive the data to draw",
      description: """
On many occasions the client will receive the data that should be drawn on the
screen. It is documented here and will be referenced further in other parts
of this documentation as "data to draw".
""",
      steps: @[
        Step(
          kind: skRequest,
          description: "For now it copies what Kakoune does and will be changed in future.",
          pretty: true,
          to: tkClient,
          request: Request(
            `method`: "draw",
            params: Parameter(
              kind: pkArray,
              aVal: @[
                # Lines
                Parameter(
                  kind: pkArray,
                  aVal: @[
                    # Line 1
                    Parameter(
                      kind: pkArray,
                      aVal: @[
                        Parameter(
                          kind: pkObject,
                          oVal: @[
                            ("contents", " 1 ".toParam),
                            ("face", faceParam("#fcfcfc", "#fedcdc", [reverse, bold]))
                          ]
                        ),
                        Parameter(
                          kind: pkObject,
                          oVal: @[
                            ("contents", "my first string".toParam),
                            ("face", faceParam("default", "default"))
                          ]
                        ),
                        Parameter(
                          kind: pkObject,
                          oVal: @[
                            ("contents", " and more".toParam),
                            ("face", faceParam("red", "black", [italic]))
                          ]
                        ),
                      ]
                    ),
                    # Line 2
                    Parameter(
                      kind: pkArray,
                      aVal: @[
                        Parameter(
                          kind: pkObject,
                          oVal: @[
                            ("contents", " 2 ".toParam),
                            ("face", faceParam("#fcfcfc", "#fedcdc", [reverse, bold]))
                          ]
                        ),
                        Parameter(
                          kind: pkObject,
                          oVal: @[
                            ("contents", "next line".toParam),
                            ("face", faceParam("red", "black", [italic]))
                          ]
                        ),
                      ]
                    ),
                  ]
                ),
                # Cursors
                Parameter(
                  kind: pkArray,
                  aVal: @[
                    faceParam("default", "default", []),
                    faceParam("blue", "black", [])
                  ]
                )
              ]
            )
          )
        )
      ]
    )
  )

  var links: Table[string, string]
  for interaction in interactions.mitems:
    interaction.description = markdown(interaction.description, links)
    for step in interaction.steps.mitems:
      step.description = markdown(step.description, links)

  interactions
