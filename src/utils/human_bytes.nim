import std / strformat

proc humanBytes*(num: int | BiggestInt, suffix: string = "B"): string =
  var num = num
  for unit in ["", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi"]:
    if abs(num) < 1024:
      return fmt"{num:.1}{unit}{suffix}"
    num = num div 1024
  return fmt"{num:.1}Yi{suffix}"

when isMainModule:
  echo humanBytes(500_000_000)
