## Bounded GS1 application identifiers and offline GS1 Digital Link utilities.
## This module intentionally implements the documented 50-AI SpecQR catalog.
import std/[algorithm, json, options, sets, strutils, unicode]
import ./errors

const
  GS1_FNC1_SEPARATOR* = "\x1d"
  GS1_MAX_INPUT_CHARACTERS* = 1_000_000
  GS1_MAX_ELEMENTS* = 16_384
  primaryAis = ["00", "01", "414"]

type
  GS1Element* = object
    ai*, value*: string
  GS1AiLength* = object
    kind*: string
    exact*, min*, max*: Option[int]
    isVariable*: bool
  GS1AiInfo* = object
    ai*, label*: string
    length*: GS1AiLength
    valueKind*, checkDigitRule*, digitalLinkRole*, separator*: string
    digitalLinkPathForPrimary*: seq[string]
  GS1ElementStringParseResult* = object
    elements*: seq[GS1Element]
    hasSeparators*: bool
  GS1UnknownQuery* = object
    key*, value*: string
  GS1DigitalLinkParseResult* = object
    elements*: seq[GS1Element]
    primary*: GS1Element
    pathElements*, queryElements*: seq[GS1Element]
    unknownQuery*: seq[GS1UnknownQuery]
  GS1Url = object
    scheme, authority, path: string
    query: Option[string]

proc gs1Fail(message: string; code = "GS1_INVALID_INPUT") {.noreturn.} =
  var error = newException(SpecQRError, message)
  error.code = "INVALID_GS1"
  error.detailCode = code
  raise error

proc validScalarUtf8(s: string): bool =
  ## Nim's UTF-8 validator is supplemented with Unicode scalar restrictions.
  if validateUtf8(s) != -1: return false
  var i = 0
  while i < s.len:
    let b = ord(s[i])
    if b <= 0x7f:
      inc i
    elif b in 0xc2..0xdf:
      if i + 1 >= s.len: return false
      i += 2
    elif b in 0xe0..0xef:
      if i + 2 >= s.len: return false
      let b1 = ord(s[i + 1])
      if b == 0xe0 and b1 < 0xa0: return false
      if b == 0xed and b1 >= 0xa0: return false
      i += 3
    elif b in 0xf0..0xf4:
      if i + 3 >= s.len: return false
      let b1 = ord(s[i + 1])
      if b == 0xf0 and b1 < 0x90: return false
      if b == 0xf4 and b1 >= 0x90: return false
      i += 4
    else: return false
  true

proc checkedText(s: string; label = "GS1 text"): string =
  if s.len > 4 * GS1_MAX_INPUT_CHARACTERS or not validScalarUtf8(s):
    gs1Fail(label & " must be valid UTF-8 within the input budget")
  var units = 0
  for rune in s.runes:
    units += (if int(rune) > 0xffff: 2 else: 1)
    if units > GS1_MAX_INPUT_CHARACTERS:
      gs1Fail(label & " exceeds the character work budget")
  s

proc digits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true
proc isAi(s: string): bool = s.len in 2..4 and digits(s)
proc ascii(s: string): bool =
  for c in s:
    if ord(c) > 127: return false
  true
proc eligible(ai, primary: string): bool =
  primary == "01" and ai in ["10", "21", "22"]

proc makeCatalog(): seq[GS1AiInfo] =
  proc add(outp: var seq[GS1AiInfo]; ai, label: string; n: int;
           variable = false; kind = "numeric"; check = "none";
           role = "data-attribute") =
    let len = if variable:
      GS1AiLength(kind: "variable", min: some(1), max: some(n), isVariable: true)
    else:
      GS1AiLength(kind: "fixed", exact: some(n))
    outp.add GS1AiInfo(ai: ai, label: label, length: len, valueKind: kind,
      checkDigitRule: check, digitalLinkRole: role,
      separator: (if variable: "required-when-followed" else: "none"),
      digitalLinkPathForPrimary: (if role == "key-qualifier": @["01"] else: @[]))
  result.add("00", "Serial shipping container code", 18, check = "sscc", role = "primary-key")
  result.add("01", "Global trade item number", 14, check = "gtin", role = "primary-key")
  result.add("02", "Contained trade item GTIN", 14, check = "gtin")
  result.add("10", "Batch or lot number", 20, variable = true, kind = "text", role = "key-qualifier")
  for pair in [("11", "Production date"), ("12", "Due date"), ("13", "Packaging date"),
               ("15", "Best before date"), ("16", "Sell by date"), ("17", "Expiration date")]:
    result.add(pair[0], pair[1], 6)
  result.add("20", "Internal product variant", 2)
  result.add("21", "Serial number", 20, variable = true, kind = "text", role = "key-qualifier")
  result.add("22", "Consumer product variant", 20, variable = true, kind = "text", role = "key-qualifier")
  result.add("30", "Variable count", 8, variable = true)
  result.add("37", "Count of contained trade items", 8, variable = true)
  for pair in [("240", "Additional product identification"), ("241", "Customer part number"),
               ("400", "Customer purchase order number")]:
    result.add(pair[0], pair[1], 30, variable = true, kind = "text")
  for pair in [("410", "Ship to global location number"), ("411", "Bill to global location number"),
               ("412", "Purchased from global location number"), ("413", "Ship for global location number"),
               ("414", "Identification of a physical location"), ("415", "Global location number of the invoicing party")]:
    result.add(pair[0], pair[1], 13, role = (if pair[0] == "414": "primary-key" else: "data-attribute"))
  result.add("420", "Ship to postal code", 20, variable = true, kind = "text")
  for pair in [("422", "Country of origin"), ("424", "Country of processing"),
               ("425", "Country of disassembly"), ("426", "Country covering full process chain")]:
    result.add(pair[0], pair[1], 3)
  for pair in [(3100, "Net weight in kilograms"), (3200, "Net weight in pounds")]:
    for ai in pair[0]..pair[0] + 5: result.add($ai, pair[1], 6)
  for ai in 91..99:
    result.add($ai, "Company internal information", 90, variable = true, kind = "text")

