## Deterministic 2..16-symbol Structured Append and decoded-set merging.
## Text boundaries are Unicode scalars. Parity is XOR of original UTF-8/raw bytes.
import std/[json, options, strutils, unicode]
import ./[api, segments, optimizer, tables, errors]

type
  SAResult* = object
    symbols*: seq[QRResult]
    total*, parity*, inputLength*, byteLength*: int
    diagnostics*: JsonNode
  MergeResult* = object
    data*: JsonNode ## JString for text or JArray of integer bytes for binary.
    total*, parity*: int
    parts*: JsonNode
    diagnostics*: JsonNode
  SADescriptor = object
    segment: Segment
    sourceIndex, splitStart, splitCount, byteStart, byteLength: int
    offsets: seq[int]
  SASource = object
    data: string
    characters: seq[Rune]
    offsets: seq[int]
    binary, manual: bool
    segments: seq[Segment]
    descriptors: seq[SADescriptor]
    length, inputLength, byteLength, parity: int
  SARange = tuple[start, length: int]
  SARangePiece = tuple[descriptor: int, start, length: int]
  SAStatus = enum saSingle, saTooLong, saOk

proc xorBytes(value: string): int =
  for c in value: result = result xor ord(c)
proc calculateStructuredAppendParity*(input: string): int =
  discard strictUtf8(input)
  xorBytes(input)
proc calculateStructuredAppendParity*(input: openArray[uint8]): int =
  if input.len > MaxPayloadUnits: fail("DATA_TOO_LONG", "Payload exceeds the resource limit")
  for b in input: result = result xor int(b)
proc manualSegments(values: openArray[Segment]; unitBudget = MaxPayloadUnits): seq[Segment] =
  if values.len == 0: fail("INVALID_INPUT", "Structured Append needs nonempty manual segments")
  if values.len > MaxManualSegments: fail("DATA_TOO_LONG", "Too many manual segments")
  result = normalizeSegments(values)
  var units = 0
  for s in result:
    if s.mode == "fnc1": fail("INVALID_GS1", "Structured Append cannot be combined with FNC1")
    if s.isControl: fail("INVALID_MODE", "Structured Append cannot include manual control segments")
    let n = if s.isBinary: s.text.len else: s.characterCount
    if n == 0: fail("INVALID_INPUT", "Structured Append requires nonempty data segments")
    if n > min(MaxPayloadUnits, unitBudget) - units:
      fail("DATA_TOO_LONG", "Manual payload exceeds Structured Append capacity")
    units += n
proc calculateStructuredAppendSegmentsParity*(segments: openArray[Segment]): int =
  for s in manualSegments(segments): result = result xor xorBytes(s.text)
proc capacity(o: Options; version: int): int = 8 * dataCodewordCount(version,
    o.errorCorrectionLevel)
proc capacityVersion(o: Options): int =
  if o.version == 0: o.maxVersion else: o.version
proc unitBudget(o: Options; maximum: int): int =
  maximum * (max(0, capacity(o, capacityVersion(o)) - 20) * 3 div 10)
proc checkOptions(o: Options; maximum: int; manual: bool; detail, symbolResults: string) =
  discard requireRange(maximum, 2, 16, "maxSymbols", "INVALID_MODE")
  if detail notin ["summary", "full"] or symbolResults notin ["output", "diagnostics"]:
    fail("INVALID_INPUT", "Invalid Structured Append diagnostic detail")
  o.validateOptions()
  if o.gs1: fail("INVALID_GS1", "Structured Append cannot be combined with gs1")
  if o.fnc1 or o.eciAssignment >= 0 or o.fnc1Second != "" or o.structuredAppend.isSome:
    fail("INVALID_MODE", "Structured Append owns its header and cannot include other controls")
  if o.boostErrorCorrection: fail("INVALID_MODE", "Structured Append does not support ECC boosting")
  if manual and (o.mode != "auto" or not o.optimizeSegments):
    fail("INVALID_MODE", "Manual Structured Append preserves caller modes")
