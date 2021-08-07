## Poor man's markdown parser.

import tables
from regex import re, findAll, groupFirstCapture, replace
from strutils import multiReplace
import strformat

const linkDefinitionRe = re"(?m)^(\[.+?\]): (.+)$"

var links: Table[string, string]

func quoteString(str: string): string =
  for ch in str:
    if ch == '"':
      result.add '\\'
      result.add '"'
    else:
      result.add ch

func htmlLink(text: string, url: string): string =
  fmt"""<a href="{quoteString(url)}">{text}</a>"""

func toReplacementGroups(table: Table[string, string]): seq[(string, string)] =
  for key, url in table:
    result.add (key, htmlLink(key[1..^2], url))

func inlineCodeReplacementGroups(str: string): seq[(string, string)] =
  const inlineCodeRe = re"(?s)`(.+?)`"
  for m in findAll(str, inlineCodeRe):
    result.add (str[m.boundaries], "<code>" & m.groupFirstCapture(0, str) & "</code>")

proc markdown*(str: string): string =
  for m in findAll(str, linkDefinitionRe):
    links[m.groupFirstCapture(0, str)] = m.groupFirstCapture(1, str)
  result = str.replace(linkDefinitionRe, "")
  result = result.multiReplace(
    ("<", "&lt;"),
    (">", "&gt;"),
  )
  result = result.multiReplace(inlineCodeReplacementGroups(result))
  result = result.multiReplace(links.toReplacementGroups)
