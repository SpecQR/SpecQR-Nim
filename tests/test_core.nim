import std/[unittest, unicode, strutils, random, options, json, math]
import specqr
proc expectCode(code: string; action: proc() {.closure.}) =
  var caught = false
  try: action()
  except SpecQRError as e: caught = true; check e.code == code
  check caught
proc slowOptimal(text: string; version: int; allowKanji = true): int =
  let chars = strictUtf8(text)
  var dp = newSeq[int](chars.len+1)
  for i in 1..chars.len: dp[i] = high(int) div 4
  for i in 0..<chars.len:
    var chunk = ""
    for j in i..<chars.len:
      chunk.add(chars[j].toUTF8)
      for mode in DataModes:
        if mode == "kanji" and not allowKanji: continue
        try:
          let s = newSegment(mode, chunk)
          if s.count < (1 shl characterCountBits(version, mode)): dp[j+1] = min(dp[j+1], dp[
              i]+s.bitLength(version))
        except SpecQRError: discard
  if chars.len == 0: 12+int(version >= 10)*8 else: dp[^1]
suite "native QR invariants":
  test "all versions, block tables, capacities, exact bounds":
    for v in 1..40:
      check qrSize(v) == 17+4*v
      let positions = alignmentPositions(v)
      if v == 1: check positions.len == 0
      else: check positions[0] == 6; check positions[^1] == qrSize(v)-7
      for level in ErrorCorrectionLevels:
        let info = blockInfo(v, level)
        check info.dataCodewords+info.blocks*info.eccPerBlock == rawCodewordCount(v)
        for mode in DataModes:
          let c = getCapacity(v, level, mode)
          check c.maximum >= 0
          let text = repeat(if mode == "numeric": "1" elif mode == "alphanumeric": "A" elif mode ==
              "kanji": "漢" else: "a", c.maximum)
          check plan(text, Options(version: v, errorCorrectionLevel: level, mode: mode)).ok
          check not plan(text & (if mode == "kanji": "漢" else: "a"), Options(version: v,
              errorCorrectionLevel: level, mode: "byte")).ok or mode != "byte"
          let excess = text & (if mode == "numeric": "1" elif mode ==
              "alphanumeric": "A" elif mode == "kanji": "漢" else: "a")
          check not plan(excess, Options(version: v, errorCorrectionLevel: level, mode: mode)).ok
  test "field arithmetic and Reed Solomon":
    check gfMultiply(0x57, 0x83) == 0x31
    for x in 0..255: check gfMultiply(x, 0) == 0; check gfMultiply(x, 1) == x
    for degree in 1..255:
      let g = reedSolomonDivisor(degree)
      check g.len == degree+1; check g[0] == 1
      check reedSolomonRemainder([], degree) == newSeq[uint8](degree)
  test "matrix copy independence and mask determinism":
    var a = generate("HELLO", Options(version: 1, errorCorrectionLevel: "L", maskPattern: 0))
    let expected = a.matrix[0][0]
    var b = a
    b.matrix[0][0] = not expected
    check a.matrix[0][0] == expected
    var c = copyMatrix(a.matrix); c[1][1] = not c[1][1]
    check c[1][1] != a.matrix[1][1]
    let auto = generate("HELLO")
    let manual = generate("HELLO", Options(maskPattern: auto.maskPattern))
    check auto.matrix == manual.matrix
    check auto.diagnostics["mask_penalties"].len == 8
  test "owned binary inputs and outputs":
    var bytes = @[0'u8, 255, 128, 65]
    let s = byteSegment(bytes)
    bytes[0] = 99
    check s.logicalBytes == @[0'u8, 255, 128, 65]
    var copy = s.logicalBytes; copy[0] = 77
    check s.logicalBytes[0] == 0
    var text = "ABC"; let seg = byteSegment(text); text[0] = 'Z'; check seg.text == "ABC"
  test "strict UTF-8 versus opaque binary":
    for invalid in ["\xc0\x80", "\xe0\x80\x80", "\xf0\x80\x80\x80", "\xed\xa0\x80",
        "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\x80", "\xc2", "\xe2\x82", "\xff"]:
      expectCode("INVALID_INPUT", proc() = discard generate(invalid))
      var bytes: seq[uint8]
      for c in invalid: bytes.add(uint8(c))
      check generate(bytes).version >= 1
    check byteSegment("\0é🙂漢字").characterCount == 6
    check newSegment("kanji", "漢字").byteCount == 4
  test "control headers and ordered restrictions":
    for n in [0, 127, 128, 16383, 16384, 999999]: check eci(n).bits(1).len == eci(n).bitLength(1)
    check fnc1Second("A").applicationIndicatorCodeword == 165
    check fnc1Second("99").applicationIndicatorCodeword == 99
    check structuredAppendSegment(16, 16, 255).bits(1).len == 20
    expectCode("INVALID_GS1", proc() = discard generateSegments([byteSegment("A"), fnc1()]))
    expectCode("INVALID_GS1", proc() = discard generateSegments([fnc1(), eci(26), byteSegment("A")]))
    expectCode("INVALID_MODE", proc() = discard generateSegments([eci(26), fnc1Second("A"),
        byteSegment("A")]))
    expectCode("INVALID_MODE", proc() = discard generateSegments([Segment()]))
    check generateSegments([eci(26), byteSegment("A"), eci(3), byteSegment([255'u8])]).version > 0
  test "exact optimizer independent brute-force":
    var rng = initRand(192831)
    let alphabet = ["0", "1", "9", "A", " ", "%", "a", "é", "漢", "🙂"]
    for v in [1, 10, 27]:
      for allow in [false, true]:
        for trial in 0..<160:
          var text = ""
          for i in 0..<rng.rand(0..18): text.add(alphabet[rng.rand(alphabet.high)])
          let actual = optimizeSegments(text, v, allow)
          check segmentsBitLength(actual, v) == slowOptimal(text, v, allow)
    let long = repeat("a", 700)
    let chunks = optimizeSegments(long, 1)
    for s in chunks: check s.count <= 255
    check segmentsBitLength(chunks, 1) == 700*8+3*12
  test "planning-only diagnostics and boost":
    let p = plan("HELLO", Options(errorCorrectionLevel: "L", boostErrorCorrection: true))
    check p.errorCorrectionLevel == "H"
    check p.diagnostics["phase"].getStr == "planning"
    check not p.diagnostics["codewords_built"].getBool
    check not p.diagnostics["mask_evaluated"].getBool
    let q = generate("HELLO", Options(errorCorrectionLevel: "L", boostErrorCorrection: true))
    check q.errorCorrectionLevel == p.errorCorrectionLevel
    check p.dataBitLength == q.diagnostics["data_bit_length"].getInt
    let overflow = plan(repeat("a", 4000), Options(mode: "byte"))
    check not overflow.ok; check overflow.version == 0; check overflow.capacityVersion == 40
  test "GS1 literal percent and GS data preserved":
    let q = generate("ABC%%DEF", Options(fnc1: true))
    check q.segments[1].mode == "byte"; check q.segments[1].text == "ABC%%DEF"
    expectCode("INVALID_MODE", proc() = discard generate("A%", Options(fnc1: true,
        mode: "alphanumeric")))
    let manual = generateSegments([fnc1(), alphanumeric("A%%B%C")])
    check manual.segments[1].text == "A%%B%C"
  test "resources and integer-overflow rejection":
    for v in [low(int), -1, 0, 41, high(int)]: expectCode("INVALID_VERSION", proc() = discard qrSize(v))
    expectCode("INVALID_INPUT", proc() = discard getCapacity(1, controlBits = -1))
    check getCapacity(1, mode = "byte", controlBits = high(int)).maximum == 0
    expectCode("DATA_TOO_LONG", proc() = discard byteSegment(newSeq[uint8](1_000_001)))
    expectCode("DATA_TOO_LONG", proc() = discard optimizeSegments(repeat("a", 7090)))
    expectCode("DATA_TOO_LONG", proc() = discard generate(newSeq[uint8](3000)))
    expectCode("INVALID_INPUT", proc() = discard generate("A", Options(printDpi: some(1e-305))))
    expectCode("INVALID_INPUT", proc() = discard generate("A", Options(printDpi: some(NaN))))
    expectCode("INVALID_ECC_LEVEL", proc() = discard generate("A", Options(
        errorCorrectionLevel: "toString")))

  test "uninitialized result diagnostics are checked":
    expectCode("INVALID_INPUT", proc() = discard diagnostics(QRResult()))
    expectCode("INVALID_INPUT", proc() = discard diagnostics(Plan()))
    expectCode("INVALID_INPUT", proc() = discard diagnostics(SAResult()))
    expectCode("INVALID_INPUT", proc() = discard diagnostics(MergeResult()))
    expectCode("INVALID_INPUT", proc() = discard moduleAt(QRResult(matrix: @[@[]]), 0, 0))
    var nilArray = newJArray(); nilArray.add(JsonNode(nil))
    expectCode("INVALID_INPUT", proc() = discard mergeStructuredAppendParts(nilArray))
    for key in ["index", "total", "parity", "data"]:
      var part = %*{"index": 1, "total": 2, "parity": 0, "data": "A"}
      part[key] = nil
      var parts = newJArray(); parts.add(part)
      expectCode("INVALID_INPUT", proc() = discard mergeStructuredAppendParts(parts))
    var part = %*{"index": 1, "total": 2, "parity": 0, "data": []}
    part["data"].add(JsonNode(nil))
    expectCode("INVALID_INPUT", proc() = discard mergeStructuredAppendParts(%*[part]))
    var nested = newJObject(); nested["nil"] = nil
    expectCode("INVALID_INPUT", proc() = discard diagnostics(QRResult(diagnostics: nested)))
    var cyclic = newJArray(); cyclic.add(cyclic)
    expectCode("INVALID_INPUT", proc() = discard diagnostics(QRResult(diagnostics: cyclic)))
