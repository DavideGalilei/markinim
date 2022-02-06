import std / times

template unixTime*: int64 =
  getTime().toUnix
