import std/[json, options, strutils, unittest]
import specqr/[errors, gs1]

const gtin = "09506000134352"
let primary = GS1Element(ai: "01", value: gtin)

template expectCode(expected: string; body: untyped) =
  block:
    var caught = false
    try:
      body
    except SpecQRError as e:
      caught = true
      check e.code == "INVALID_GS1"
      check e.detailCode == expected
    check caught

suite "GS1 catalog and check digits":
  test "50 concrete supported AIs and metadata":
    check getSupportedGs1Ais().len == 50
    check getGs1AiInfo("01").get.length.exact.get == 14
    check getGs1AiInfo("10").get.length.isVariable
    check getGs1AiInfo("10").get.digitalLinkPathForPrimary == @["01"]
    check getGs1AiInfo("3105").get.valueKind == "numeric"
    check getGs1AiInfo("3106").isNone
    check getGs1AiInfo("9999").isNone
    check (%getGs1AiInfo("17").get)["length"]["exact"].getInt == 6
  test "GS1 modulo 10 known and zero vectors":
    check calculateGs1CheckDigit("0950600013435") == "2"
    check appendGtinCheckDigit("0950600013435") == gtin
    check validateGtinCheckDigit(gtin)
    check not validateGtinCheckDigit("09506000134353")
    check calculateGs1CheckDigit("0") == "0"
    check validateGs1CheckDigit("00")
    for body in ["1234567", "12345678901", "123456789012", "1234567890123"]:
      check validateGtinCheckDigit(appendGtinCheckDigit(body))
    check validateSsccCheckDigit(appendSsccCheckDigit("12345678901234567"))
  test "check digit malformed values fail with typed diagnostics":
    expectCode("GS1_INVALID_CHARSET"): discard calculateGs1CheckDigit("")
    expectCode("GS1_INVALID_CHARSET"): discard calculateGs1CheckDigit("1x")
    expectCode("GS1_INVALID_LENGTH"): discard validateGs1CheckDigit("1")
    expectCode("GS1_INVALID_LENGTH"): discard calculateGtinCheckDigit("123")
    expectCode("GS1_INVALID_LENGTH"): discard validateGtinCheckDigit("12")
    expectCode("GS1_INVALID_LENGTH"): discard calculateSsccCheckDigit("123")
    expectCode("GS1_INVALID_LENGTH"): discard validateSsccCheckDigit("123")
  test "bounded check digit input":
    expectCode("GS1_INVALID_INPUT"):
      discard calculateGs1CheckDigit(repeat('1', GS1_MAX_INPUT_CHARACTERS + 1))

