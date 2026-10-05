import std/[json, options, os]
import specqr/[gs1,errors]
proc text(n: JsonNode; key: string; fallback=""): string =
  if n.hasKey(key): n[key].getStr else: fallback
proc flag(n: JsonNode; key: string; fallback=false): bool =
  if n.hasKey(key): n[key].getBool else: fallback
proc run(f: JsonNode): JsonNode =
  let op=f["op"].getStr
  let input=f.text("input")
  let o=if f.hasKey("options"): f["options"] else: newJObject()
  var elements: seq[GS1Element]
  if f.hasKey("elements"):
    for e in f["elements"]: elements.add GS1Element(ai:e.text("ai"),value:e.text("value"))
  var paths: seq[string]
  if o.hasKey("pathAis"):
    for v in o["pathAis"]: paths.add v.getStr
  try:
    case op
    of "dictionary": return %getSupportedGs1Ais()
    of "info":
      let info=getGs1AiInfo(input)
      return if info.isSome: %info.get else: newJNull()
    of "checkDigit": return %calculateGs1CheckDigit(input)
    of "validateCheckDigit": return %validateGs1CheckDigit(input)
    of "gtinDigit": return %calculateGtinCheckDigit(input)
    of "gtinAppend": return %appendGtinCheckDigit(input)
    of "gtinValidate": return %validateGtinCheckDigit(input)
    of "ssccDigit": return %calculateSsccCheckDigit(input)
    of "ssccAppend": return %appendSsccCheckDigit(input)
    of "ssccValidate": return %validateSsccCheckDigit(input)
    of "human": return %parseGs1HumanReadable(input)
    of "raw": return %parseGs1ElementString(input)
    of "create": return %createGs1ElementString(elements)
    of "validateElements": return validateGs1Elements(elements,o.text("context","element-string"),o.flag("collectAllErrors",true),o.flag("allowUnsupportedAi"))
    of "validateRaw": return validateGs1ElementString(input,o.text("context","element-string"),o.flag("collectAllErrors",true),o.flag("allowUnsupportedAi"))
    of "linkCreate": return %createGs1DigitalLink(elements,o.text("baseUrl","https://id.gs1.org"),o.text("primaryAi","01"),paths,o.hasKey("pathAis"))
    of "linkParse": return %parseGs1DigitalLink(input,o.text("primaryAi"),o.text("unknownQuery","preserve"))
    of "linkValidate": return validateGs1DigitalLink(input,o.text("primaryAi"),o.text("unknownQuery","preserve"),o.flag("normalize"))
    of "linkNormalize": return %normalizeGs1DigitalLink(input,o.text("primaryAi"),o.text("unknownQuery","preserve"),o.text("mode","specqr-deterministic"))
    else: raise newException(ValueError,"unsupported op")
  except SpecQRError as e: return %*{"throws":{"code":e.code,"message":e.msg,"detailCode":e.detailCode}}
let fixture=parseFile(paramStr(1))
var results=newJArray()
for f in fixture["cases"]: results.add run(f)
echo $results
