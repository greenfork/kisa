include karax/prelude
import ./jsonrpc_schema

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
