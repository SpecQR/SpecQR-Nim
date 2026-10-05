## Stable error categories for all public validation boundaries.
import std/[json, math]

type SpecQRError* = object of CatchableError
  code*: string
  detailCode*: string
proc fail*(code, message: string) {.noreturn.} =
  var e = newException(SpecQRError, message)
  e.code = code
  raise e
proc requireRange*(n, lo, hi: int; label: string; code = "INVALID_INPUT"): int =
  if n < lo or n > hi: fail(code, label & " is outside its supported range")
  n

# JSON is used only for structured diagnostics and decoded-part boundaries.
# Public result objects are value types; reject caller-created nil/cyclic trees
# rather than letting std/json.copy dereference them or overflow the call stack.
proc copyJsonChecked*(node: JsonNode): JsonNode =
  var visited = 0
  proc copyNode(n: JsonNode; depth: int): JsonNode =
    inc visited
    if n.isNil or depth > 64 or visited > 1_000_000:
      fail("INVALID_INPUT", "Diagnostics must be a bounded, non-nil JSON tree")
    case n.kind
    of JNull: result = newJNull()
    of JBool: result = %n.getBool
    of JInt: result = %n.getBiggestInt
    of JFloat:
      if classify(n.getFloat) in {fcNan, fcInf, fcNegInf}:fail("INVALID_INPUT", "Diagnostics must contain finite numbers")
      result = %n.getFloat
    of JString:
      if n.getStr.len > 4_000_000:fail("INVALID_INPUT", "Diagnostics string exceeds budget")
      result = %n.getStr
    of JArray:
      result = newJArray()
      for item in n:result.add(copyNode(item, depth + 1))
    of JObject:
      result = newJObject()
      for key, value in n:result[key] = copyNode(value, depth + 1)
  copyNode(node, 0)