proc numericBits(n: int): int = n div 3 * 10 + [0, 4, 7][n mod 3]
proc payloadBits(mode: string; n, nb: int): int =
  case mode
  of "numeric": numericBits(n)
  of "alphanumeric": n div 2 * 11 + n mod 2 * 6
  of "kanji": n * 13
  else: nb * 8
proc segmentBits(mode: string; n, nb, version: int): int =
  let width = characterCountBits(version, mode)
  let count = if mode == "byte": nb else: n
  if count >= (1 shl width): return high(int) div 4
  4 + width + payloadBits(mode, n, nb)
proc offsets(text: string): seq[int] =
  result.add 0
  var pos = 0
  for c in text.runes:
    pos += c.toUTF8.len
    result.add pos
proc inputSource(value: string; o: Options; maximum: int): SASource =
  result.characters = strictUtf8(value)
  let n = result.characters.len
  if n == 0: fail("INVALID_INPUT", "Structured Append needs at least two nonempty symbols")
  if n > unitBudget(o, maximum): fail("DATA_TOO_LONG", "Input exceeds Structured Append capacity")
  if o.mode != "auto": discard newSegment(o.mode, value)
  result.data = value
  result.offsets = offsets(value)
  result.length = n
  result.inputLength = n
  result.byteLength = value.len
  result.parity = xorBytes(value)
  let version = capacityVersion(o)
  var width = high(int)
  if o.mode == "auto":
    for mode in DataModes: width = min(width, characterCountBits(version, mode))
  else: width = characterCountBits(version, o.mode)
  let required = if o.mode == "auto": numericBits(n) else: payloadBits(o.mode, n, value.len)
  if required > maximum * max(0, capacity(o, version) - 24 - width):
    fail("DATA_TOO_LONG", "Input exceeds Structured Append capacity")
proc inputSource(value: openArray[uint8]; o: Options; maximum: int): SASource =
  if value.len == 0: fail("INVALID_INPUT", "Structured Append needs at least two nonempty symbols")
  if value.len > MaxPayloadUnits or value.len > unitBudget(o, maximum):
    fail("DATA_TOO_LONG", "Input exceeds Structured Append capacity")
  if o.mode notin ["auto", "byte"]: fail("INVALID_MODE", "Binary input requires byte mode")
  let version = capacityVersion(o)
  if value.len * 8 > maximum * max(0, capacity(o, version) - 24 - characterCountBits(version, "byte")):
    fail("DATA_TOO_LONG", "Input exceeds Structured Append capacity")
  result.binary = true
  result.data = newString(value.len)
  for i, b in value:
    result.data[i] = char(b)
    result.parity = result.parity xor int(b)
  result.length = value.len
  result.inputLength = value.len
  result.byteLength = value.len
proc segmentSource(values: openArray[Segment]; o: Options; maximum: int): SASource =
  result.manual = true
  result.segments = manualSegments(values, unitBudget(o, maximum))
  result.inputLength = result.segments.len
  let version = capacityVersion(o)
  var totalBits = 0
  for i, s in result.segments:
    let n = if s.isBinary: s.text.len else: s.characterCount
    let size = s.text.len
    let split = if s.mode == "byte": n else: 1
    var d = SADescriptor(segment: s, sourceIndex: i, splitStart: result.length,
      splitCount: split, byteStart: result.byteLength, byteLength: size)
    if s.mode == "byte" and not s.isBinary: d.offsets = offsets(s.text)
    result.descriptors.add d
    result.length += split
    result.byteLength += size
    result.parity = result.parity xor xorBytes(s.text)
    totalBits += 4 + characterCountBits(version, s.mode) + payloadBits(s.mode, n, size)
  if totalBits > maximum * max(0, capacity(o, version) - 20):
    fail("DATA_TOO_LONG", "Segments exceed Structured Append capacity")
proc textSlice(text: string; offsets: openArray[int]; start, n: int): string =
  if n == 0: "" else: text[offsets[start]..<offsets[start + n]]
