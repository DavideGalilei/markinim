import random, unicode

const emojiRanges = @[
  @[0x1F600, 0x1F64F], # Emoticons
  @[0x1F300, 0x1F5FF], # Misc Symbols and Pictographs
  @[0x1F680, 0x1F6FF], # Transport and Map
  @[0x1F1E6, 0x1F1FF], # Regional country flags
  @[0x2600, 0x26FF],   # Misc symbols
  @[0x2700, 0x27BF],   # Dingbats
  @[0x1F900, 0x1F9FF], # Supplemental Symbols and Pictographs
  @[0x1F018, 0x1F270], # Various asian characters
  @[0x238C, 0x2454],   # Misc items
  @[0x1F300, 0x1F5FF], # Misc Symbols and Pictographs
  @[0x1F600, 0x1F64F], # Emoticons
  @[0x1F680, 0x1F6FF], # Transport and Map
  @[0x1F1E6, 0x1F1FF], # Regional country flags
  @[0x2600, 0x26FF],   # Misc symbols
  @[0x2700, 0x27BF],   # Dingbats
  @[0x1F900, 0x1F9FF], # Supplemental Symbols and Pictographs
  @[0x1F018, 0x1F270], # Various asian characters
  @[0x238C, 0x2454],   # Misc items
]

proc randomEmoji*(): string =
  randomize()
  let randRange = rand(0..emojiRanges.len - 1)
  let emojiRange = emojiRanges[randRange]
  let
    startRange = emojiRange[0]
    endRange = emojiRange[1]

  let randomCodePoint = rand(startRange..endRange)
  return $Rune(randomCodePoint)
