import std/[unittest, strutils, options, math]
import specqr
proc rejects(code: string; f: proc() {.closure.}) =
  var caught = false
  try: f()
  except SpecQRError as e: caught = true; check e.code == code
  check caught
suite "portable renderers":
  test "implicit eight-pixel modules and PNG framing":
    let q = generate("HELLO")
    let p = q.toPixels
    check p.width == (q.size+8)*8
    check p.height == p.width
    check p.pixels.len == p.width*p.height*4
    let png = q.toPng
    check png[0..7] == @[137'u8, 80, 78, 71, 13, 10, 26, 10]
    check q.toPngDataUrl.startsWith("data:image/png;base64,")
    check q.toSvgDataUrl.startsWith("data:image/svg+xml;charset=utf-8,")
    check q.toSvg.contains("width=\"" & $p.width & "\"")
  test "every raster pixel maps to its owned module":
    let q = generate("A")
    let o = RenderOptions(scale: 3, margin: 2, foreground: "#12345678", background: "#abcdef90")
    let p = toPixels(q, o)
    for y in 0..<p.height:
      for x in 0..<p.width:
        let mx = x div 3-2; let my = y div 3-2
        let c = if mx >= 0 and mx < q.size and my >= 0 and my < q.size and q.matrix[my][mx]: [0x12,
            0x34, 0x56, 0x78] else: [0xab, 0xcd, 0xef, 0x90]
        for k in 0..<4: check p.pixels[(y*p.width+x)*4+k] == uint8(c[k])
  test "color and contrast safety":
    check parseColor("#abc").get == [170, 187, 204, 255]
    check parseColor("#abcd").get == [170, 187, 204, 221]
    check abs(contrastRatio([0, 0, 0, 255], [255, 255, 255, 255])-21) < 1e-10
    check parseColor("navy", false).isNone
    for color in ["", "url(x)", "<script>", "#ggg", "#12345", repeat("x", 65)]: rejects(
        "INVALID_COLOR", proc() = discard parseColor(color))
    rejects("INVALID_COLOR", proc() = discard toPng(generate("A"), RenderOptions(
        foreground: "navy")))
  test "geometry bounds and finite physical dimensions":
    let q = generate("A")
    for o in [RenderOptions(scale: 0), RenderOptions(margin: -1), RenderOptions(scale: high(int)),
        RenderOptions(margin: high(int)), RenderOptions(scale: 1_000_000_000)]: rejects(
        "INVALID_INPUT", proc() = discard toSvg(q, o))
    rejects("INVALID_INPUT", proc() = discard toPng(q, RenderOptions(scale: 100)))
    rejects("INVALID_INPUT", proc() = discard toSvg(@[@[true], @[false, true]]))
    for dpi in [NaN, Inf, -1.0, 1e-305]: rejects("INVALID_INPUT", proc() = discard renderDimensions(
        q.matrix, dpi = dpi))
    check renderDimensions(q.matrix, dpi = 300).moduleSizeMm > 0