proc inputSlice(s: SASource; start, n: int): string =
  if s.binary: s.data[start..<start + n] else: textSlice(s.data, s.offsets, start, n)
proc inputByteLength(s: SASource; start, n: int): int =
  if s.binary: n else: s.offsets[start + n] - s.offsets[start]
proc ranges(s: SASource; start, n: int): seq[SARangePiece] =
  let finish = start + n
  var low = 0
  var high = s.descriptors.len
  while low < high:
    let mid = low + (high - low) div 2
    let d = s.descriptors[mid]
    if d.splitStart + d.splitCount <= start: low = mid + 1
    else: high = mid
  var i = low
  while i < s.descriptors.len:
    let d = s.descriptors[i]
    if d.splitStart >= finish: break
    let overlap = max(start, d.splitStart)
    result.add (i, overlap - d.splitStart, min(finish, d.splitStart + d.splitCount) - overlap)
    inc i
proc rangeBytes(d: SADescriptor; start, n: int): tuple[start, length: int] =
  if d.segment.mode != "byte": (d.byteStart, d.byteLength)
  elif not d.segment.isBinary: (d.byteStart + d.offsets[start], d.offsets[start + n] - d.offsets[start])
  else: (d.byteStart + start, n)
proc sourceBits(s: SASource; start, n: int; o: Options; version: int): int =
  let cap = capacity(o, version)
  if s.manual:
    result = 20
    for piece in ranges(s, start, n):
      let d = s.descriptors[piece.descriptor]
      let nb = rangeBytes(d, piece.start, piece.length).length
      let len = if d.segment.mode == "byte": piece.length else: d.segment.characterCount
      result += segmentBits(d.segment.mode, len, nb, version)
      if result > cap: break
  else:
    if numericBits(n) > cap - 20: return high(int) div 4
    if s.binary: return 20 + segmentBits("byte", n, n, version)
    if o.mode != "auto": return 20 + segmentBits(o.mode, n, inputByteLength(s, start, n), version)
    if o.optimizeSegments:
      var tracker = newSegmentOptimizationTracker(version, o.allowKanji)
      var required = 0
      for i in start..<start + n:
        required = tracker.appendCharacter(s.characters[i])
        if required + 20 > cap: break
      return required + 20
    let data = createSegments(inputSlice(s, start, n), mode = "auto", version = version,
                              optimize = false, allowKanji = o.allowKanji)
    for seg in data:
      if seg.count >= (1 shl characterCountBits(version, seg.mode)): return high(int) div 4
    return 20 + segmentsBitLength(data, version)
proc largestPrefix(s: SASource; start, maximum: int; o: Options; version: int): int =
  if not s.manual and not s.binary and o.mode == "auto" and o.optimizeSegments:
    var tracker = newSegmentOptimizationTracker(version, o.allowKanji)
    let cap = capacity(o, version) - 20
    for i in 1..maximum:
      if tracker.appendCharacter(s.characters[start + i - 1]) > cap: return i - 1
    return maximum
  var low = 1
  var high = maximum
  let cap = capacity(o, version)
  while low <= high:
    let n = low + (high - low) div 2
    if sourceBits(s, start, n, o, version) <= cap:
      result = n
      low = n + 1
    else: high = n - 1
proc attempt(s: SASource; o: Options; version, maximum: int): tuple[status: SAStatus, ranges: seq[SARange]] =
  if sourceBits(s, 0, s.length, o, version) <= capacity(o, version):
    return (saSingle, @[])
  var start = 0
  while start < s.length:
    if result.ranges.len == maximum: return (saTooLong, @[])
    let possible = s.length - start - (if result.ranges.len == 0: 1 else: 0)
    let n = largestPrefix(s, start, possible, o, version)
    if n <= 0: return (saTooLong, @[])
    result.ranges.add (start, n)
    start += n
  result.status = if result.ranges.len >= 2: saOk else: saSingle
