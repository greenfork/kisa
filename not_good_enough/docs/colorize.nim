import strformat
import strutils
import jsconsole
from strutils import join

type
  ParserState = enum
    Value
    String
    Number
    Array
    Object
    ObjectKey
  TokenKind = enum
    tkBoundary = "boundary"
    tkString = "string"
    tkValue = "value"
    tkComma = "comma"
    tkObjectKey = "object-key"

func spanStart(class: TokenKind): string = fmt"""<span class="tok tok-{$class}">"""
func spanEnd(): string = "</span>"
func span(str: string, class: TokenKind): string = spanStart(class) & str & spanEnd()
func span(ch: char, class: TokenKind): string = ($ch).span(class)
func spanBoundary(ch: char, stackLevel: int): string =
  fmt"""<span class="tok tok-{$TokenKind.tkBoundary}-{$(stackLevel mod 9)}">{ch}</span>"""

func logError(args: varargs[string, `$`]) =
  when not defined(release):
    {.cast(noSideEffect).}:
      console.error args.join(" ")

func colorizeJson*(str: string): string =
  var states: seq[ParserState]
  states.add Value
  var cnt = 0
  var stackLevel = 0

  proc skipSpaces() =
    while cnt < str.len and str[cnt].isSpaceAscii():
      result.add str[cnt]
      cnt.inc
  proc expectNext(ch: char) =
    cnt.inc
    skipSpaces()
    if str[cnt] != ch: logError "unexpected: ", str[cnt], " != ", ch
  proc expectNext(s: string) =
    for ch in s:
      cnt.inc
      if str[cnt] != ch: logError "unexpected: ", str[cnt], " != ", ch

  while cnt < str.len:
    defer: cnt.inc
    skipSpaces()

    case states[^1]:
    of Value:
      if str[cnt] == ',':
        result &= span(',', tkComma)
        discard states.pop()
      elif str[cnt] in [']', '}']:
        cnt.dec
        discard states.pop()
      elif str[cnt] == '{':
        result &= spanBoundary('{', stackLevel)
        stackLevel.inc
        states.add Object
      elif str[cnt] == '[':
        result &= spanBoundary('[', stackLevel)
        stackLevel.inc
        states.add Array
      elif str[cnt] == '"':
        result &= spanStart(tkString)
        result.add '"'
        states.add String
      elif str[cnt] == 't':
        expectNext("rue")
        result &= span("true", tkValue)
      elif str[cnt] == 'f':
        expectNext("alse")
        result &= span("false", tkValue)
      elif str[cnt] == 'n':
        expectNext("ull")
        result &= span("null", tkValue)
      elif str[cnt].isDigit():
        cnt.dec
        result &= spanStart(tkValue)
        states.add Number
      else:
        logError "unexpected Value character: ", str[cnt].repr
        discard
    of String:
      if str[cnt] == '"':
        result.add '"'
        result &= spanEnd()
        discard states.pop()
      else:
        result.add str[cnt]
    of Number:
      if str[cnt].isDigit() or str[cnt] == '.':
        result.add str[cnt]
      else:
        cnt.dec
        result &= spanEnd()
        discard states.pop()
    of Array:
      if str[cnt] == ']':
        stackLevel.dec
        result &= spanBoundary(']', stackLevel)
        discard states.pop()
      else:
        cnt.dec
        states.add Value
    of Object:
      if str[cnt] == '}':
        result &= spanEnd()
        stackLevel.dec
        result &= spanBoundary('}', stackLevel)
        discard states.pop()
      elif str[cnt] == '"':
        result &= spanStart(tkObjectKey)
        result.add '"'
        states.add ObjectKey
      else:
        logError "unexpected Object character: ", str[cnt].repr
        discard
    of ObjectKey:
      if str[cnt] == '"':
        result.add '"'
        result &= spanEnd()
        expectNext(':')
        result &= span(':', tkBoundary)
        discard states.pop()
        states.add Value
      else:
        result.add str[cnt]
  if states.len > 1 or states[0] != Value:
    logError "unexpected end: ", states.repr
