import strformat
import tables
from strutils import repeat
from sequtils import mapIt
from ./poormanmarkdown import markdown
from ./utils import parameterize

# Partial JSON-RPC 2.0 specification in types.
type
  ParamKind* = enum
    pkVoid, pkNull, pkBool, pkInteger, pkFloat, pkString, pkArray, pkObject,
    pkReference
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
    of pkReference: rVal*: string
  Request* = object
    id: int
    `method`*: string
    params*: Parameter
    notification*: bool ## notifications in json-rpc don't have an `id` element
  Error* = object
    code*: int
    message*: string
    data*: Parameter
  ResponseKind* = enum
    rkResult, rkError
  Response* = object
    id: int
    notification: bool ## notifications in json-rpc don't have an `id` element
    case kind*: ResponseKind
    of rkResult:
      result*: Parameter
    of rkError:
      error*: Error
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
      success*: Response
      errors*: seq[Response]
      `from`*: TargetKind
    of skOther:
      other*: string
  Interaction* = object
    title*: string
    description*: string
    steps*: seq[Step]
  FaceAttribute* = enum
    underline, reverse, bold, blink, dim, italic
  DataReference* = object
    title*: string
    description*: string
    data*: Parameter

func toParam(val: string): Parameter = Parameter(kind: pkString, sVal: val)
func toParam(val: bool): Parameter = Parameter(kind: pkBool, bVal: val)
func toParam(val: int): Parameter = Parameter(kind: pkInteger, iVal: val)
func toParam(val: float): Parameter = Parameter(kind: pkFloat, fVal: val)
func toParam(val: FaceAttribute): Parameter = ($val).toParam
func toParam[T](val: openArray[T]): Parameter =
  Parameter(kind: pkArray, aVal: val.mapIt(it.toParam))
func toParam(val: Parameter): Parameter = val

func quoteString(str: string): string =
  for ch in str:
    if ch == '"':
      result.add '\\'
      result.add '"'
    else:
      result.add ch

const spacesPerIndentationLevel = 4

func linkFormat*(str: string): string = fmt""""%{str.parameterize}%""""
func anchor*(dr: DataReference): string =
  let name = dr.title.parameterize
  result = fmt"""<a href="#{name}">{name}</a>"""

func toCode*(p: Parameter, pretty = false,
    indentationLevel: Natural = 0): string =
  case p.kind
  of pkVoid: assert false
  of pkNull: result = "null"
  of pkBool: result = $p.bVal
  of pkInteger: result = $p.iVal
  of pkFloat: result = $p.fVal
  of pkString: result = fmt""""{quoteString(p.sVal)}""""
  of pkReference: result = linkFormat(p.rVal)
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

func toCode*(r: Request, pretty = false,
    indentationLevel: Natural = 0): string =
  assert r.params.kind in [pkArray, pkObject, pkVoid] # as per specification

  var rs = Parameter(
    kind: pkObject,
    oVal: @[("jsonrpc", "2.0".toParam)]
  )
  if not r.notification:
    rs.oVal.add ("id", r.id.toParam)
  rs.oVal.add ("method", r.`method`.toParam)
  if r.params.kind != pkVoid:
    rs.oVal.add ("params", r.params)
  result = rs.toCode(pretty, indentationLevel)

func toCode*(r: Response, pretty = false,
    indentationLevel: Natural = 0): string =
  var rs = Parameter(
    kind: pkObject,
    oVal: @[("jsonrpc", "2.0".toParam)]
  )
  if not r.notification:
    rs.oVal.add ("id", r.id.toParam)
  case r.kind
  of rkResult:
    rs.oVal.add ("result", r.result)
  of rkError:
    rs.oVal.add ("code", r.error.code.toParam)
    rs.oVal.add ("message", r.error.message.toParam)
    if r.error.data.kind != pkVoid:
      rs.oVal.add ("data", r.error.data)
  result = rs.toCode(pretty, indentationLevel)

func faceParam(fg: string, bg: string, attributes: openArray[FaceAttribute] = []): Parameter =
  result = Parameter(kind: pkObject)
  result.oVal.add ("fg", fg.toParam)
  result.oVal.add ("bg", bg.toParam)
  result.oVal.add ("attributes", attributes.toParam)

func refParam(anchor: string): Parameter =
  Parameter(
    kind: pkReference,
    rVal: anchor.parameterize,
  )

