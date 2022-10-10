import std / [strutils, sequtils]

when not defined(debug):
    switch("d", "release")
    switch("d", "strip")
    switch("d", "lto")

    const
        splitted = NimVersion.split('.').map(parseInt)
        version = (splitted[0], splitted[1], splitted[2])

    when version > (1, 6, 2):
        switch("mm", "orc")
        switch("deepcopy", "on")

switch("d", "ssl")

# Raise exceptions instead of crashing, add traceback
# https://nim-lang.org/docs/manual.html#definitions
--panics:off
--stackTrace:on
--lineTrace:on
