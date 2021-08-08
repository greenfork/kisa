from strutils import multiReplace

func sanitizeHtml*(str: string): string =
  str.multiReplace(
    ("<", "&lt;"),
    (">", "&gt;"),
  )