let gs1Catalog = makeCatalog()
proc getSupportedGs1Ais*(): seq[GS1AiInfo] = gs1Catalog
proc getGs1AiInfo*(ai: string): Option[GS1AiInfo] =
  for info in gs1Catalog:
    if info.ai == ai: return some(info)
  none(GS1AiInfo)

proc numeric(value, label: string): string =
  result = checkedText(value, label)
  if not digits(result): gs1Fail(label & " must contain digits only", "GS1_INVALID_CHARSET")
proc calculateGs1CheckDigit*(value: string): string =
  let s = numeric(value, "GS1 check digit input")
  var total = 0
  var weight = 3
  for i in countdown(s.high, 0):
    total = (total + (ord(s[i]) - ord('0')) * weight) mod 10
    weight = 4 - weight
  $((10 - total) mod 10)
proc validateGs1CheckDigit*(value: string): bool =
  let s = numeric(value, "GS1 check digit value")
  if s.len < 2: gs1Fail("GS1 check digit value must include body and check digit", "GS1_INVALID_LENGTH")
  calculateGs1CheckDigit(s[0..<s.high]) == s[^1..^1]
proc calculateGtinCheckDigit*(value: string): string =
  let s = numeric(value, "GTIN body")
  if s.len notin [7, 11, 12, 13]: gs1Fail("GTIN body must be 7, 11, 12, or 13 digits", "GS1_INVALID_LENGTH")
  calculateGs1CheckDigit(s)
proc appendGtinCheckDigit*(value: string): string = value & calculateGtinCheckDigit(value)
proc validateGtinCheckDigit*(value: string): bool =
  let s = numeric(value, "GTIN")
  if s.len notin [8, 12, 13, 14]: gs1Fail("GTIN must be 8, 12, 13, or 14 digits", "GS1_INVALID_LENGTH")
  validateGs1CheckDigit(s)
proc calculateSsccCheckDigit*(value: string): string =
  let s = numeric(value, "SSCC body")
  if s.len != 17: gs1Fail("SSCC body must be exactly 17 digits", "GS1_INVALID_LENGTH")
  calculateGs1CheckDigit(s)
proc appendSsccCheckDigit*(value: string): string = value & calculateSsccCheckDigit(value)
proc validateSsccCheckDigit*(value: string): bool =
  let s = numeric(value, "SSCC")
  if s.len != 18: gs1Fail("SSCC must be exactly 18 digits", "GS1_INVALID_LENGTH")
  validateGs1CheckDigit(s)

proc checkBounded(elements: openArray[GS1Element]) =
  if elements.len > GS1_MAX_ELEMENTS: gs1Fail("GS1 element count exceeds limit")
  var work = 0
  for element in elements:
    for field in [element.ai, element.value]:
      if field.len > GS1_MAX_INPUT_CHARACTERS - work:
        gs1Fail("GS1 aggregate text exceeds input budget")
      work += field.len
