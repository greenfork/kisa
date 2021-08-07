include karax/prelude
import ./jsonrpc_schema
from ./poormanmarkdown import markdown

proc createDom(): VNode =
  buildHtml(tdiv):
    h1:
      text "Kisa API documentation"
    for interaction in interactions:
      h2:
        text interaction.title
      p:
        verbatim markdown(interaction.description).kstring
      ol:
        for step in interaction.steps:
          li:
            p:
              verbatim markdown(step.description).kstring
            pre:
              text(
                case step.kind
                of skOther:
                  step.other
                of skRequest:
                  var str = case step.to
                  of tkServer: "  To Server --> "
                  of tkClient: "  To Client --> "
                  str & step.request.toCode
                of skResponse:
                  var str = case step.`from`
                  of tkServer: "From Server <-- "
                  of tkClient: "From Client <-- "
                  str & step.response.toCode
              )

setRenderer createDom
