proc asEmoji*(b: bool): string =
  if b:
    return "✳️"
  return "🚫"

const levels = [
  "(ᗒ︵ᗕ) 🚫",
  "(>◡<) 👍🏻",
  "(^//ω/^) ✨",
  "(๑ↀᆺↀ๑) 🌺",
]

proc asEmoji*(i: int): string =
  if i notin 0 ..< len(levels):
    return levels[0]
  return levels[i]