suite "GS1 element strings":
  test "human-readable and FNC1 round trip":
    let elements = @[primary, GS1Element(ai: "10", value: "LOT-A"), GS1Element(ai: "17",
        value: "271231")]
    let human = "(01)" & gtin & "(10)LOT-A(17)271231"
    let raw = "01" & gtin & "10LOT-A\x1d17271231"
    check parseGs1HumanReadable(human) == elements
    check createGs1ElementString(elements) == raw
    check gs1ToHumanReadable(elements) == human
    check gs1ElementStringToHumanReadable(raw) == human
    check parseGs1ElementString(raw).elements == elements
    check parseGs1ElementString(raw).hasSeparators
    check not parseGs1ElementString("01" & gtin).hasSeparators
    check normalizeGs1Elements(raw) == elements
    check normalizeGs1Elements(human) == elements
    check normalizeGs1Elements(parseGs1ElementString(raw)) == elements
  test "every supported AI accepts its bounded canonical sample":
    for info in getSupportedGs1Ais():
      let value = if info.valueKind == "text": "X"
                  elif info.length.isVariable: "1"
                  else: repeat('0', info.length.exact.get)
      let elements = @[GS1Element(ai: info.ai, value: value)]
      check parseGs1HumanReadable(gs1ToHumanReadable(elements)) == elements
      check parseGs1ElementString(createGs1ElementString(elements)).elements == elements
      check validateGs1Elements(elements)["ok"].getBool
  test "fixed concatenation and variable followed by variable":
    check createGs1ElementString([GS1Element(ai: "17", value: "271231"), GS1Element(ai: "20",
        value: "42")]) == "172712312042"
    let values = @[GS1Element(ai: "10", value: "A%"), GS1Element(ai: "21", value: "B%%")]
    check createGs1ElementString(values) == "10A%\x1d21B%%"
    check parseGs1ElementString(createGs1ElementString(values)).elements == values
  test "missing and extra separators are diagnosed":
    expectCode("GS1_MISSING_SEPARATOR"): discard parseGs1ElementString("10LOT17271231")
    expectCode("GS1_UNEXPECTED_SEPARATOR"): discard parseGs1ElementString("\x1d10X")
    expectCode("GS1_UNEXPECTED_SEPARATOR"): discard parseGs1ElementString("10X\x1d")
    expectCode("GS1_UNEXPECTED_SEPARATOR"): discard parseGs1ElementString("17271231\x1d10X")
    expectCode("GS1_UNEXPECTED_SEPARATOR"): discard parseGs1ElementString("10X\x1d\x1d21Y")
  test "semantic field errors are separated":
    expectCode("GS1_INVALID_CHECK_DIGIT"): discard parseGs1HumanReadable("(01)09506000134353")
    expectCode("GS1_INVALID_LENGTH"): discard parseGs1HumanReadable("(10)")
    expectCode("GS1_INVALID_LENGTH"): discard parseGs1HumanReadable("(17)123")
    expectCode("GS1_INVALID_CHARSET"): discard parseGs1HumanReadable("(17)abcdef")
    expectCode("GS1_UNSUPPORTED_AI"): discard parseGs1HumanReadable("(9999)x")
    expectCode("GS1_INVALID_INPUT"): discard parseGs1HumanReadable("(1)x")
    expectCode("GS1_INVALID_INPUT"): discard parseGs1HumanReadable("(10x")
    expectCode("GS1_INVALID_INPUT"): discard parseGs1HumanReadable("10X")
    expectCode("GS1_INVALID_INPUT"): discard parseGs1ElementString("(10)X")
    expectCode("GS1_UNEXPECTED_SEPARATOR"): discard normalizeGs1Elements([GS1Element(ai: "10",
        value: "x\x1d")])
  test "UTF-8 and printable ASCII validation":
    expectCode("GS1_INVALID_CHARSET"): discard parseGs1HumanReadable("(10)日本")
    for bad in ["\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\x80", "\xf0\x80\x80\x80"]:
      expectCode("GS1_INVALID_INPUT"): discard parseGs1HumanReadable("(10)" & bad)
    expectCode("GS1_INVALID_CHARSET"): discard normalizeGs1Elements([GS1Element(ai: "10",
        value: "a\nb")])
  test "validation accumulates zero-based field issues":
    let invalid = @[GS1Element(ai: "01", value: "bad"), GS1Element(ai: "17", value: "short")]
    let checked = validateGs1Elements(invalid)
    check not checked["ok"].getBool
    check checked["errors"].len == 2
    check checked["errors"][0]["elementIndex"].getInt == 0
    check checked["errors"][1]["elementIndex"].getInt == 1
    check checked["errors"][1]["ai"].getStr == "17"
    check validateGs1Elements(invalid, collectAllErrors = false)["errors"].len == 1
    check not validateGs1Elements([primary], allowUnsupportedAi = true)["ok"].getBool
    check not validateGs1Elements([primary], context = "other")["ok"].getBool
    check not validateGs1Elements([GS1Element(ai: "10", value: "x")], context = "digital-link")["ok"].getBool
    check validateGs1Elements([primary], context = "digital-link")["ok"].getBool
    check validateGs1ElementString("10X")["hasSeparators"].getBool == false
  test "count and aggregate budgets fail predictably":
    var elements: seq[GS1Element]
    for i in 0..GS1_MAX_ELEMENTS: elements.add GS1Element(ai: "10", value: "X")
    expectCode("GS1_INVALID_INPUT"): discard createGs1ElementString(elements)
    expectCode("GS1_INVALID_INPUT"): discard createGs1ElementString(newSeq[GS1Element](0))
    expectCode("GS1_INVALID_INPUT"): discard normalizeGs1Elements([GS1Element(ai: "10",
        value: repeat('A', GS1_MAX_INPUT_CHARACTERS))])

