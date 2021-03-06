proc asEmoji*(b: bool): string =
  if b:
    return "โณ๏ธ"
  return "๐ซ"

const levels = [
  "(แ๏ธตแ) ๐ซ",
  "(>โก<) ๐๐ป",
  "(^//ฯ/^) โจ",
  "(เนโแบโเน) ๐บ",
]

proc asEmoji*(i: int): string =
  if i notin 0 ..< len(levels):
    return levels[0]
  return levels[i]
