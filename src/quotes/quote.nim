# Lora and Montserrat are under the Open Fonts License
# https://fonts.google.com/specimen/Lora#standard-styles
# https://fonts.google.com/specimen/Montserrat

import std / [os, random, strformat, oids]
import pkg / pixie


randomize()

const
  QUOTE_WIDTH = 1000
  QUOTE_HEIGHT = 1000


type QuoteConfig* = ref object
  fonts, strokeFonts: seq[Font]
  markinimFont: Font
  markinimImage: Image


proc getQuoteConfig*(): QuoteConfig =
  var
    thisDir = currentSourcePath.parentDir
    fonts = @[
      readFont(thisDir / "Lora-BoldItalic.ttf"),
      readFont(thisDir / "Oswald-SemiBold.ttf"),
    ]
    strokeFonts = @[
      readFont(thisDir / "Lora-BoldItalic.ttf"),
      readFont(thisDir / "Oswald-SemiBold.ttf"),
    ]
    markinimFont = readFont(thisDir / "Montserrat-ExtraBold.ttf")
    markinimImage = readImage(thisDir / "markinim.jpg")

  for font in fonts:
    font.size = min(QUOTE_WIDTH, QUOTE_HEIGHT) / 13

  for i in 0 ..< strokeFonts.len:
    strokeFonts[i].paint.color = color(1, 1, 1, 1)
    strokeFonts[i].size = fonts[i].size

  markinimFont.size = min(QUOTE_WIDTH, QUOTE_HEIGHT) / 25

  new result
  result.fonts = fonts
  result.strokeFonts = strokeFonts
  result.markinimFont = markinimFont
  result.markinimImage = markinimImage


proc genQuote*(text: string, config: QuoteConfig): string {.gcsafe.} =
  let
    blackWhite = rand(0 .. 1) == 1
    image = newImage(QUOTE_WIDTH, QUOTE_HEIGHT)
    finalpic = newImage(QUOTE_WIDTH, QUOTE_HEIGHT)
    paint = newPaint(LinearGradientPaint)
    randIdx = rand(0 ..< config.fonts.len)
    font = config.fonts[randIdx]
    strokeFont = config.strokeFonts[randIdx]

  # markinimFont.paint.color = if blackWhite: color(1, 192 / 255, 203 / 255, 1) else: color(0, 0, 0, 1)

  paint.blendMode = OverlayBlend
  paint.gradientHandlePositions = @[
    vec2(0, 0),
    vec2(float(image.width), float(image.height)),
  ]
  paint.gradientStops = @[
    ColorStop(color: color(rand(0.2 .. 1.0), rand(0.2 .. 1.0), rand(0.2 .. 1.0), if blackWhite: 0.5 else: 1), position: 0),
    ColorStop(color: color(rand(0.2 .. 1.0), rand(0.2 .. 1.0), rand(0.2 .. 1.0), if blackWhite: 0.5 else: 1), position: 1),
  ]

  image.fillGradient(paint)

  let strokeArrangement = strokeFont.typeset(text,
    bounds = vec2(image.width.float * 0.9, image.height.float * 0.9),
    hAlign = CenterAlign, vAlign = MiddleAlign
  )

  image.strokeText(
    strokeArrangement,
    translate(vec2(image.width.float / 20, image.width.float / 20)),
    strokeWidth = font.size / 10,
  )

  let arrangement = font.typeset(text,
    bounds = vec2(image.width.float * 0.9, image.height.float * 0.9),
    hAlign = CenterAlign, vAlign = MiddleAlign
  )

  image.fillText(
    arrangement,
    translate(vec2(image.width.float / 20, image.width.float / 20)),
  )

  # Watermark
  image.fillText(config.markinimFont, "@MarkinimBot",
    transform = translate(vec2(image.width / 2, image.height.float - config.markinimFont.size * 1.5)),
    hAlign = CenterAlign,
  )

  finalpic.draw(config.markinimImage)
  finalpic.draw(image)
  let finalFile = getTempDir() / &"markinim_quote_{genOid()}.png"
  finalpic.writeFile(finalFile)
  return finalFile


when isMainModule:
  let im = genQuote("Markinim quotes update", fonts, strokeFonts, markinimFont, markinimImage)
  echo im
  copyFile(im, "test.png")
  discard tryRemoveFile(im)