suite "GS1 Digital Link":
  test "builder puts qualifiers in path and sorted data in query":
    let values = @[GS1Element(ai: "17", value: "271231"), primary,
                   GS1Element(ai: "10", value: "LOT A"), GS1Element(ai: "21", value: "S/2"),
                   GS1Element(ai: "240", value: "x+y")]
    let uri = createGs1DigitalLink(values)
    check uri == "https://id.gs1.org/01/" & gtin & "/10/LOT%20A/21/S%2F2?17=271231&240=x%2By"
    let parsed = parseGs1DigitalLink(uri)
    check parsed.primary == primary
    check parsed.pathElements.len == 3
    check parsed.queryElements.len == 2
    check parsed.unknownQuery.len == 0
    check validateGs1DigitalLink(uri)["ok"].getBool
    check normalizeGs1DigitalLink(uri) == uri
  test "custom and empty path AI selections":
    let values = @[primary, GS1Element(ai: "10", value: "LOT"), GS1Element(ai: "21", value: "SER")]
    check createGs1DigitalLink(values, pathAis = @["21"]) == "https://id.gs1.org/01/" & gtin & "/21/SER?10=LOT"
    check createGs1DigitalLink(values, explicitPathAis = true) == "https://id.gs1.org/01/" & gtin & "?10=LOT&21=SER"
    expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"):
      discard createGs1DigitalLink(values, pathAis = @["17"])
  test "other primary AIs put GTIN qualifiers in query":
    let sscc = appendSsccCheckDigit("12345678901234567")
    check createGs1DigitalLink([GS1Element(ai: "00", value: sscc), GS1Element(ai: "10",
        value: "x")], primaryAi = "00") == "https://id.gs1.org/00/" & sscc & "?10=x"
    check parseGs1DigitalLink("https://example.com/414/1234567890123").primary.ai == "414"
    expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"):
      discard createGs1DigitalLink([GS1Element(ai: "10", value: "x")])
  test "unknown duplicate query pairs preserve order and decoded values":
    let input = "https://EXAMPLE.COM:00443/p/01/" & gtin & "?utm=a&utm=b&x=a+b&empty&x=%E6%97%A5%E6%9C%AC&17=271231"
    let parsed = parseGs1DigitalLink(input)
    check parsed.unknownQuery == @[
      GS1UnknownQuery(key: "utm", value: "a"), GS1UnknownQuery(key: "utm", value: "b"),
      GS1UnknownQuery(key: "x", value: "a b"), GS1UnknownQuery(key: "empty", value: ""),
      GS1UnknownQuery(key: "x", value: "日本")]
    let expected = "https://example.com/p/01/" & gtin & "?17=271231&utm=a&utm=b&x=a+b&empty=&x=%E6%97%A5%E6%9C%AC"
    check normalizeGs1DigitalLink(input) == expected
    check normalizeGs1DigitalLink(expected) == expected
    check validateGs1DigitalLink(input)["warnings"][0]["count"].getInt == 5
    expectCode("GS1_DIGITAL_LINK_UNKNOWN_QUERY"):
      discard parseGs1DigitalLink(input, unknownQuery = "reject")
  test "dot-only builder data is safely routed into query":
    let values = @[primary, GS1Element(ai: "10", value: ".."), GS1Element(ai: "21", value: ".")]
    let expected = "https://example.com/01/" & gtin & "?10=..&21=."
    check createGs1DigitalLink(values, baseUrl = "https://example.com") == expected
    check normalizeGs1DigitalLink(expected & "&utm=a&utm=b") == expected & "&utm=a&utm=b"
    check parseGs1DigitalLink(expected).elements == values
    for dot in [".", "..", "%2e", "%2E%2e", ".%2E", "%2e."]:
      let input = "https://example.com/01/" & gtin & "/10/" & dot
      expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"): discard parseGs1DigitalLink(input)
      check not validateGs1DigitalLink(input)["ok"].getBool
      expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"): discard normalizeGs1DigitalLink(input)
    check createGs1DigitalLink([primary, GS1Element(ai: "10", value: "%2e")],
        baseUrl = "https://example.com") == "https://example.com/01/" & gtin & "/10/%252e"
  test "base prefix normalization is isolated from data":
    check createGs1DigitalLink([primary], baseUrl = "https://example.com/a/../b") ==
        "https://example.com/b/01/" & gtin
    check createGs1DigitalLink([primary], baseUrl = "https://example.com/a/%2E%2e/b") ==
        "https://example.com/b/01/" & gtin
    expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"):
      discard createGs1DigitalLink([primary], baseUrl = "https://example.com/%30%31")
    expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"):
      discard parseGs1DigitalLink("https://example.com/01/./../01/" & gtin)
  test "duplicate AIs and invalid placement are rejected":
    expectCode("GS1_DUPLICATE_AI"): discard createGs1DigitalLink([primary, primary])
    expectCode("GS1_DUPLICATE_AI"): discard parseGs1DigitalLink("https://example.com/01/" & gtin &
        "?01=" & gtin)
    expectCode("GS1_DUPLICATE_AI"): discard parseGs1DigitalLink("https://example.com/01/" & gtin & "?10=x&10=y")
    expectCode("GS1_INVALID_DIGITAL_LINK_PLACEMENT"): discard parseGs1DigitalLink(
        "https://example.com/01/" & gtin & "/17/271231")
    expectCode("GS1_UNSUPPORTED_AI"): discard parseGs1DigitalLink("https://example.com/01/" & gtin & "?9999=x")
    expectCode("GS1_INVALID_INPUT"): discard createGs1DigitalLink([primary],
        baseUrl = "https://example.com?x=y")
    check not validateGs1DigitalLink("https://example.com/01/" & gtin, normalize = true)["ok"].getBool
  test "percent syntax and malformed scalar UTF-8 are rejected":
    for bad in ["%", "%0", "%GG", "%C0%AF", "%ED%A0%80", "%F4%90%80%80", "%FF", "%00"]:
      expectCode("GS1_INVALID_PERCENT_ENCODING"):
        discard parseGs1DigitalLink("https://example.com/01/" & gtin & "?x=" & bad)
    let parsed = parseGs1DigitalLink("https://example.com/01/" & gtin & "/10/A%2FB%25C?x=a%3Db")
    check parsed.pathElements[1].value == "A/B%C"
    check parsed.unknownQuery[0].value == "a=b"
  test "bounded query expansion and unknown policy":
    expectCode("GS1_INVALID_INPUT"):
      discard parseGs1DigitalLink("https://example.com/01/" & gtin & "?" & repeat("x=y&",
          GS1_MAX_ELEMENTS))
    expectCode("GS1_INVALID_INPUT"):
      discard parseGs1DigitalLink("https://example.com/01/" & gtin, unknownQuery = "ignore")
    expectCode("GS1_INVALID_INPUT"):
      discard normalizeGs1DigitalLink("https://example.com/01/" & gtin, mode = "other")

