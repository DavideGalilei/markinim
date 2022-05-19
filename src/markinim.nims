import std / [strutils, sequtils]

switch("d", "release")
switch("d", "lto")

const
    splitted = NimVersion.split('.').map(parseInt)
    version = (splitted[0], splitted[1], splitted[2])

when version > (1, 6, 2):
    switch("mm", "orc")
    switch("deepcopy", "on")

switch("d", "strip")
