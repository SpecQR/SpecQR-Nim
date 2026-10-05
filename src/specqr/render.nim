## Portable SVG and PNG (stored DEFLATE, CRC-32, Adler-32), no codec dependency.
import std/[strutils, math, options, base64]
import ./[errors, core]
const
  RasterPixelBudget* = 4*1024*1024
  SvgCharacterBudget* = 8*1024*1024
  DataUrlCharacterBudget* = 32*1024*1024
  MaxGeometryInteger* = 1_000_000_000
type
  Color* = array[4, int]
  Pixels* = object
    width*, height*: int
    pixels*: seq[uint8]
  RenderOptions* = object
    margin*: int = 4
    scale*: int = 8
    foreground*: string = "#000000"
    background*: string = "#ffffff"
proc colorText*(value: string): string =
  if value.len > 64: fail("INVALID_COLOR", "Color exceeds 64 bytes")
  result = value.strip()
  if result.len == 0: fail("INVALID_COLOR", "Color must not be empty")
  if result[0] == '#':
    if result.len notin [4, 5, 7, 9]: fail("INVALID_COLOR", "Invalid hex color")
    for c in result[1..^1]:
      if c notin HexDigits: fail("INVALID_COLOR", "Invalid hex color")
  else:
    for c in result:
      if c notin {'a'..'z', 'A'..'Z'}: fail("INVALID_COLOR", "Color must be hex or a simple ASCII CSS name")
proc parseColor*(value: string; strict = true): Option[Color] =
  let text = colorText(value).toLowerAscii()
  case text
  of "black": return some([0, 0, 0, 255])
  of "white": return some([255, 255, 255, 255])
  of "transparent": return some([0, 0, 0, 0])
  else: discard
  if text[0] == '#':
    let h = text[1..^1]
    var channels: Color = [0, 0, 0, 255]
    if h.len <= 4:
      for i, c in h: channels[i] = parseHexInt($c)*17
    else:
      for i in 0..<h.len div 2: channels[i] = parseHexInt(h[i*2..i*2+1])
    return some(channels)
  if strict: fail("INVALID_COLOR", "Raster colors require hex, black, white, or transparent")
  none(Color)
proc contrastRatio*(fg, bg: Color): float =
  for c in fg: discard requireRange(c, 0, 255, "Color channel", "INVALID_COLOR")
  for c in bg: discard requireRange(c, 0, 255, "Color channel", "INVALID_COLOR")
  let ba = float(bg[3])/255; let fa = float(fg[3])/255
  let weights = [0.2126, 0.7152, 0.0722]
  var a, b: float
  for i in 0..<3:
    let back = float(bg[i])/255*ba+1-ba
    let front = float(fg[i])/255*fa+back*(1-fa)
    let fl = if front <= 0.04045: front/12.92 else: pow((front+0.055)/1.055, 2.4)
    let bl = if back <= 0.04045: back/12.92 else: pow((back+0.055)/1.055, 2.4)
    a+=fl*weights[i]; b+=bl*weights[i]
  (max(a, b)+0.05)/(min(a, b)+0.05)
proc geometry*(matrix: Matrix; o: RenderOptions; raster = false): int =
  validateMatrix(matrix)
  discard requireRange(o.margin, 0, MaxGeometryInteger, "Margin")
  discard requireRange(o.scale, 1, MaxGeometryInteger, "Scale")
  if o.margin > (MaxGeometryInteger-matrix.len) div 2: fail("INVALID_INPUT", "Render geometry exceeds bound")
  let span = matrix.len+2*o.margin
  if o.scale > MaxGeometryInteger div span: fail("INVALID_INPUT", "Render geometry exceeds bound")
  result = span*o.scale
  if raster and result > 2048: fail("INVALID_INPUT", "Raster exceeds pixel budget")
proc toSvg*(matrix: Matrix; o = RenderOptions()): string =
  let d = geometry(matrix, o)
  let fg = colorText(o.foreground); let bg = colorText(o.background)
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $d & "\" height=\"" & $d &
      "\" viewBox=\"0 0 " & $d & " " & $d &
      "\" role=\"img\"><rect width=\"100%\" height=\"100%\" fill=\"" & bg & "\"/><path fill=\"" &
      fg & "\" d=\""
  for y, row in matrix:
    for x, dark in row:
      if dark: result.add("M" & $((x+o.margin)*o.scale) & "," & $((y+o.margin)*o.scale) & "h" &
          $o.scale & "v" & $o.scale & "h-" & $o.scale & "z")
  result.add("\"/></svg>")
  if result.len > SvgCharacterBudget: fail("INVALID_INPUT", "SVG exceeds character budget")
