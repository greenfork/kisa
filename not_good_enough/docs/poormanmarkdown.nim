## Poor man's markdown parser.

import tables
from regex import re, findAll, groupFirstCapture, replace
from strutils import multiReplace
import strformat
from ./utils import sanitizeHtml

const linkDefinitionRe = re"(?m)^(\[.+?\]): (.+)$"

func quoteString(str: string): string =
  for ch in str:
    if ch != '"':
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

## `links` must be initialized and passed on every parse call. It is modified
## inside a proc and same `links` can be passed to further `markdown` calls.
func markdown*(str: string, links: var Table[string, string]): string =
  for m in findAll(str, linkDefinitionRe):
    links[m.groupFirstCapture(0, str)] = m.groupFirstCapture(1, str)
  result = str.replace(linkDefinitionRe, "")
  result = result.sanitizeHtml()
  result = result.multiReplace(inlineCodeReplacementGroups(result))
  result = result.multiReplace(links.toReplacementGroups)
