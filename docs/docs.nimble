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