proc toPixels*(matrix: Matrix; o = RenderOptions()): Pixels =
  let d = geometry(matrix, o, true)
  let fg = parseColor(o.foreground).get(); let bg = parseColor(o.background).get()
  result = Pixels(width: d, height: d, pixels: newSeq[uint8](4*d*d))
  var at = 0
  for y in 0..<d:
    let my = y div o.scale-o.margin
    for x in 0..<d:
      let mx = x div o.scale-o.margin
      let c = if my >= 0 and my < matrix.len and mx >= 0 and mx < matrix.len and matrix[my][
          mx]: fg else: bg
      for k in 0..<4: result.pixels[at] = uint8(c[k]); inc at
proc crcTable(): array[256, uint32] =
  for i in 0..<256:
    var c = uint32(i)
    for j in 0..<8: c = (c shr 1) xor (if (c and 1) != 0: 0xedb88320'u32 else: 0'u32)
    result[i] = c
const CrcTable = crcTable()
proc adler(data: openArray[uint8]): uint32 =
  var a = 1'u32; var b = 0'u32
  for v in data: a = (a+uint32(v)) mod 65521; b = (b+a) mod 65521
  (b shl 16) or a
proc be32(dest: var seq[uint8]; n: uint32) =
  for shift in [24, 16, 8, 0]: dest.add(uint8((n shr shift) and 255))
proc chunk(dest: var seq[uint8]; kind: string; data: openArray[uint8]) =
  dest.be32(uint32(data.len))
  var c = 0xffffffff'u32
  for b in kind:
    dest.add(uint8(b)); c = CrcTable[int((c xor uint32(b)) and 255)] xor (c shr 8)
  for b in data:
    dest.add(b); c = CrcTable[int((c xor uint32(b)) and 255)] xor (c shr 8)
  dest.be32(c xor 0xffffffff'u32)
proc toPng*(matrix: Matrix; o = RenderOptions()): seq[uint8] =
  let image = toPixels(matrix, o)
  let stride = 4*image.width
  var raw = newSeq[uint8]((stride+1)*image.height)
  for y in 0..<image.height:
    for x in 0..<stride: raw[y*(stride+1)+1+x] = image.pixels[y*stride+x]
  var z = @[0x78'u8, 0x01'u8]
  var p = 0
  while p < raw.len:
    let n = min(65535, raw.len-p); let inv = n xor 65535
    z.add(uint8(p+n == raw.len)); z.add(uint8(n and 255)); z.add(uint8(n shr 8)); z.add(uint8(
        inv and 255)); z.add(uint8(inv shr 8))
    for i in p..<p+n: z.add(raw[i])
    p+=n
  z.be32(adler(raw))
  var header: seq[uint8]
  header.be32(uint32(image.width)); header.be32(uint32(image.height)); header.add([8'u8, 6, 0, 0, 0])
  result = @[137'u8, 80, 78, 71, 13, 10, 26, 10]
  result.chunk("IHDR", header); result.chunk("IDAT", z); result.chunk("IEND", [])
proc toSvgDataUrl*(matrix: Matrix; o = RenderOptions()): string =
  let svg = toSvg(matrix, o)
  if svg.len > (DataUrlCharacterBudget-31) div 3: fail("INVALID_INPUT", "SVG URL exceeds budget")
  result = "data:image/svg+xml;charset=utf-8,"
  for c in svg:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '~', '!', '*', '\'', '(', ')', '-', '.',
        '_'}: result.add(c)
    else: result.add('%'); result.add(toHex(ord(c), 2))
proc toPngDataUrl*(matrix: Matrix; o = RenderOptions()): string =
  let png = toPng(matrix, o)
  if ((png.len+2) div 3)*4+22 > DataUrlCharacterBudget: fail("INVALID_INPUT", "PNG URL exceeds budget")
  "data:image/png;base64," & base64.encode(png)
proc renderDimensions*(matrix: Matrix; o = RenderOptions(); dpi = 0.0): tuple[width, height,
    modulePixels, marginModules: int; dpi, moduleSizeMm, symbolSizeMm: float] =
  let d = geometry(matrix, o)
  result = (d, d, o.scale, o.margin, dpi, 0.0, 0.0)
  if dpi != 0.0:
    if classify(dpi) in {fcNan, fcInf, fcNegInf} or dpi <= 0: fail("INVALID_INPUT", "DPI must be positive and finite")
    result.moduleSizeMm = float(o.scale)/dpi*25.4; result.symbolSizeMm = float(d)/dpi*25.4
    if classify(result.moduleSizeMm) in {fcNan, fcInf, fcNegInf} or result.moduleSizeMm <= 0 or
        classify(result.symbolSizeMm) in {fcNan, fcInf, fcNegInf} or result.symbolSizeMm <= 0: fail(
        "INVALID_INPUT", "Print geometry must be finite and positive")
