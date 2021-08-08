import colors
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

const boundaryColor = colSlateGray
const stringColor = colGreen
const keyColor = colSienna
const valueColor = colCrimson
const commaColor = colSienna

func spanStart(color: Color): string = fmt"""<span style="color: {color}">"""
func spanEnd(): string = "</span>"
func span(str: string, color: Color): string = spanStart(color) & str & spanEnd()
func span(ch: char, color: Color): string = ($ch).span(color)

func logError(args: varargs[string, `$`]) =
  when not defined(release):
    {.cast(noSideEffect).}:
      console.error args.join(" ")

func colorizeJson*(str: string): string =
  var states: seq[ParserState]
  states.add Value

  var cnt = 0
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
        result &= span(',', commaColor)
        discard states.pop()
      elif str[cnt] in [']', '}']:
        cnt.dec
        discard states.pop()
      elif str[cnt] == '{':
        result &= span(str[cnt], boundaryColor)
        states.add Object
      elif str[cnt] == '[':
        result &= span(str[cnt], boundaryColor)
        states.add Array
      elif str[cnt] == '"':
        result &= spanStart(stringColor)
        result.add '"'
        states.add String
      elif str[cnt] == 't':
        expectNext("rue")
        result &= span("true", valueColor)
      elif str[cnt] == 'f':
        expectNext("alse")
        result &= span("false", valueColor)
      elif str[cnt] == 'n':
        expectNext("ull")
        result &= span("null", valueColor)
      elif str[cnt].isDigit():
        cnt.dec
        result &= spanStart(valueColor)
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
        result &= span(']', boundaryColor)
        discard states.pop()
      else:
        cnt.dec
        states.add Value
    of Object:
      if str[cnt] == '}':
        result &= spanEnd()
        result &= span('}', boundaryColor)
        discard states.pop()
      elif str[cnt] == '"':
        result &= spanStart(keyColor)
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
        result &= span(':', boundaryColor)
        discard states.pop()
        states.add Value
      else:
        result.add str[cnt]
  if states.len > 1 or states[0] != Value:
    logError "unexpected end: ", states.repr