proc checkedElement(element: GS1Element; index = 0): GS1Element =
  let ai = checkedText(element.ai, "GS1 element " & $index & " AI")
  let value = checkedText(element.value, "GS1 element " & $index & " value")
  if not isAi(ai): gs1Fail("GS1 element " & $index & " AI must be a 2 to 4 digit string")
  let found = getGs1AiInfo(ai)
  if found.isNone: gs1Fail("Unsupported GS1 AI " & ai, "GS1_UNSUPPORTED_AI")
  let info = found.get
  let prefix = "GS1 AI " & ai & " value"
  if value.len == 0: gs1Fail(prefix & " must not be empty", "GS1_INVALID_LENGTH")
  if '\x1d' in value: gs1Fail(prefix & " must not contain the FNC1 separator", "GS1_UNEXPECTED_SEPARATOR")
  if '(' in value or ')' in value: gs1Fail(prefix & " must be raw data without human-readable parentheses")
  for c in value:
    if c notin {' '..'~'}: gs1Fail(prefix & " must use printable ASCII characters", "GS1_INVALID_CHARSET")
  if info.valueKind == "numeric" and not digits(value):
    gs1Fail(prefix & " must contain digits only", "GS1_INVALID_CHARSET")
  if info.length.isVariable:
    if value.len > info.length.max.get:
      gs1Fail(prefix & " must be at most " & $info.length.max.get & " characters", "GS1_INVALID_LENGTH")
  elif value.len != info.length.exact.get:
    gs1Fail(prefix & " must be exactly " & $info.length.exact.get & " characters", "GS1_INVALID_LENGTH")
  if info.checkDigitRule == "gtin" and not validateGtinCheckDigit(value):
    gs1Fail(prefix & " has an invalid GTIN check digit", "GS1_INVALID_CHECK_DIGIT")
  if info.checkDigitRule == "sscc" and not validateSsccCheckDigit(value):
    gs1Fail(prefix & " has an invalid SSCC check digit", "GS1_INVALID_CHECK_DIGIT")
  GS1Element(ai: ai, value: value)
proc normalizeGs1Elements*(elements: openArray[GS1Element]): seq[GS1Element] =
  checkBounded(elements)
  if elements.len == 0: gs1Fail("GS1 elements must not be empty")
  for index, e in elements: result.add checkedElement(e, index)
proc normalizeGs1Elements*(parsed: GS1ElementStringParseResult): seq[GS1Element] =
  normalizeGs1Elements(parsed.elements)
proc asciiInput(value, label: string): string =
  result = checkedText(value, label)
  if not ascii(result): gs1Fail(label & " must use ASCII characters", "GS1_INVALID_CHARSET")
  if result.len == 0: gs1Fail(label & " must not be empty")
proc pushElement(elements: var seq[GS1Element]; element: GS1Element) =
  if elements.len >= GS1_MAX_ELEMENTS: gs1Fail("GS1 element count exceeds limit")
  elements.add element
proc parseGs1HumanReadable*(value: string): seq[GS1Element] =
  let s = asciiInput(value, "GS1 human-readable input")
  var p = 0
  while p < s.len:
    if s[p] != '(': gs1Fail("GS1 AI must be parenthesized at offset " & $p)
    let q = s.find(')', p + 1)
    if q < 0: gs1Fail("GS1 AI is missing closing parenthesis at offset " & $p)
    var stop = s.find('(', q + 1)
    if stop < 0: stop = s.len
    result.pushElement checkedElement(GS1Element(ai: s[p + 1..<q], value: s[q + 1..<stop]), result.len)
    p = stop
proc readAi(s: string; pos: int): Option[GS1AiInfo] =
  for n in [4, 3, 2]:
    if pos + n <= s.len:
      let info = getGs1AiInfo(s[pos..<pos + n])
      if info.isSome: return info
  none(GS1AiInfo)
proc parseGs1ElementString*(value: string): GS1ElementStringParseResult =
  let s = asciiInput(value, "GS1 element string")
  if '(' in s or ')' in s: gs1Fail("GS1 element string must be raw data without parentheses")
  var p = 0
  while p < s.len:
    if s[p] == '\x1d': gs1Fail("Unexpected FNC1 separator at offset " & $p, "GS1_UNEXPECTED_SEPARATOR")
    let found = readAi(s, p)
    if found.isNone: gs1Fail("Unsupported GS1 AI at offset " & $p, "GS1_UNSUPPORTED_AI")
    let info = found.get
    let start = p + info.ai.len
    var stop = if info.length.isVariable: s.find('\x1d', start) else: min(s.len, start + info.length.exact.get)
    if stop < 0: stop = s.len
    if info.length.isVariable and stop == s.len:
      for off in max(start + 1, stop - 22)..<stop:
        let tail = readAi(s, off)
        if tail.isSome and not tail.get.length.isVariable and off + tail.get.ai.len + tail.get.length.exact.get == stop:
          gs1Fail("GS1 variable field is missing an FNC1 separator before offset " & $off, "GS1_MISSING_SEPARATOR")
    result.elements.pushElement checkedElement(GS1Element(ai: info.ai, value: s[start..<stop]), result.elements.len)
    p = stop
    if info.length.isVariable and p < s.len:
      inc p
      if p >= s.len: gs1Fail("GS1 element string must not end with an FNC1 separator", "GS1_UNEXPECTED_SEPARATOR")
  result.hasSeparators = '\x1d' in s
