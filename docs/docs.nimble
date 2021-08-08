# Package

version = "0.1.0"
author = "Dmitry Matveyev"
description = "A new awesome nimble package"
license = "MIT"
srcDir = "."
bin = @["index.js"]
backend = "js"

# Dependencies

requires "nim >= 1.4.8"
requires "karax#head"
requires "regex"

task release, "build site in release mode for most space efficiency":
  exec "nim r increase_indexjs_version.nim"
  exec "nim js -d:release -d:danger index.nim"
