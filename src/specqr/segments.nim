## Owned native segments. Text is strict UTF-8; byte sequences are opaque.
import std/[unicode, strutils]
import ./[errors, tables, kanji_data]
const
  AlphanumericCharset* = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
  DataModes* = ["numeric", "alphanumeric", "kanji", "byte"]
  ControlModes* = ["eci", "fnc1", "fnc1-second", "structured-append"]
  MaxPayloadUnits* = 1_000_000
  MaxManualSegments* = 16_384
  MaxSingleSymbolCharacters* = 7089
  MaxSingleSymbolDataBits* = 23648

type Segment* = object
  m, payload, application: string
  binary: bool
  characters, assignment, saIndex, saTotal, saParity: int

proc strictUtf8*(text: string): seq[Rune] =
  if text.len > 4*MaxPayloadUnits: fail("DATA_TOO_LONG", "Text resource limit exceeded")
  if validateUtf8(text) >= 0: fail("INVALID_INPUT", "Text must be well-formed UTF-8")
  var canonical = ""
  for c in text.runes:
    canonical.add(c.toUTF8)
    if int(c) > 0x10ffff or int(c) in 0xd800..0xdfff: fail("INVALID_INPUT", "Text must contain Unicode scalars")
    result.add(c)
    if result.len > MaxPayloadUnits: fail("DATA_TOO_LONG", "Text resource limit exceeded")
  if canonical != text: fail("INVALID_INPUT", "UTF-8 must use shortest-form scalar encoding")
proc kanjiCode*(r: Rune): int =
  let c = int(r)
  if c < 128 or c > 65535: return -1
  var lo = 0; var hi = KanjiKeys.high
  while lo <= hi:
    let mid = lo+(hi-lo) div 2
    if KanjiKeys[mid] < c: lo = mid+1
    elif KanjiKeys[mid] > c: hi = mid-1
    else: return KanjiCodes[mid]
  -1
proc canEncodeKanji*(r: Rune): bool = kanjiCode(r) >= 0
proc kanjiValue*(r: Rune): int =
  let code = kanjiCode(r)
  if code < 0: fail("INVALID_MODE", "Character is not QR Kanji encodable")
  let adjusted = code-(if code <= 0x9ffc: 0x8140 else: 0xc140)
  (adjusted shr 8)*0xc0+(adjusted and 0xff)
proc alphaValue*(r: Rune): int =
  if int(r) > 127: return -1
  AlphanumericCharset.find(char(int(r)))
proc mode*(s: Segment): string = s.m
proc isControl*(s: Segment): bool = s.m in ControlModes
proc isBinary*(s: Segment): bool = s.binary
proc text*(s: Segment): string = s.payload
proc logicalBytes*(s: Segment): seq[uint8] =
  for c in s.payload: result.add(uint8(c))
proc count*(s: Segment): int =
  if s.isControl: 0 elif s.m == "byte": s.payload.len else: s.characters
proc characterCount*(s: Segment): int = s.characters
proc byteCount*(s: Segment): int =
  if s.m == "kanji": s.count*2 else: s.payload.len
proc assignmentNumber*(s: Segment): int = s.assignment
proc applicationIndicator*(s: Segment): string = s.application
proc index*(s: Segment): int = s.saIndex
proc total*(s: Segment): int = s.saTotal
proc parity*(s: Segment): int = s.saParity
proc applicationIndicatorCodeword*(s: Segment): int =
  if s.m != "fnc1-second": return -1
  if s.application.len == 2: parseInt(s.application) else: ord(s.application[0])+100
proc newSegment*(mode, data: string): Segment =
  if mode notin DataModes: fail("INVALID_MODE", "Expected a data mode")
  let scalars = strictUtf8(data)
  for c in scalars:
    if mode == "numeric" and int(c) notin ord('0')..ord('9'): fail("INVALID_MODE", "Numeric data must contain digits")
    if mode == "alphanumeric" and alphaValue(c) < 0: fail("INVALID_MODE", "Invalid alphanumeric character")
    if mode == "kanji" and not canEncodeKanji(c): fail("INVALID_MODE", "Invalid Kanji character")
  Segment(m: mode, payload: data, characters: scalars.len, assignment: -1, saIndex: -1, saTotal: -1, saParity: -1)
proc byteSegment*(data: openArray[uint8]): Segment =
  if data.len > MaxPayloadUnits: fail("DATA_TOO_LONG", "Payload resource limit exceeded")
  var owned = newString(data.len)
  for i, b in data: owned[i] = char(b)
  Segment(m: "byte", payload: owned, binary: true, assignment: -1, saIndex: -1, saTotal: -1, saParity: -1)
proc byteSegment*(text: string): Segment = newSegment("byte", text)
proc numeric*(text: string): Segment = newSegment("numeric", text)
proc alphanumeric*(text: string): Segment = newSegment("alphanumeric", text)
proc kanji*(text: string): Segment = newSegment("kanji", text)
proc eci*(assignmentNumber: int): Segment =
  discard requireRange(assignmentNumber, 0, 999999, "ECI assignment", "INVALID_ECI")
  Segment(m: "eci", assignment: assignmentNumber)