proc createGs1ElementString*(elements: openArray[GS1Element]): string =
  let values = normalizeGs1Elements(elements)
  for i, e in values:
    result.add e.ai
    result.add e.value
    if i < values.high and getGs1AiInfo(e.ai).get.length.isVariable: result.add GS1_FNC1_SEPARATOR
    if result.len > GS1_MAX_INPUT_CHARACTERS: gs1Fail("GS1 output exceeds character budget")
proc gs1ToHumanReadable*(elements: openArray[GS1Element]): string =
  for e in normalizeGs1Elements(elements): result.add "(" & e.ai & ")" & e.value
  result = checkedText(result, "GS1 output")
proc normalizeGs1Elements*(value: string): seq[GS1Element] =
  if value.startsWith("("): parseGs1HumanReadable(value)
  else: parseGs1ElementString(value).elements
proc gs1ElementStringToHumanReadable*(value: string): string =
  gs1ToHumanReadable(parseGs1ElementString(value).elements)

proc `%`*(e: GS1Element): JsonNode = %* {"ai": e.ai, "value": e.value}
proc `%`*(q: GS1UnknownQuery): JsonNode = %* {"key": q.key, "value": q.value}
proc `%`*(p: GS1ElementStringParseResult): JsonNode =
  %* {"elements": p.elements, "hasSeparators": p.hasSeparators}
proc `%`*(p: GS1DigitalLinkParseResult): JsonNode =
  %* {"elements": p.elements, "primary": p.primary, "pathElements": p.pathElements,
      "queryElements": p.queryElements, "unknownQuery": p.unknownQuery}
proc `%`*(info: GS1AiInfo): JsonNode =
  let length = if info.length.isVariable:
    %* {"type": "variable", "min": info.length.min.get, "max": info.length.max.get, "isVariable": true}
  else: %* {"type": "fixed", "exact": info.length.exact.get, "isVariable": false}
  result = %* {"ai": info.ai, "label": info.label, "length": length,
    "valueKind": info.valueKind, "checkDigitRule": info.checkDigitRule,
    "digitalLinkRole": info.digitalLinkRole, "separator": info.separator,
    "digitalLinkPathForPrimary": newJNull()}
  if info.digitalLinkPathForPrimary.len > 0: result["digitalLinkPathForPrimary"] = %info.digitalLinkPathForPrimary
proc issue(error: ref SpecQRError; element = none(GS1Element); index = -1): JsonNode =
  let reason = case error.detailCode
    of "GS1_UNSUPPORTED_AI": "unsupported-ai"
    of "GS1_INVALID_LENGTH": "invalid-length"
    of "GS1_INVALID_CHARSET": "invalid-charset"
    of "GS1_MISSING_SEPARATOR": "missing-separator"
    of "GS1_UNEXPECTED_SEPARATOR": "unexpected-separator"
    of "GS1_INVALID_CHECK_DIGIT": "invalid-check-digit"
    of "GS1_INVALID_PERCENT_ENCODING": "invalid-percent-encoding"
    of "GS1_INVALID_DIGITAL_LINK_PLACEMENT": "invalid-digital-link-placement"
    of "GS1_DUPLICATE_AI": "duplicate-ai"
    of "GS1_DIGITAL_LINK_UNKNOWN_QUERY": "unknown-query"
    of "GS1_DIGITAL_LINK_UNSUPPORTED_HOST": "unsupported-host"
    of "GS1_DIGITAL_LINK_INVALID_URI": "invalid-uri"
    of "GS1_DIGITAL_LINK_FRAGMENT_NOT_ALLOWED": "fragment-not-allowed"
    else: "invalid-input"
  result = %* {"code": error.detailCode, "message": error.msg, "reason": reason,
    "ai": newJNull(), "value": newJNull(), "key": newJNull(), "offset": newJNull(),
    "elementIndex": newJNull(), "expected": newJNull(), "count": newJNull()}
  if element.isSome:
    let e = element.get
    if e.ai.len <= 4 and validScalarUtf8(e.ai): result["ai"] = %e.ai
    if e.value.len <= 90 and validScalarUtf8(e.value): result["value"] = %e.value
  if result["ai"].kind == JNull:
    let at = error.msg.find("GS1 AI ")
    if at >= 0:
      var tail = at + 7
      while tail < error.msg.len and error.msg[tail] in {'0'..'9'}: inc tail
      if tail - at - 7 in 2..4: result["ai"] = %error.msg[at + 7..<tail]
  let at = error.msg.find("offset ")
  if at >= 0:
    var tail = at + 7
    while tail < error.msg.len and error.msg[tail] in {'0'..'9'}: inc tail
    if tail > at + 7: result["offset"] = %parseInt(error.msg[at + 7..<tail])
  if index >= 0: result["elementIndex"] = %index
  if error.detailCode == "GS1_DIGITAL_LINK_UNSUPPORTED_HOST":
    result["expected"] = %"ASCII DNS name, canonical dotted IPv4, or RFC IPv6"
