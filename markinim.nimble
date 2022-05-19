# Package

version       = "0.1.0"
author        = "Davide Galilei"
description   = "A markov chain Telegram bot"
license       = "MIT"
srcDir        = "src"
bin           = @["markinim"]


# Dependencies

requires "nim >= 1.4.0"
requires "telebot"
requires "norm"

requires "https://github.com/DavideGalilei/nimkov"
requires "https://github.com/DavideGalilei/owoifynim"
requires "https://github.com/DavideGalilei/emojipasta"