proc select(s: SASource; o: Options; maximum: int): tuple[version: int, ranges: seq[SARange],
    selection: string] =
  let lo = if o.version == 0: o.minVersion else: o.version
  let hi = if o.version == 0: o.maxVersion else: o.version
  var tooLong = false
  for version in lo..hi:
    let trial = attempt(s, o, version, maximum)
    if trial.status == saOk:
      return (version, trial.ranges, (if o.version == 0: "auto-minimum" else: "fixed"))
    tooLong = tooLong or trial.status == saTooLong
  if tooLong: fail("DATA_TOO_LONG", "Input cannot be split into " & $maximum & " or fewer symbols in the selected version range")
  fail("INVALID_INPUT", "Input fits in one symbol; use generate or a low-level Structured Append header")
proc inputChunk(s: SASource; start, n: int): tuple[data: string, offsets: JsonNode] =
  result.data = inputSlice(s, start, n)
  result.offsets = %* {"input_start": start, "input_length": n,
    "byte_start": (if s.binary: start else: s.offsets[start]), "byte_length": inputByteLength(s,
        start, n)}
proc segmentChunk(s: SASource; start, n: int): tuple[segments: seq[Segment], offsets: JsonNode] =
  var firstIndex = -1
  var lastIndex = 0
  var byteStart = 0
  var byteLength = 0
  for piece in ranges(s, start, n):
    let d = s.descriptors[piece.descriptor]
    let b = rangeBytes(d, piece.start, piece.length)
    if firstIndex < 0:
      firstIndex = d.sourceIndex
      byteStart = b.start
    lastIndex = d.sourceIndex + 1
    byteLength += b.length
    if d.segment.mode == "byte":
      if d.segment.isBinary:
        var data = newSeq[uint8](piece.length)
        for i in 0..<piece.length: data[i] = uint8(d.segment.text[piece.start + i])
        result.segments.add byteSegment(data)
      else: result.segments.add byteSegment(textSlice(d.segment.text, d.offsets, piece.start, piece.length))
    else: result.segments.add d.segment
  result.offsets = %* {"source_segment_start": firstIndex, "source_segment_end": lastIndex,
    "split_unit_start": start, "split_unit_length": n, "byte_start": byteStart,
    "byte_length": byteLength}
proc fullDetail(s: SASource): JsonNode =
  result = newJArray()
  for d in s.descriptors:
    for unit in 0..<d.splitCount:
      let bytes = rangeBytes(d, unit, 1)
      result.add( %* {"source_segment_index": d.sourceIndex, "mode": d.segment.mode,
        "unit_start": (if d.segment.mode == "byte": unit else: 0),
        "unit_length": (if d.segment.mode == "byte": 1 else: d.segment.characterCount),
        "byte_start": bytes.start, "byte_length": bytes.length})
