from strutils import multiReplace, toLowerAscii

func sanitizeHtml*(str: string): string =
  str.multiReplace(
    ("<", "&lt;"),
    (">", "&gt;"),
  )

func parameterize*(str: string): string =
  for ch in str:
    if ch == ' ':
      result.add '-'
    elif ch in {'a'..'z', 'A'..'Z', '-', '_'}:
      result.add ch.toLowerAscii
    else:
      assert false
