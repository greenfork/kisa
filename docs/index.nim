include karax/prelude
import ./jsonrpc_schema
import ./colorize
from ./utils import sanitizeHtml

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
              verbatim(
                case step.kind
                of skOther:
                  step.other.sanitizeHtml
                of skRequest:
                  var toTarget =
                    case step.to
                    of tkServer: "  To Server --> "
                    of tkClient: "  To Client --> "
                  toTarget &
                    step.request.toCode(step.pretty, 1).sanitizeHtml.colorizeJson
                of skResponse:
                  var fromTarget =
                    case step.`from`
                    of tkServer: "From Server <-- "
                    of tkClient: "From Client <-- "
                  var rs =
                    fromTarget &
                    step.success.toCode(step.pretty, 1).sanitizeHtml.colorizeJson
                  for error in step.errors:
                    rs &=
                      "\n" &
                      fromTarget &
                      error.toCode(step.pretty, 1).sanitizeHtml.colorizeJson
                  rs
              )

setRenderer createDom