func req[T](met: string, param: T = Parameter(kind: pkVoid), id: int = 1): Request =
  Request(
    `method`: met,
    params: param.toParam,
    notification: false,
    id: id,
  )

func notif[T](met: string, param: T = Parameter(kind: pkVoid)): Request =
  Request(
    `method`: met,
    params: param.toParam,
    notification: true,
  )

func res[T](rs: T, id: int = 1): Response =
  Response(
    kind: rkResult,
    result: rs.toParam,
    id: id,
  )

func err(code: int, message: string, id: int = 1): Response =
  Response(
    kind: rkError,
    error: Error(
      code: code,
      message: message,
    ),
    id: id,
  )

# Construction of all the structures must happen at compile time so that we get
# faster run time and less JavaScript bundle size generated from this file.
const interactions* = block:
  var interactions: seq[Interaction]

  interactions.add(
    Interaction(
      title: "Initialize a client",
      description: """
This is the very first thing the client should do.
Client connects to the server and receives a confirmation.
""",
      steps: @[
        Step(
          kind: skOther,
          description: """
The first thing to do is to send a connection request to the unix domain socket
of type seqpacket which is located at the user runtime directory inside `kisa`
directory with an <ID> of a currently running session (by convention it is the
process ID of the running server). Below is an example for a Zig language, see
the documentation of [socket(2)] and [connect(2)] for more information.

[socket(2)]: https://linux.die.net/man/2/socket
[connect(2)]: https://linux.die.net/man/2/connect
""",
          other: """
const std = @import("std");
const os = std.os;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = &gpa.allocator;
const address = try allocator.create(std.net.Address);
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
After that the server notifies the client that the connection was accepted.
""",
          to: tkClient,
          request: notif("connected"),
        ),
      ]
    )
  )

  interactions.add(
    Interaction(
      title: "Deinitialize a client",
      description: """
This is the very last thing the client should do.
Client notifies the server that it is going to be deinitialized. If this is
the last client of the server, the server quits.
""",
      steps: @[
        Step(
          kind: skRequest,
          description: "Client sends a notification that the client quits.",
          to: tkServer,
          request: notif("quitted")
        ),
      ]
    )
  )

  interactions.add(
    Interaction(
      title: "Open a file",
      description: """
Client asks the server to open a file and get data to display it on the screen.
""",
      steps: @[
        Step(
          kind: skRequest,
          description: "Client sends an absolute path to file.",
          to: tkServer,
          request: req("openFile", ["/home/grfork/reps/kisa/kisarc.zzz"]),
        ),
        Step(
          kind: skResponse,
          description: """
Server responds with `true` on success or with error description.
""",
          `from`: tkServer,
          success: res(true),
          errors: @[
            err(1, "Operation not permitted"),
            err(2, "No such file or directory"),
            err(12, "Cannot allocate memory"),
            err(13, "Permission denied"),
            err(16, "Device or resource busy"),
            err(17, "File exists"),
            err(19, "No such device"),
            err(20, "Not a directory"),
            err(21, "Is a directory"),
            err(23, "Too many open files in system"),
            err(24, "Too many open files"),
            err(27, "File too large"),
            err(28, "No space left on device"),
            err(36, "File name too long"),
            err(40, "Too many levels of symbolic links"),
            err(75, "Value too large for defined data type"),
          ],
        ),
        Step(
          kind: skRequest,
          description: """
Client asks to receive the data to draw re-sending same file path.
""",
          to: tkServer,
          request: req("sendDrawData", ["/home/grfork/reps/kisa/kisarc.zzz"], 2),
        ),
        Step(
          kind: skResponse,
          description: """
Server responds with `true` on success or with error description.
""",
          `from`: tkServer,
          success: res(refParam("data-to-draw"), 2),
        ),
      ]
    )
  )

  var links: Table[string, string]
  for interaction in interactions.mitems:
    interaction.description = markdown(interaction.description, links)
    for step in interaction.steps.mitems:
      step.description = markdown(step.description, links)

  interactions

const dataReferences* = block:
  var dataReferences: seq[DataReference]

  dataReferences.add(
    DataReference(
      title: "Data to draw",
      description: """
On many occasions the client will receive the data that should be drawn on the
screen. For now it copies what Kakoune does and will be changed in future.
""",
      data: Parameter(
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

  dataReferences
