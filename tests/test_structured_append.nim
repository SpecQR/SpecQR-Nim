import std/[json, options, strutils, unicode, unittest]
import specqr/[api, errors, segments, structured_append]

template expectCode(expected: string; body: untyped) =
  block:
    var caught = false
    try:
      body
    except SpecQRError as e:
      caught = true
      check e.code == expected
    check caught

proc bytesOf(s: string): seq[uint8] =
  for c in s: result.add uint8(c)
proc flatten(r: SAResult): string =
  for q in r.symbols:
    for s in q.segments:
      if not s.isControl: result.add s.text
proc hx(data: openArray[uint8]): string =
  for b in data: result.add toHex(int(b), 2).toLowerAscii

suite "Structured Append parity":
  test "text means original UTF-8 and binary is opaque":
    for text in ["", "A", "漢字", "é🙂漢é", "a\0b", "é", "é"]:
      check calculateStructuredAppendParity(text) == calculateStructuredAppendParity(bytesOf(text))
    check calculateStructuredAppendParity("A") == 65
    check calculateStructuredAppendParity(@[0'u8, 255, 1]) == 254
    check calculateStructuredAppendParity("é") != calculateStructuredAppendParity("é")
  test "manual modes do not alter logical UTF-8 parity":
    let segs = @[numeric("123"), alphanumeric("AB%"), kanji("漢字"), byteSegment(@[0'u8, 255])]
    let expected = calculateStructuredAppendParity("123AB%漢字") xor 255
    check calculateStructuredAppendSegmentsParity(segs) == expected
  test "parity bounds and invalid UTF-8 are typed errors":
    expectCode("DATA_TOO_LONG"): discard calculateStructuredAppendParity(newSeq[uint8](
        MaxPayloadUnits + 1))
    expectCode("INVALID_INPUT"): discard calculateStructuredAppendParity("\xff")
    expectCode("INVALID_INPUT"): discard calculateStructuredAppendSegmentsParity(newSeq[Segment](0))
    expectCode("INVALID_GS1"): discard calculateStructuredAppendSegmentsParity([fnc1(), numeric("1")])
    expectCode("INVALID_MODE"): discard calculateStructuredAppendSegmentsParity([eci(26),
        byteSegment("x")])

suite "Structured Append generation":
  test "known alphanumeric split matches public data codewords":
    let r = generateStructuredAppend(repeat('A', 31), Options(version: 1, errorCorrectionLevel: "L",
        maskPattern: 0, mode: "alphanumeric"))
    check r.total == 2
    check r.parity == 65
    check r.inputLength == 31
    check r.byteLength == 31
    check hx(r.symbols[0].dataCodewords) == "3014120a9cc398730e61cc398730e61cc39850"
    check hx(r.symbols[1].dataCodewords) == "311412051cc398730e61cc00ec11ec11ec11ec"
    check flatten(r) == repeat('A', 31)
    for i, q in r.symbols:
      check q.version == 1
      check q.maskPattern == 0
      check q.segments[0].mode == "structured-append"
      check q.segments[0].index == i + 1
      check q.segments[0].total == 2
      check q.segments[0].parity == 65
      check q.segments[0].bitLength(1) == 20
  test "Unicode byte split never cuts inside a scalar":
    let text = repeat("é🙂漢é", 8)
    let r = generateStructuredAppend(text, Options(version: 2, errorCorrectionLevel: "M",
        mode: "byte", maskPattern: 5))
    check r.total == 4
    check r.inputLength == 40
    check r.byteLength == 96
    check flatten(r) == text
    var nextByte = 0
    var nextInput = 0
    for i, q in r.symbols:
      let detail = r.diagnostics["symbols"][i]
      check detail["byte_start"].getInt == nextByte
      check detail["input_start"].getInt == nextInput
      nextByte += detail["byte_length"].getInt
      nextInput += detail["input_length"].getInt
      for s in q.segments:
        if not s.isControl: check validateUtf8(s.text) == -1
    check nextByte == r.byteLength
    check nextInput == r.inputLength
  test "binary bytes preserve all octets and use complete ordered headers":
    var data: seq[uint8]
    for i in 0..<240: data.add uint8(i)
    let r = generateStructuredAppend(data, Options(version: 1, errorCorrectionLevel: "L",
        maskPattern: 0), diagnostics = true)
    check r.total == 16
    check bytesOf(flatten(r)) == data
    check r.diagnostics["warnings"].len == 2
    check r.diagnostics["symbols"][15]["sequence_indicator"].getInt == 255
    check r.diagnostics["symbols"][15]["input_start"].getInt == 225
    expectCode("DATA_TOO_LONG"):
      discard generateStructuredAppend(data, Options(version: 1, errorCorrectionLevel: "L"),
          maxSymbols = 15)
  test "automatic version uses the smallest splittable range version":
    let r = generateStructuredAppend(repeat("abcdefghij", 100), Options(errorCorrectionLevel: "M",
        maskPattern: 0), maxSymbols = 4)
    check r.total in 2..4
    check r.symbols[0].version > 1
    check r.diagnostics["version_selection"].getStr == "auto-minimum"
    for q in r.symbols: check q.version == r.symbols[0].version
    check flatten(r) == repeat("abcdefghij", 100)
  test "optimization and no optimization both preserve payload":
    let text = repeat("1234567890123456789abc漢字HELLO WORLD", 4)
    let optimized = generateStructuredAppend(text, Options(version: 2, maskPattern: 0))
    let unoptimized = generateStructuredAppend(text, Options(version: 2, maskPattern: 0,
        optimizeSegments: false))
    check optimized.total == 5
    check unoptimized.total == 7
    check flatten(optimized) == text
    check flatten(unoptimized) == text
  test "single-symbol empty and resource-excess requests are rejected":
    expectCode("INVALID_INPUT"): discard generateStructuredAppend("")
    expectCode("INVALID_INPUT"): discard generateStructuredAppend("a")
    expectCode("INVALID_INPUT"): discard generateStructuredAppend(newSeq[uint8](0))
    expectCode("DATA_TOO_LONG"): discard generateStructuredAppend(repeat('A', MaxPayloadUnits))
    expectCode("DATA_TOO_LONG"): discard generateStructuredAppend(newSeq[uint8](MaxPayloadUnits + 1))
    expectCode("DATA_TOO_LONG"): discard generateStructuredAppend(repeat('a', 1000), Options(
        version: 1), maxSymbols = 2)
  test "controls boosting mode conflicts and invalid maxSymbols":
    let text = repeat('A', 80)
    expectCode("INVALID_GS1"): discard generateStructuredAppend(text, Options(gs1: true))
    expectCode("INVALID_MODE"): discard generateStructuredAppend(text, Options(fnc1: true))
    expectCode("INVALID_MODE"): discard generateStructuredAppend(text, Options(eciAssignment: 0))
    expectCode("INVALID_MODE"): discard generateStructuredAppend(text, Options(fnc1Second: "37"))
    expectCode("INVALID_MODE"):
      discard generateStructuredAppend(text, Options(structuredAppend: some(structuredAppendSegment(
          1, 2, 0))))
    expectCode("INVALID_MODE"): discard generateStructuredAppend(text, Options(
        boostErrorCorrection: true))
    expectCode("INVALID_MODE"): discard generateStructuredAppend(text, maxSymbols = 1)
    expectCode("INVALID_MODE"): discard generateStructuredAppend(text, maxSymbols = 17)
    expectCode("INVALID_MODE"): discard generateStructuredAppend(@[1'u8, 2, 3], Options(
        mode: "numeric"))

suite "Manual Structured Append":
  test "non-byte segments remain indivisible and caller modes are preserved":
    let values = @[alphanumeric("ABCDEFGHIJKLMNOPQRSTU"), numeric("12345678901234567890"),
        byteSegment(@[0'u8, 1, 2, 255])]
    let r = generateSegmentsStructuredAppend(values, Options(version: 1, errorCorrectionLevel: "L",
        maskPattern: 0), splitUnits = "full", symbolResults = "diagnostics")
    check r.total == 2
    check r.inputLength == 3
    check r.byteLength == 45
    check r.parity == 189
    check hx(r.symbols[0].dataCodewords) == "301bd20a9cd452a1570b3d732fd628cada12f0"
    check hx(r.symbols[1].dataCodewords) == "311bd10507b7231503159a9ad2020000817f80"
    check r.symbols[0].segments[1].mode == "alphanumeric"
    check r.symbols[0].segments[1].text == "ABCDEFGHIJKLMNOPQRSTU"
    check r.symbols[1].segments[1].mode == "numeric"
    check r.diagnostics["split_unit_count"].getInt == 6
    check r.diagnostics["split_units"].len == 6
    check r.diagnostics["split_units"][0]["unit_length"].getInt == 21
    check r.diagnostics["split_units"][1]["byte_start"].getInt == 21
  test "byte text scalar units and raw byte units retain separate boundaries":
    let text = repeat("🙂éé", 12)
    let r = generateSegmentsStructuredAppend([byteSegment(text)], Options(version: 1,
        errorCorrectionLevel: "L", maskPattern: 3), splitUnits = "full")
    check r.total == 8
    check r.inputLength == 1
    check r.diagnostics["split_unit_count"].getInt == 48
    check flatten(r) == text
    for unit in r.diagnostics["split_units"]:
      check unit["byte_length"].getInt in [1, 2, 4]
      check unit["unit_length"].getInt == 1
  test "adjacent manual byte segments are never merged implicitly":
    let values = @[byteSegment("abcdefghijk"), byteSegment("ABCDEFGHIJK"), byteSegment(@[1'u8, 2, 3,
        4, 5, 6, 7, 8])]
    let r = generateSegmentsStructuredAppend(values, Options(version: 1, errorCorrectionLevel: "L",
        maskPattern: 4))
    check r.total == 3
    check hx(r.symbols[0].dataCodewords) == "3022840b6162636465666768696a6b40241420"
    check r.symbols[0].segments.len == 3
    check r.symbols[0].segments[1].text == "abcdefghijk"
    check r.symbols[0].segments[2].text == "AB"
  test "indivisible oversized manual segment is rejected":
    expectCode("DATA_TOO_LONG"):
      discard generateSegmentsStructuredAppend([numeric(repeat('1', 100))], Options(version: 1,
          errorCorrectionLevel: "L"))
    expectCode("INVALID_INPUT"):
      discard generateSegmentsStructuredAppend([byteSegment("")])
    expectCode("INVALID_MODE"):
      discard generateSegmentsStructuredAppend([byteSegment(repeat('a', 100))], Options(mode: "byte"))
    expectCode("INVALID_MODE"):
      discard generateSegmentsStructuredAppend([byteSegment(repeat('a', 100))], Options(
          optimizeSegments: false))
    expectCode("INVALID_INPUT"):
      discard generateSegmentsStructuredAppend([byteSegment(repeat('a', 100))], splitUnits = "bad")
  test "diagnostics accessor returns a defensive copy":
    let r = generateStructuredAppend(repeat('A', 80), Options(version: 1, maskPattern: 0))
    var copied = diagnostics(r)
    copied["total"] = %99
    check r.diagnostics["total"].getInt == r.total

suite "Structured Append decoded merge":
  test "text merges by one-based index and checks original UTF-8 parity":
    let parity = calculateStructuredAppendParity("ab漢🙂")
    let parts = %* [{"index": 2, "total": 2, "parity": parity, "data": "漢🙂"},
                   {"index": 1, "total": 2, "parity": parity, "data": "ab"}]
    let r = mergeStructuredAppendParts(parts)
    check r.data.getStr == "ab漢🙂"
    check r.total == 2
    check r.parity == parity
    check r.parts[0]["index"].getInt == 1
    check r.diagnostics["byte_length"].getInt == 9
    check r.diagnostics["parity_check"]["matches"].getBool
    var copy = diagnostics(r)
    copy["parity_check"]["matches"] = %false
    check r.diagnostics["parity_check"]["matches"].getBool
  test "binary merge preserves bytes and permits empty decoded parts":
    let r = mergeStructuredAppendParts( %* [{"index": 3, "total": 3, "parity": 254, "data": [255, 1]},
      {"index": 1, "total": 3, "parity": 254, "data": [0]},
      {"index": 2, "total": 3, "parity": 254, "data": []}])
    check r.data == %* [0, 255, 1]
    check r.diagnostics["data_type"].getStr == "binary"
    check r.diagnostics["byte_length"].getInt == 3
  test "complete set constraints duplicate mixed mismatch and invalid byte failures":
    for bad in [
      %* [],
      %* [{"index": 1, "total": 2, "parity": 0, "data": "x"}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": "x"}, {"index": 1, "total": 2, "parity": 0,
          "data": "x"}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": "x"}, {"index": 2, "total": 2, "parity": 0,
          "data": [120]}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": "x"}, {"index": 2, "total": 2, "parity": 1,
          "data": "x"}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": "x"}, {"index": 2, "total": 3, "parity": 0,
          "data": "x"}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": [256]}, {"index": 2, "total": 2,
          "parity": 0, "data": []}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": [true]}, {"index": 2, "total": 2,
          "parity": 0, "data": []}],
      %* [{"index": 0, "total": 2, "parity": 0, "data": "x"}, {"index": 2, "total": 2, "parity": 0,
          "data": "x"}],
      %* [{"index": 1.0, "total": 2, "parity": 0, "data": "x"}, {"index": 2, "total": 2,
          "parity": 0, "data": "x"}],
      %* [{"index": 1, "total": 2, "parity": 0, "data": "x"}, {"index": 2, "total": 2, "parity": 0, "data": "y"}]
    ]:
      expectCode("INVALID_INPUT"): discard mergeStructuredAppendParts(bad)
  test "merged resource budget is aggregate across all parts":
    let text = repeat('a', MaxPayloadUnits div 2 + 1)
    expectCode("DATA_TOO_LONG"):
      discard mergeStructuredAppendParts( %* [{"index": 1, "total": 2, "parity": 0, "data": text},
        {"index": 2, "total": 2, "parity": 0, "data": text}])
