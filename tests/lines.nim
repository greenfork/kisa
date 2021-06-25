var f = open("manylines.txt", fmAppend)

for i in 0..<4294967296:
  f.write($i & "\n")
