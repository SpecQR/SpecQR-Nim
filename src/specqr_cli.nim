## Standalone native CLI. No shelling out, external codec, or network calls.
import std/[os, strutils, json, options]
import specqr
const Help = """SpecQR Nim 0.1.0
Usage: specqr_cli (--text TEXT | --text-file FILE | --bytes-file FILE) [options]
  --format svg|png|svg-data-url|png-data-url|matrix|json (default svg)
  --output FILE             Write output to FILE instead of stdout
  --ecc L|M|Q|H             Error correction (default M)
  --version 1..40           Fixed version; otherwise automatic
  --min-version N --max-version N --mask 0..7 --mode auto|numeric|alphanumeric|byte|kanji
  --eci N                  ECI label (26 is UTF-8; no transcoding)
  --gs1 --fnc1 --fnc1-second A --boost --no-optimize --no-kanji
  --margin N --scale N      Quiet zone and pixels/module (defaults 4 and 8)
  --foreground COLOR --background COLOR --print-dpi N
  --plan                   Output arithmetic-only planning JSON
  --structured-append      Output 2..16-symbol JSON set; use --format json
  --max-symbols N          Maximum Structured Append symbols
  --help --version-info
Text files must be shortest-form UTF-8. Byte files are never interpreted as text.
Matrix rows are 0/1 strings; x/y in the library use zero-based coordinates.
"""
proc cliInteger(s, label: string): int =
  try: result = parseInt(s)
  except ValueError: fail("INVALID_INPUT", label & " must be a native-range integer")
proc boundedRead(path: string; binary: bool): string =
  let limit = if binary: MaxPayloadUnits else: 4*MaxPayloadUnits
  if getFileSize(path) > int64(limit): fail("DATA_TOO_LONG", "Input file exceeds resource budget")
  let file = open(path, fmRead)
  defer: file.close()
  var buffer: array[8192, char]
  while true:
    let remaining = limit + 1 - result.len
    let n = file.readBuffer(addr buffer[0], min(buffer.len, remaining))
    if n == 0: break
    for i in 0..<n: result.add(buffer[i])
    if result.len > limit: fail("DATA_TOO_LONG", "Input file exceeds resource budget")
proc matrixJson(q: QRResult): JsonNode =
  result = newJArray()
  for row in q.matrix:
    var r = ""
    for b in row: r.add(if b: '1' else: '0')
    result.add(%r)
proc qJson(q: QRResult): JsonNode =
  %*{"version": q.version, "errorCorrectionLevel": q.errorCorrectionLevel,
      "maskPattern": q.maskPattern, "matrix": matrixJson(q), "diagnostics": q.diagnostics}
proc main() =
  var o = Options(); var input = ""; var source = ""; var target = ""; var format = "svg"
  var planning = false; var sa = false; var maximum = 16
  let args = commandLineParams(); var i = 0
  proc value(): string =
    inc i
    if i >= args.len: fail("INVALID_INPUT", "Missing option value")
    args[i]
  while i < args.len:
    let arg = args[i]
    case arg
    of "--help", "-h": stdout.write(Help); return
    of "--version-info": stdout.write("SpecQR Nim 0.1.0; Nim " & NimVersion & "\n"); return
    of "--text", "--text-file", "--bytes-file":
      if source != "": fail("INVALID_INPUT", "Specify exactly one input source")
      source = arg; input = value()
    of "--output", "-o": target = value()
    of "--format": format = value()
    of "--ecc": o.errorCorrectionLevel = value()
    of "--version": o.version = requireRange(cliInteger(value(), arg),1,40,"Version","INVALID_VERSION")
    of "--min-version": o.minVersion = cliInteger(value(), arg)
    of "--max-version": o.maxVersion = cliInteger(value(), arg)
    of "--mask": o.maskPattern = requireRange(cliInteger(value(), arg),0,7,"Mask")
    of "--mode": o.mode = value()
    of "--eci": o.eciAssignment = requireRange(cliInteger(value(), arg),0,999999,"ECI","INVALID_ECI")
    of "--gs1": o.gs1 = true
    of "--fnc1": o.fnc1 = true
    of "--fnc1-second": o.fnc1Second = value()
    of "--no-optimize": o.optimizeSegments = false
    of "--no-kanji": o.allowKanji = false
    of "--boost": o.boostErrorCorrection = true
    of "--margin": o.margin = cliInteger(value(), arg)
    of "--scale": o.scale = cliInteger(value(), arg)
    of "--foreground": o.foreground = value()
    of "--background": o.background = value()
    of "--print-dpi":
      try: o.printDpi = some(parseFloat(value()))
      except ValueError: fail("INVALID_INPUT", "DPI must be numeric")
    of "--plan": planning = true
    of "--structured-append": sa = true
    of "--max-symbols": maximum = cliInteger(value(), arg)
    else: fail("INVALID_INPUT", "Unknown option: " & arg)
    inc i
  if source == "": fail("INVALID_INPUT", "An explicit text or byte input source is required")
  if format notin ["svg", "png", "svg-data-url", "png-data-url", "matrix", "json"]: fail(
      "INVALID_OUTPUT", "Unsupported output format")
  if planning and sa: fail("INVALID_MODE", "Planning and Structured Append are separate operations")
  if sa and format != "json": fail("INVALID_OUTPUT", "Structured Append requires --format json")
  if source != "--text": input = boundedRead(input, source == "--bytes-file")
  var bytes: seq[uint8]
  if source == "--bytes-file":
    for c in input: bytes.add(uint8(c))
  var output = ""
  if planning:
    let p = if source == "--bytes-file": plan(bytes, o) else: plan(input, o)
    output = $(%*{"ok": p.ok, "version": p.version, "capacityVersion": p.capacityVersion,
        "dataBitLength": p.dataBitLength, "capacityBits": p.capacityBits,
        "remainingBits": p.remainingBits, "diagnostics": p.diagnostics}) & "\n"
  elif sa:
    let set = if source == "--bytes-file": generateStructuredAppend(bytes, o,
        maximum) else: generateStructuredAppend(input, o, maximum)
    var symbols = newJArray()
    for q in set.symbols: symbols.add(qJson(q))
    output = $(%*{"total": set.total, "parity": set.parity, "inputLength": set.inputLength,
        "byteLength": set.byteLength, "symbols": symbols, "diagnostics": set.diagnostics}) & "\n"
  else:
    let q = if source == "--bytes-file": generate(bytes, o) else: generate(input, o)
    case format
    of "svg": output = q.toSvg & "\n"
    of "png":
      let data = q.toPng
      output = newString(data.len)
      for j, b in data: output[j] = char(b)
    of "svg-data-url": output = q.toSvgDataUrl & "\n"
    of "png-data-url": output = q.toPngDataUrl & "\n"
    of "matrix": output = $matrixJson(q) & "\n"
    else: output = $qJson(q) & "\n"
  if target == "": stdout.write(output); stdout.flushFile()
  else: writeFile(target, output)
when isMainModule:
  try: main()
  except SpecQRError as e: stderr.write(e.code & ": " & e.msg & "\n"); quit(2)
  except IOError as e: stderr.write("IO_ERROR: " & e.msg & "\n"); quit(2)
  except OSError as e: stderr.write("IO_ERROR: " & e.msg & "\n"); quit(2)
