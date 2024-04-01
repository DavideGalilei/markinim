when not defined(debug):
    switch("d", "release")
    switch("d", "strip")
    switch("d", "lto")

switch("mm", "orc")
switch("deepcopy", "on")

--d:ssl

# Raise exceptions instead of crashing, add traceback
# https://nim-lang.org/docs/manual.html#definitions
--panics:off
--stackTrace:on
--lineTrace:on