suite "Digital Link strict offline authority profile":
  test "canonical DNS IPv4 and IPv6 are accepted without network access":
    for host in ["example.com", "EXAMPLE.COM", "example.com.", "xn--bcher-kva.example",
                 "localhost", "127.0.0.1", "192.168.1.1", "8.8.8.8", "0.0.0.0",
                 "[::1]", "[2001:db8::1]", "[::ffff:192.0.2.1]", "[1:2:3:4:5:6:7:8]"]:
      check parseGs1DigitalLink("https://" & host & "/01/" & gtin).primary == primary
    check normalizeGs1DigitalLink("HTTP://LOCALHOST:080/01/" & gtin) == "http://localhost/01/" & gtin
    check validateGs1DigitalLink("http://localhost/01/" & gtin)["warnings"][0]["code"].getStr == "GS1_DIGITAL_LINK_HTTP"
  test "ambiguous IPv4 aliases include empty hexadecimal digits":
    for host in ["0x", "0X", "1.0x", "example.0x", "0x.", "1.0X", "1.2.3.0x",
                 "0x7f000001", "0177.0.0.1", "127.1", "2130706433", "127.0.0.01",
                 "1.2.3.256", "1.2.3.4.", "example.123", "example.0xff"]:
      let input = "https://" & host & "/01/" & gtin
      expectCode("GS1_DIGITAL_LINK_UNSUPPORTED_HOST"): discard parseGs1DigitalLink(input)
      expectCode("GS1_DIGITAL_LINK_UNSUPPORTED_HOST"): discard normalizeGs1DigitalLink(input)
      check not validateGs1DigitalLink(input)["ok"].getBool
  test "credentials non-ASCII zones malformed DNS and IPv6 are rejected":
    for host in ["user:password@example.com", "user@example.com", "例.jp", "%65xample.com",
                 "a..example", "-bad.example", "bad-.example", "bad_name.example", "",
                 "[::1%25eth0]", "[1:2:3:4:5:6:7]", "[1:2:3:4:5:6:7:8:9]", "[:::]",
                 "[1::2::3]", "[::ffff:192.000.2.1]", "[1.2.3.4::]", "[::1]oops"]:
      expectCode("GS1_DIGITAL_LINK_UNSUPPORTED_HOST"):
        discard parseGs1DigitalLink("https://" & host & "/01/" & gtin)
  test "port range grammar default canonicalization":
    for port in ["", "-1", "+443", "65536", "123456", "a", "443:80"]:
      expectCode("GS1_DIGITAL_LINK_INVALID_URI"):
        discard parseGs1DigitalLink("https://example.com:" & port & "/01/" & gtin)
    check normalizeGs1DigitalLink("https://example.com:00443/01/" & gtin) ==
        "https://example.com/01/" & gtin
    check normalizeGs1DigitalLink("https://example.com:00000/01/" & gtin) ==
        "https://example.com:0/01/" & gtin
    check normalizeGs1DigitalLink("https://example.com:65535/01/" & gtin) ==
        "https://example.com:65535/01/" & gtin
  test "fragments invalid schemes raw whitespace and backslashes fail":
    expectCode("GS1_DIGITAL_LINK_FRAGMENT_NOT_ALLOWED"):
      discard parseGs1DigitalLink("https://example.com/01/" & gtin & "#x")
    for input in ["ftp://example.com/01/" & gtin, "//example.com/01/" & gtin,
                  "https://example.com\\x/01/" & gtin, " https://example.com/01/" & gtin,
                  "https://example.com/01/" & gtin & "?x=raw space"]:
      expectCode("GS1_DIGITAL_LINK_INVALID_URI"): discard parseGs1DigitalLink(input)
