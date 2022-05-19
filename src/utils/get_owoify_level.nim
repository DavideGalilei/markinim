const levels = ["owo", "uwu", "uvu"]

func getOwoifyLevel*(level: int): string =
  if level in 0 ..< len(levels):
    return levels[level]
  return levels[0]
