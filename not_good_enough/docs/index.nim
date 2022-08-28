include karax/prelude
import ./jsonrpc_schema
from ./colorize import colorizeJson
from ./utils import sanitizeHtml, parameterize
from strutils import replace

proc renderStepCode(step: Step): string =
  case step.kind
  of skOther:
    result = step.other.sanitizeHtml
  of skRequest:
    var toTarget =
      case step.to
      of tkServer: "  To Server --> "
      of tkClient: "  To Client --> "
    result = toTarget &
      step.request.toCode(step.pretty, 1).sanitizeHtml.colorizeJson
  of skResponse:
    var fromTarget =
      case step.`from`
      of tkServer: "From Server <-- "
      of tkClient: "From Client <-- "
    result = fromTarget &
      step.success.toCode(step.pretty, 1).sanitizeHtml.colorizeJson
    for error in step.errors:
      result &=
        "\n" &
        fromTarget &
        error.toCode(step.pretty, 1).sanitizeHtml.colorizeJson

func replaceLinks(str: string, dataReferences: seq[DataReference]): string =
  ## Replaces formatted string "%name%" with an anchor with href="#name".
  result = str
  for dataReference in dataReferences:
    result = result.replace(dataReference.title.linkFormat, dataReference.anchor)

proc createDom(): VNode =
  buildHtml(tdiv):
    h1:
      text "Kisa API documentation"
    for interaction in interactions:
      h2:
        text interaction.title
      p:
        verbatim interaction.description
      ol:
        for step in interaction.steps:
          li:
            p:
              verbatim step.description
            pre:
              code:
                verbatim renderStepCode(step).replaceLinks(dataReferences)
    h2:
      text "Data references"
    for dataReference in dataReferences:
      h3(id = dataReference.title.parameterize):
        text dataReference.title
      p:
        verbatim dataReference.description
      pre:
        code:
          verbatim dataReference.data.toCode(true, 1).sanitizeHtml.colorizeJson

setRenderer createDom
