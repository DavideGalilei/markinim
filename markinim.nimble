# Package

version       = "0.1.0"
author        = "Davide Galilei"
description   = "A markov chain Telegram bot"
license       = "MIT"
srcDir        = "src"
bin           = @["markinim"]


# Dependencies

requires "nim >= 1.4.0"
requires "nimkov"
requires "telebot"
requires "norm"