proc fnc1*(): Segment = Segment(m: "fnc1")
proc fnc1Second*(applicationIndicator: string): Segment =
  let v = applicationIndicator
  if not ((v.len == 2 and v[0] in '0'..'9' and v[1] in '0'..'9') or (v.len == 1 and (v[0] in
      'A'..'Z' or v[0] in 'a'..'z'))):
    fail("INVALID_MODE", "FNC1 second indicator must be two ASCII digits or one Latin letter")
  Segment(m: "fnc1-second", application: v)
proc structuredAppendSegment*(index, total, parity: int): Segment =
  discard requireRange(index, 1, 16, "SA index", "INVALID_MODE")
  discard requireRange(total, 2, 16, "SA total", "INVALID_MODE")
  discard requireRange(parity, 0, 255, "SA parity", "INVALID_MODE")
  if index > total: fail("INVALID_MODE", "SA index must not exceed total")
  Segment(m: "structured-append", saIndex: index, saTotal: total, saParity: parity)
proc validateSegment*(s: Segment) =
  if s.m notin DataModes and s.m notin ControlModes: fail("INVALID_MODE", "Uninitialized segment")
proc bitLength*(s: Segment; version: int): int =
  validateVersion(version); s.validateSegment()
  case s.m
  of "eci": return if s.assignment < 128: 12 elif s.assignment < 16384: 20 else: 28
  of "fnc1": return 4
  of "fnc1-second": return 12
  of "structured-append": return 20
  else: discard
  let n = s.count
  let payload = case s.m
    of "numeric": n div 3*10+[0, 4, 7][n mod 3]
    of "alphanumeric": n div 2*11+n mod 2*6
    of "kanji": n*13
    else: n*8
  4+characterCountBits(version, s.m)+payload
proc appendBits(dest: var seq[int]; value, width: int) =
  for shift in countdown(width-1, 0): dest.add((value shr shift) and 1)
proc bits*(s: Segment; version: int): seq[int] =
  let nbits = s.bitLength(version)
  if not s.isControl and s.count >= (1 shl characterCountBits(version, s.m)): fail("DATA_TOO_LONG", "Segment count does not fit")
  if nbits > MaxSingleSymbolDataBits: fail("DATA_TOO_LONG", "Segment exceeds single-symbol capacity")
  let indicator = case s.m
    of "numeric": 1
    of "alphanumeric": 2
    of "byte": 4
    of "kanji": 8
    of "eci": 7
    of "fnc1": 5
    of "fnc1-second": 9
    else: 3
  result.appendBits(indicator, 4)
  case s.m
  of "eci":
    if s.assignment < 128: result.appendBits(s.assignment, 8)
    elif s.assignment < 16384: result.appendBits(2, 2); result.appendBits(s.assignment, 14)
    else: result.appendBits(6, 3); result.appendBits(s.assignment, 21)
  of "fnc1-second": result.appendBits(s.applicationIndicatorCodeword, 8)
  of "structured-append":
    result.appendBits(s.saIndex-1, 4); result.appendBits(s.saTotal-1, 4); result.appendBits(
        s.saParity, 8)
  of "fnc1": discard
  else:
    result.appendBits(s.count, characterCountBits(version, s.m))
    case s.m
    of "byte":
      for c in s.payload: result.appendBits(ord(c), 8)
    of "numeric":
      var i = 0
      while i < s.payload.len:
        let n = min(3, s.payload.len-i)
        var value = 0
        for j in i..<i+n: value = value*10+ord(s.payload[j])-ord('0')
        result.appendBits(value, [4, 7, 10][n-1]); i+=n
    of "alphanumeric":
      var i = 0
      while i+1 < s.payload.len:
        result.appendBits(AlphanumericCharset.find(s.payload[i])*45+AlphanumericCharset.find(
            s.payload[i+1]), 11); i+=2
      if i < s.payload.len: result.appendBits(AlphanumericCharset.find(s.payload[i]), 6)
    else:
      for c in s.payload.runes: result.appendBits(kanjiValue(c), 13)
  if result.len != nbits: fail("INVALID_INPUT", "Inconsistent segment length")
proc normalizeSegments*(segments: openArray[Segment]): seq[Segment] =
  if segments.len > MaxManualSegments: fail("DATA_TOO_LONG", "Manual segment resource limit exceeded")
  var units = 0; var controls: array[4, int]
  for i, s in segments:
    s.validateSegment()
    units += (if s.binary: s.payload.len else: s.characters)
    if units > MaxPayloadUnits: fail("DATA_TOO_LONG", "Manual payload resource limit exceeded")
    for j, m in ControlModes:
      if s.m == m:
        inc controls[j]
        if m != "eci" and (controls[j] > 1 or i != 0): fail(if m ==
            "fnc1": "INVALID_GS1" else: "INVALID_MODE", "Control must be first and unique")
    result.add(s)
  var families = 0
  for n in controls:
    if n > 0: inc families
  if families > 1: fail(if controls[1] > 0: "INVALID_GS1" else: "INVALID_MODE", "FNC1, ECI, and SA cannot be combined")
proc segmentsBitLength*(segments: openArray[Segment]; version: int): int =
  validateVersion(version)
  let clean = normalizeSegments(segments)
  for s in clean: result+=s.bitLength(version)
proc segmentsBits*(segments: openArray[Segment]; version: int): seq[int] =
  let clean = normalizeSegments(segments)
  if segmentsBitLength(clean, version) > MaxSingleSymbolDataBits: fail("DATA_TOO_LONG", "Segments exceed single-symbol capacity")
  for s in clean: result.add(s.bits(version))