proc generateSource(s: SASource; o: Options; maximum: int; detail,
    symbolResults: string): SAResult =
  let selected = select(s, o, maximum)
  let version = selected.version
  result.total = selected.ranges.len
  result.parity = s.parity
  result.inputLength = s.inputLength
  result.byteLength = s.byteLength
  var detailSymbols = newJArray()
  for i, r in selected.ranges:
    var chosen = o
    chosen.version = version
    chosen.minVersion = version
    chosen.maxVersion = version
    chosen.structuredAppend = some(structuredAppendSegment(i + 1, result.total, s.parity))
    var symbol: QRResult
    var offsets: JsonNode
    if s.manual:
      let chunk = segmentChunk(s, r.start, r.length)
      symbol = generateSegments(chunk.segments, chosen)
      offsets = chunk.offsets
    else:
      let chunk = inputChunk(s, r.start, r.length)
      if s.binary:
        var data = newSeq[uint8](chunk.data.len)
        for j, c in chunk.data: data[j] = uint8(c)
        symbol = generate(data, chosen)
      else: symbol = generate(chunk.data, chosen)
      offsets = chunk.offsets
    result.symbols.add symbol
    let required = symbol.diagnostics["data_bit_length"].getInt
    var d = %* {"index": i + 1, "total": result.total, "parity": s.parity,
      "sequence_index": i, "sequence_total": result.total - 1,
      "sequence_indicator": ((i shl 4) or (result.total - 1)), "version": version,
      "error_correction_level": symbol.errorCorrectionLevel, "data_bit_length": required,
      "capacity_bits": capacity(o, version), "remaining_bits": capacity(o, version) - required,
      "mask_pattern": symbol.maskPattern}
    for key, value in offsets: d[key] = value
    detailSymbols.add d
  var warnings = newJArray()
  if result.total == maximum:
    warnings.add( %* {"code": "STRUCTURED_APPEND_MAX_SYMBOLS_NEAR_LIMIT", "severity": "info",
      "message": "The set uses the configured maximum number of symbols.",
      "details": {"total": result.total, "max_symbols": maximum}})
  if symbolResults == "diagnostics":
    warnings.add( %* {"code": "STRUCTURED_APPEND_DECODER_SUPPORT_VARIES", "severity": "info",
      "message": "Decoder APIs vary in how they expose Structured Append metadata.", "details": {
          "total": result.total}})
  let reason = if selected.selection == "fixed": "Version " & $version & " was requested explicitly."
               else: "Version " & $version & " is the smallest version in " & $o.minVersion & ".." &
                   $o.maxVersion & " that can split the payload into " & $result.total & " symbols."
  result.diagnostics = %* {"version": version, "error_correction_level": o.errorCorrectionLevel,
    "version_selection": selected.selection, "version_selection_reason": reason,
    "total": result.total,
    "parity": s.parity, "byte_length": s.byteLength, "input_length": s.inputLength,
    "max_symbols": maximum, "split_strategy": (if s.manual: "segment-boundary-byte-chunk" else: "greedy-largest-fitting"),
    "symbols": detailSymbols, "warnings": warnings}
  if s.manual:
    result.diagnostics["segment_count"] = %s.segments.len
    result.diagnostics["split_unit_count"] = %s.length
    result.diagnostics["split_units_detail"] = %detail
    if detail == "full": result.diagnostics["split_units"] = fullDetail(s)
proc generateStructuredAppend*(input: string; options = Options(); maxSymbols = 16;
    diagnostics = false): SAResult =
  let results = if diagnostics: "diagnostics" else: "output"
  checkOptions(options, maxSymbols, false, "summary", results)
  generateSource(inputSource(input, options, maxSymbols), options, maxSymbols, "summary", results)
proc generateStructuredAppend*(input: openArray[uint8]; options = Options(); maxSymbols = 16;
    diagnostics = false): SAResult =
  let results = if diagnostics: "diagnostics" else: "output"
  checkOptions(options, maxSymbols, false, "summary", results)
  generateSource(inputSource(input, options, maxSymbols), options, maxSymbols, "summary", results)
proc generateSegmentsStructuredAppend*(segments: openArray[Segment]; options = Options(); maxSymbols = 16;
                                       diagnostics = false; splitUnits = "summary";
                                           symbolResults = ""): SAResult =
  let results = if symbolResults.len > 0: symbolResults elif diagnostics: "diagnostics" else: "output"
  checkOptions(options, maxSymbols, true, splitUnits, results)
  generateSource(segmentSource(segments, options, maxSymbols), options, maxSymbols, splitUnits, results)
proc generateStructuredAppend*(segments: openArray[Segment]; options = Options(); maxSymbols = 16;
    diagnostics = false): SAResult =
  generateSegmentsStructuredAppend(segments, options, maxSymbols, diagnostics)
proc diagnostics*(r: SAResult): JsonNode =
  if r.diagnostics.isNil: fail("INVALID_INPUT", "Uninitialized diagnostics result")
  copyJsonChecked(r.diagnostics)
proc diagnostics*(r: MergeResult): JsonNode =
  if r.diagnostics.isNil: fail("INVALID_INPUT", "Uninitialized diagnostics result")
  copyJsonChecked(r.diagnostics)