proc validationOptions(context: string; allowUnsupportedAi: bool) =
  if context notin ["element-string", "digital-link"]:
    gs1Fail("GS1 validation context must be element-string or digital-link")
  if allowUnsupportedAi: gs1Fail("GS1 validation allowUnsupportedAi must be false")
proc validationFailure(error: ref SpecQRError; digital = false): JsonNode =
  result = %* {"ok": false, "errors": [issue(error)], "warnings": []}
  if digital: result["result"] = newJNull()
  else:
    result["elements"] = newJNull()
    result["hasSeparators"] = newJNull()
proc validateGs1Elements*(elements: openArray[GS1Element]; context = "element-string";
                          collectAllErrors = true; allowUnsupportedAi = false): JsonNode =
  try:
    validationOptions(context, allowUnsupportedAi)
    checkBounded(elements)
    if elements.len == 0: gs1Fail("GS1 elements must not be empty")
    var normalized: seq[GS1Element]
    var errors = newJArray()
    for i, e in elements:
      try: normalized.add checkedElement(e, i)
      except SpecQRError as err:
        errors.add issue(err, some(e), i)
        if not collectAllErrors: break
    if errors.len > 0:
      return %* {"ok": false, "elements": newJNull(), "hasSeparators": newJNull(), "errors": errors, "warnings": []}
    if context == "digital-link":
      var hasPrimary = false
      for e in normalized:
        if e.ai in primaryAis: hasPrimary = true
      if not hasPrimary: gs1Fail("GS1 Digital Link requires primary AI 00, 01, or 414", "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
    return %* {"ok": true, "elements": normalized, "hasSeparators": newJNull(), "errors": [], "warnings": []}
  except SpecQRError as err: return validationFailure(err)
proc validateGs1ElementString*(value: string; context = "element-string";
                              collectAllErrors = true; allowUnsupportedAi = false): JsonNode =
  try:
    validationOptions(context, allowUnsupportedAi)
    let parsed = parseGs1ElementString(value)
    result = validateGs1Elements(parsed.elements, context, collectAllErrors, allowUnsupportedAi)
    result["hasSeparators"] = %parsed.hasSeparators
  except SpecQRError as err: result = validationFailure(err)

proc hexDigit(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1
proc percentFail() {.noreturn.} =
  gs1Fail("GS1 URI must use valid percent-encoding and UTF-8 without NUL", "GS1_INVALID_PERCENT_ENCODING")
proc decode(value: string; form = false): string =
  var i = 0
  while i < value.len:
    if value[i] == '%':
      if i + 2 >= value.len: percentFail()
      let a = hexDigit(value[i + 1])
      let b = hexDigit(value[i + 2])
      if a < 0 or b < 0: percentFail()
      result.add char(16 * a + b)
      i += 3
    else:
      result.add (if form and value[i] == '+': ' ' else: value[i])
      inc i
  if not validScalarUtf8(result) or '\0' in result: percentFail()
proc encode(value: string; form = false): string =
  for c in value:
    var safe = c in {'a'..'z', 'A'..'Z', '0'..'9', '*', '-', '.', '_'}
    if not form: safe = safe or c in {'~', '!', '\'', '(', ')'}
    if safe: result.add c
    elif form and c == ' ': result.add '+'
    else: result.add '%' & toHex(ord(c), 2)
proc boundedSplit(value: string; separator: char; limit: int): seq[string] =
  if value.count(separator) >= limit: gs1Fail("GS1 URL component count exceeds limit")
  value.split(separator)
proc queryPair(value: string): GS1UnknownQuery =
  let at = value.find('=')
  if at < 0: GS1UnknownQuery(key: decode(value, true), value: "")
  else: GS1UnknownQuery(key: decode(value[0..<at], true), value: decode(value[at + 1..<value.len], true))
proc ipv4(value: string): bool =
  let parts = value.split('.')
  if parts.len != 4: return false
  for part in parts:
    if part.len notin 1..3 or not digits(part): return false
    if part.len > 1 and part[0] == '0': return false
    if parseInt(part) > 255: return false
  true
proc ipv6Side(value: string; allowIpv4 = false): int =
  if value.len == 0: return 0
  let parts = value.split(':')
  for i, part in parts:
    if part.len == 0: return -1
    if '.' in part:
      if not allowIpv4 or i != parts.high or not ipv4(part): return -1
      result += 2
    else:
      if part.len > 4: return -1
      for c in part:
        if hexDigit(c) < 0: return -1
      inc result
proc ipv6(value: string): bool =
  let parts = value.split("::")
  if parts.len == 1: return ipv6Side(parts[0], true) == 8
  if parts.len == 2:
    let a = ipv6Side(parts[0])
    let b = ipv6Side(parts[1], true)
    return a >= 0 and b >= 0 and a + b < 8
  false
proc hostFail() {.noreturn.} =
  gs1Fail("Unsupported host profile; use ASCII DNS, canonical dotted IPv4, or RFC IPv6 without credentials", "GS1_DIGITAL_LINK_UNSUPPORTED_HOST")
proc authority(value, scheme: string): string =
  if value.len notin 1..1024 or not ascii(value) or '@' in value or '%' in value: hostFail()
  var port = none(string)
  if value.startsWith("["):
    let close = value.find(']')
    if close < 0: hostFail()
    let address = value[1..<close]
    if not ipv6(address): hostFail()
    result = "[" & address.toLowerAscii & "]"
    let tail = value[close + 1..<value.len]
    if tail.len > 0:
      if not tail.startsWith(":"): hostFail()
      port = some(tail[1..<tail.len])
  else:
    let at = value.find(':')
    result = (if at < 0: value else: value[0..<at]).toLowerAscii
    if at >= 0: port = some(value[at + 1..<value.len])
    let dns = if result.endsWith("."): result[0..<result.high] else: result
    if dns.len notin 1..253: hostFail()
    let labels = dns.split('.')
    for label in labels:
      if label.len notin 1..63: hostFail()
      if label[0] notin {'a'..'z', '0'..'9'} or label[^1] notin {'a'..'z', '0'..'9'}: hostFail()
      for c in label:
        if c notin {'a'..'z', '0'..'9', '-'}: hostFail()
    let tail = labels[^1]
    var hexNumber = tail.startsWith("0x")
    if hexNumber:
      for i in 2..<tail.len:
        if hexDigit(tail[i]) < 0: hexNumber = false
    if (digits(tail) or hexNumber) and not ipv4(result): hostFail()
  if port.isSome:
    let p = port.get
    if p.len notin 1..5 or not digits(p):
      gs1Fail("GS1 port must contain decimal digits from 0 to 65535", "GS1_DIGITAL_LINK_INVALID_URI")
    let number = parseInt(p)
    if number > 65535: gs1Fail("GS1 port must be from 0 to 65535", "GS1_DIGITAL_LINK_INVALID_URI")
    if not ((scheme == "http" and number == 80) or (scheme == "https" and number == 443)):
      result.add ":" & $number
proc parseUrl(value: string): GS1Url =
  let s = checkedText(value, "GS1 Digital Link URI")
  if '#' in s: gs1Fail("GS1 Digital Link URI must not include a fragment", "GS1_DIGITAL_LINK_FRAGMENT_NOT_ALLOWED")
  for c in s:
    if c <= ' ' or c == '\x7f' or c == '\\':
      gs1Fail("GS1 URI must be absolute http or https without whitespace or backslashes", "GS1_DIGITAL_LINK_INVALID_URI")
  let schemeEnd = s.find("://")
  if schemeEnd < 0: gs1Fail("GS1 URI must be an absolute http or https URL", "GS1_DIGITAL_LINK_INVALID_URI")
  result.scheme = s[0..<schemeEnd].toLowerAscii
  if result.scheme notin ["http", "https"]:
    gs1Fail("GS1 URI must be an absolute http or https URL", "GS1_DIGITAL_LINK_INVALID_URI")
  let start = schemeEnd + 3
  var stop = start
  while stop < s.len and s[stop] notin {'/', '?'}: inc stop
  result.authority = authority(s[start..<stop], result.scheme)
  let queryAt = s.find('?', stop)
  if queryAt < 0: result.path = s[stop..<s.len]
  else:
    result.path = s[stop..<queryAt]
    result.query = some(s[queryAt + 1..<s.len])
  for part in boundedSplit(result.path, '/', 2 * GS1_MAX_ELEMENTS + 1): discard decode(part)
  if result.query.isSome:
    for pair in boundedSplit(result.query.get, '&', GS1_MAX_ELEMENTS): discard queryPair(pair)
proc urlBase(url: GS1Url): string = url.scheme & "://" & url.authority
proc checkPrimary(ai: string) =
  if ai notin primaryAis: gs1Fail("GS1 primaryAi must be one of 00, 01, or 414")
proc checkPolicy(policy: string) =
  if policy notin ["preserve", "reject"]: gs1Fail("GS1 unknownQuery must be preserve or reject")
proc placement(ai, primary: string) =
  if getGs1AiInfo(ai).isNone: gs1Fail("Unsupported GS1 AI " & ai, "GS1_UNSUPPORTED_AI")
  if not eligible(ai, primary):
    gs1Fail("GS1 AI " & ai & " cannot be placed in the Digital Link path after primary AI " & primary, "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
proc unique(seen: var HashSet[string]; ai: string) =
  if ai in seen: gs1Fail("GS1 Digital Link must not contain duplicate AI " & ai, "GS1_DUPLICATE_AI")
  seen.incl ai
proc prefix(parts: openArray[string]): string =
  var stack: seq[string]
  for part in parts:
    let decoded = decode(part)
    if decoded in ["", "."]: continue
    if decoded == "..":
      if stack.len > 0: discard stack.pop()
    else: stack.add part
  if stack.len > 0: "/" & stack.join("/") else: ""
proc pathParts(path: string): seq[string] =
  let value = strutils.strip(path, chars = {'/'})
  if value.len == 0:
    gs1Fail("GS1 Digital Link path must include primary AI 00, 01, or 414", "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
  result = boundedSplit(value, '/', 2 * GS1_MAX_ELEMENTS + 1)
  for part in result:
    if part.len == 0: gs1Fail("GS1 Digital Link path must not contain empty segments")
proc firstAi(parts: openArray[string]; primaryAi: string): int =
  for i, part in parts:
    if (primaryAi.len == 0 and part in primaryAis) or (primaryAi.len > 0 and part == primaryAi): return i
  gs1Fail("GS1 Digital Link path must include primary AI 00, 01, or 414", "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
proc createGs1DigitalLink*(elements: openArray[GS1Element]; baseUrl = "https://id.gs1.org";
                          primaryAi = "01"; pathAis: seq[string] = @[];
                          explicitPathAis = false): string =
  checkPrimary(primaryAi)
  let base = parseUrl(baseUrl)
  if base.query.isSome: gs1Fail("GS1 Digital Link baseUrl must not include query components")
  if pathAis.len > GS1_MAX_ELEMENTS: gs1Fail("GS1 element count exceeds limit")
  var paths = initHashSet[string]()
  for ai in pathAis:
    if not isAi(ai): gs1Fail("GS1 pathAis entries must be 2 to 4 digit AI strings")
    if ai != primaryAi:
      placement(ai, primaryAi)
      paths.incl ai
  let values = normalizeGs1Elements(elements)
  var seen = initHashSet[string]()
  var selected = -1
  for i, e in values:
    seen.unique(e.ai)
    if e.ai == primaryAi: selected = i
  if selected < 0: gs1Fail("GS1 input must include primary AI " & primaryAi, "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
  var path = @[values[selected]]
  var query: seq[GS1Element]
  for i, e in values:
    if i == selected: continue
    let inPath = if explicitPathAis or pathAis.len > 0: e.ai in paths else: eligible(e.ai, primaryAi)
    if inPath and e.value notin [".", ".."]:
      placement(e.ai, primaryAi)
      path.add e
    else: query.add e
  query.sort(proc(a, b: GS1Element): int =
    let first = cmp(a.ai, b.ai)
    if first == 0: cmp(a.value, b.value) else: first)
  let stem = prefix(boundedSplit(base.path, '/', 2 * GS1_MAX_ELEMENTS + 1))
  for part in boundedSplit(stem, '/', 2 * GS1_MAX_ELEMENTS + 1):
    if decode(part) in primaryAis:
      gs1Fail("GS1 base URL normalized path must not contain a primary AI component (00, 01, or 414), including percent-encoded equivalents", "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
  result = urlBase(base) & stem
  for e in path: result.add "/" & encode(e.ai) & "/" & encode(e.value)
  for i, e in query:
    result.add (if i == 0: "?" else: "&") & encode(e.ai, true) & "=" & encode(e.value, true)
  result = checkedText(result, "GS1 Digital Link output")
proc parseLink(url: GS1Url; primaryAi, unknownQuery: string): GS1DigitalLinkParseResult =
  if primaryAi.len > 0: checkPrimary(primaryAi)
  checkPolicy(unknownQuery)
  let parts = pathParts(url.path)
  let start = firstAi(parts, primaryAi)
  for i in start..<parts.len:
    if decode(parts[i]) in [".", ".."]:
      gs1Fail("GS1 Digital Link path values must not be dot segments; place these values in the query", "GS1_INVALID_DIGITAL_LINK_PLACEMENT")
  if (parts.len - start) mod 2 != 0: gs1Fail("GS1 Digital Link path must contain AI/value pairs")
  var seen = initHashSet[string]()
  var i = start
  while i < parts.len:
    let ai = parts[i]
    if not isAi(ai): gs1Fail("GS1 Digital Link path segment " & $(i + 1) & " must be a GS1 AI")
    let element = checkedElement(GS1Element(ai: ai, value: decode(parts[i + 1])), result.pathElements.len)
    if result.pathElements.len > 0: placement(ai, result.pathElements[0].ai)
    seen.unique(ai)
    result.pathElements.pushElement(element)
    i += 2
  if url.query.isSome:
    for raw in boundedSplit(url.query.get, '&', GS1_MAX_ELEMENTS):
      if raw.len == 0: continue
      let pair = queryPair(raw)
      if isAi(pair.key):
        let element = checkedElement(GS1Element(ai: pair.key, value: pair.value), result.pathElements.len + result.queryElements.len)
        seen.unique(element.ai)
        result.queryElements.pushElement(element)
      elif unknownQuery == "preserve": result.unknownQuery.add pair
      else: gs1Fail("GS1 Digital Link query parameter is not a GS1 AI", "GS1_DIGITAL_LINK_UNKNOWN_QUERY")
      if result.pathElements.len + result.queryElements.len + result.unknownQuery.len > GS1_MAX_ELEMENTS:
        gs1Fail("GS1 element and query pair count exceeds limit")
  result.elements = result.pathElements & result.queryElements
  result.primary = result.pathElements[0]
proc parseGs1DigitalLink*(uri: string; primaryAi = ""; unknownQuery = "preserve"): GS1DigitalLinkParseResult =
  parseLink(parseUrl(uri), primaryAi, unknownQuery)
proc validateGs1DigitalLink*(uri: string; primaryAi = ""; unknownQuery = "preserve";
                            normalize = false): JsonNode =
  try:
    if normalize: gs1Fail("GS1 validation normalize is unsupported; call normalizeGs1DigitalLink")
    let url = parseUrl(uri)
    let parsed = parseLink(url, primaryAi, unknownQuery)
    var warnings = newJArray()
    if url.scheme == "http":
      warnings.add(%* {"code": "GS1_DIGITAL_LINK_HTTP", "message": "URI uses HTTP; use HTTPS when transport security is required", "reason": "http-uri"})
    if parsed.unknownQuery.len > 0:
      warnings.add(%* {"code": "GS1_DIGITAL_LINK_UNKNOWN_QUERY_PRESERVED", "message": "Non-GS1 query parameters are preserved", "reason": "unknown-query-preserved", "count": parsed.unknownQuery.len})
    result = %* {"ok": true, "result": parsed, "errors": [], "warnings": warnings}
  except SpecQRError as err: result = validationFailure(err, true)
proc normalizeGs1DigitalLink*(uri: string; primaryAi = ""; unknownQuery = "preserve";
                             mode = "specqr-deterministic"): string =
  if mode != "specqr-deterministic": gs1Fail("GS1 normalization mode must be specqr-deterministic")
  let url = parseUrl(uri)
  let parsed = parseLink(url, primaryAi, unknownQuery)
  let parts = pathParts(url.path)
  let start = firstAi(parts, primaryAi)
  let stem = urlBase(url) & prefix(parts[0..<start])
  result = createGs1DigitalLink(parsed.elements, baseUrl = stem, primaryAi = parsed.primary.ai)
  for pair in parsed.unknownQuery:
    result.add (if '?' in result: "&" else: "?") & encode(pair.key, true) & "=" & encode(pair.value, true)
  result = checkedText(result, "GS1 Digital Link output")

# Familiar helper names are kept as typed aliases.
proc gs1Normalize*(elements: openArray[GS1Element]): seq[GS1Element] = normalizeGs1Elements(elements)
proc gs1Normalize*(value: string): seq[GS1Element] = normalizeGs1Elements(value)
proc gs1FromHumanReadable*(value: string): seq[GS1Element] = parseGs1HumanReadable(value)
proc gs1ToElementString*(elements: openArray[GS1Element]): string = createGs1ElementString(elements)
proc gs1Build*(elements: openArray[GS1Element]): string = createGs1ElementString(elements)
proc gs1Parse*(value: string): GS1ElementStringParseResult = parseGs1ElementString(value)
proc gs1DigitalLink*(elements: openArray[GS1Element]; baseUrl = "https://id.gs1.org";
                     primaryAi = "01"; pathAis: seq[string] = @[]; explicitPathAis = false): string =
  createGs1DigitalLink(elements, baseUrl, primaryAi, pathAis, explicitPathAis)
proc gs1ToDigitalLink*(elements: openArray[GS1Element]; baseUrl = "https://id.gs1.org";
                       primaryAi = "01"; pathAis: seq[string] = @[]; explicitPathAis = false): string =
  createGs1DigitalLink(elements, baseUrl, primaryAi, pathAis, explicitPathAis)
