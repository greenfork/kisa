from strutils import parseInt, find

const filesData = [
  ("index.html", "index.js?v=", '"'),
  ("index.html", "styles.css?v=", '"'),
]

for (filename, startText, endText) in filesData:
  let text = readFile(filename)
  let startIndex = text.find(startText)
  var numberStr: string

  for ch in text[startIndex + startText.len..^1]:
    if ch == endText: break
    else: numberStr.add ch

  let number = parseInt(numberStr)

  let newText =
    text[0..startIndex + startText.len - 1] &
    $(number + 1) &
    text[startIndex + startText.len + numberStr.len..^1]

  writeFile(filename, newText)