proc fieldInt(part: JsonNode; key: string; low, high: int): int =
  if part.isNil or part.kind != JObject or not part.hasKey(key) or part[key].isNil or part[
      key].kind != JInt:
    fail("INVALID_INPUT", key & " must be an integer")
  let n = part[key].getBiggestInt
  if n < BiggestInt(low) or n > BiggestInt(high): fail("INVALID_INPUT", key & " is outside its supported range")
  int(n)
proc mergeStructuredAppendParts*(parts: JsonNode): MergeResult =
  if parts.isNil or parts.kind != JArray or parts.len notin 1..16:
    fail("INVALID_INPUT", "parts must contain 1..16 decoded mappings")
  var ordered: array[16, JsonNode]
  var summaries: array[16, JsonNode]
  var total = -1
  var parity = -1
  var kind = ""
  var nb, actual, units: int
  for part in parts:
    if part.isNil or part.kind != JObject: fail("INVALID_INPUT", "Part must be a decoded mapping")
    let index = fieldInt(part, "index", 1, 16)
    let t = fieldInt(part, "total", 2, 16)
    let p = fieldInt(part, "parity", 0, 255)
    if index > t: fail("INVALID_INPUT", "Index exceeds total")
    if total >= 0 and t != total: fail("INVALID_INPUT", "Structured Append total mismatch")
    if parity >= 0 and p != parity: fail("INVALID_INPUT", "Structured Append parity mismatch")
    if not ordered[index - 1].isNil: fail("INVALID_INPUT", "Duplicate Structured Append index " & $index)
    if not part.hasKey("data") or part["data"].isNil or part["data"].kind notin {JString, JArray}:
      fail("INVALID_INPUT", "Part data must be text or bytes")
    let data = part["data"]
    var typ: string
    var size, checksum, n: int
    if data.kind == JString:
      typ = "string"
      let text = data.getStr
      n = strictUtf8(text).len
      size = text.len
      checksum = xorBytes(text)
    else:
      typ = "binary"
      n = data.len
      if n > MaxPayloadUnits: fail("DATA_TOO_LONG", "Merged input exceeds the resource limit")
      for b in data:
        if b.isNil or b.kind != JInt or b.getBiggestInt < 0 or b.getBiggestInt > 255:
          fail("INVALID_INPUT", "Binary values must be integers from 0 to 255")
        checksum = checksum xor b.getInt
      size = n
    if n > MaxPayloadUnits - units: fail("DATA_TOO_LONG", "Merged input exceeds the resource limit")
    units += n
    if kind.len > 0 and kind != typ: fail("INVALID_INPUT", "Parts must not mix text and binary data")
    total = t
    parity = p
    kind = typ
    nb += size
    actual = actual xor checksum
    ordered[index - 1] = data.copy()
    summaries[index - 1] = %* {"index": index, "total": total, "parity": parity,
      "data_type": kind, "byte_length": size}
  var missing: seq[string]
  for i in 0..<total:
    if ordered[i].isNil: missing.add $(i + 1)
  if missing.len > 0: fail("INVALID_INPUT", "Missing Structured Append indexes: " & missing.join(", "))
  if parts.len != total: fail("INVALID_INPUT", "Part count does not match total")
  if actual != parity: fail("INVALID_INPUT", "Structured Append parity check failed")
  result.total = total
  result.parity = parity
  result.parts = newJArray()
  if kind == "string":
    var joined = newStringOfCap(nb)
    for i in 0..<total: joined.add ordered[i].getStr
    result.data = %joined
  else:
    result.data = newJArray()
    for i in 0..<total:
      for b in ordered[i]: result.data.add b.copy()
  for i in 0..<total: result.parts.add summaries[i]
  result.diagnostics = %* {"part_count": total, "total": total, "parity": parity,
    "data_type": kind, "byte_length": nb, "missing": [], "duplicate": [],
    "parity_check": {"expected": parity, "actual": actual, "matches": true}}
