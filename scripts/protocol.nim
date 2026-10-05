## Development-only JSON adapter. All encoding is performed by native SpecQR.
import std/[json, math, strutils, base64, options]
import specqr
import ./gs1_fixture
proc bad(message:string) {.noreturn.}=fail("INVALID_INPUT",message)
proc field(r:JsonNode;key:string;fallback:JsonNode=newJNull()):JsonNode =
  if r.kind!=JObject:bad("Expected object")
  if r.hasKey(key):r[key] else:fallback
proc textValue(x:JsonNode):string =
  if x.kind!=JString:bad("Expected string")
  x.getStr
proc integer(x:JsonNode):int =
  if x.kind==JInt:
    let n=x.getBiggestInt
    if n<int64(low(int)) or n>int64(high(int)):bad("Integer out of range")
    return int(n)
  if x.kind==JFloat:
    let v=x.getFloat
    if classify(v) in {fcNan,fcInf,fcNegInf} or floor(v)!=v or v<float(low(int)) or v>=float(high(int)):bad("Expected native-range integer")
    return int(v)
  bad("Expected integer")
proc boolean(x:JsonNode):bool =
  if x.kind!=JBool:bad("Expected boolean")
  x.getBool
proc bytesValue(x:JsonNode):seq[uint8] =
  if x.kind!=JArray:bad("Expected byte array")
  if x.len>MaxPayloadUnits:fail("DATA_TOO_LONG","Payload resource limit exceeded")
  for b in x:result.add(uint8(requireRange(integer(b),0,255,"Byte")))
proc wireSegment*(raw:JsonNode):Segment =
  let m=textValue(raw.field("mode"))
  let value=raw.field("text",raw.field("data"))
  case m
  of "numeric","alphanumeric","kanji":newSegment(m,textValue(value))
  of "byte":
    if raw.hasKey("bytes"):byteSegment(bytesValue(raw["bytes"]))
    elif value.kind==JArray:byteSegment(bytesValue(value))
    else:byteSegment(textValue(value))
  of "eci":eci(integer(raw.field("assignmentNumber")))
  of "fnc1":fnc1()
  of "fnc1-second":fnc1Second(textValue(raw.field("applicationIndicator")))
  of "structured-append":structuredAppendSegment(integer(raw.field("index")),integer(raw.field("total")),integer(raw.field("parity")))
  else:fail("INVALID_MODE","Unknown segment mode")
proc wireOptions*(raw:JsonNode):Options =
  if raw.kind!=JObject:bad("Options must be an object")
  result=Options()
  for key,v in raw:
    case key
    of "errorCorrectionLevel":
      if v.kind!=JString:fail("INVALID_ECC_LEVEL","ECC must be string")
      result.errorCorrectionLevel=v.getStr
    of "version":result.version=if v.kind==JNull or (v.kind==JString and v.getStr=="auto"):0 else:requireRange(integer(v),1,40,"Version","INVALID_VERSION")
    of "minVersion":result.minVersion=integer(v)
    of "maxVersion":result.maxVersion=integer(v)
    of "maskPattern":result.maskPattern=if v.kind==JNull or (v.kind==JString and v.getStr=="auto"): -1 else:requireRange(integer(v),0,7,"Mask")
    of "mode":result.mode=textValue(v)
    of "optimizeSegments":result.optimizeSegments=boolean(v)
    of "allowKanji":result.allowKanji=boolean(v)
    of "boostErrorCorrection":result.boostErrorCorrection=boolean(v)
    of "eci":result.eciAssignment=if v.kind==JNull: -1 elif v.kind==JBool:(if v.getBool:26 else: -1) else:requireRange(integer(v),0,999999,"ECI","INVALID_ECI")
    of "gs1":result.gs1=boolean(v)
    of "fnc1":result.fnc1=boolean(v)
    of "fnc1Second":
      if v.kind!=JNull:
        result.fnc1Second=textValue(v);discard fnc1Second(result.fnc1Second)
    of "structuredAppend":
      if v.kind!=JNull:result.structuredAppend=some(structuredAppendSegment(integer(v.field("index")),integer(v.field("total")),integer(v.field("parity"))))
    of "margin":result.margin=integer(v)
    of "scale":result.scale=integer(v)
    of "foreground":result.foreground=textValue(v)
    of "background":result.background=textValue(v)
    of "printDpi":
      if v.kind!=JNull:
        if v.kind notin {JInt,JFloat}:bad("DPI must be numeric")
        result.printDpi=some(v.getFloat)
    of "maxSymbols":discard # Handled by SA entry point.
    of "output":
      if textValue(v) != "matrix":fail("INVALID_OUTPUT","Reference adapter output must be matrix")
    else:bad("Unknown option: " & key)
  result.validateOptions()
proc rows*(matrix:Matrix):seq[string] =
  for row in matrix:
    var text=newString(row.len)
    for i,b in row:text[i]=if b:'1' else:'0'
    result.add(text)
proc packed(matrix:Matrix):string =
  var data=newSeq[uint8]((matrix.len*matrix.len+7) div 8);var i=0
  for row in matrix:
    for b in row:
      if b:data[i div 8]=data[i div 8] or uint8(1 shl (7-i mod 8))
      inc i
  base64.encode(data)
proc hex(data:openArray[uint8]):string =
  for b in data:result.add(toHex(b,2).toLowerAscii)
proc wireSymbol*(q:QRResult;r:JsonNode=newJObject()):JsonNode =
  result= %*{"version":q.version,"ecc":q.errorCorrectionLevel,"mask":q.maskPattern,"data":hex(q.dataCodewords),"codewords":hex(q.codewords),"matrix":rows(q.matrix),"matrixPacked":packed(q.matrix),"segments":newJArray()}
  for s in q.segments:result["segments"].add(%*{"mode":s.mode,"count":s.count})
  if r.hasKey("pngScale"):
    var ro=q.options.renderOptions;ro.scale=integer(r["pngScale"])
    result["png"]= %hex(toPng(q,ro))
  if r.field("diagnostics",%false).getBool:result["diagnostics"]=q.diagnostics.copy()
  if r.field("renders",%false).getBool:
    result["svg"]= %q.toSvg;result["svgDataUrl"]= %q.toSvgDataUrl;result["pngDataUrl"]= %q.toPngDataUrl
proc elements(raw:JsonNode):seq[GS1Element] =
  if raw.kind!=JArray:bad("Expected GS1 elements array")
  for e in raw:result.add(GS1Element(ai:textValue(e.field("ai")),value:textValue(e.field("value"))))
proc runRequest*(r:JsonNode):JsonNode =
  try:
    let cmdNode=r.field("command",%"generate")
    let command=if cmdNode.kind==JNull:"generate" else:textValue(cmdNode)
    case command
    of "gs1-fixture": return %*{"value":runGs1Fixture(r)}
    of "gf":
      var data:seq[uint8]
      for a in 0..255:
        for b in 0..255:data.add(uint8(gfMultiply(a,b)))
      return %*{"bytes":hex(data)}
    of "rs":
      let degree=integer(r.field("degree"));var data:seq[uint8]
      for i in 0..299:data.add(uint8((i*61+degree) and 255))
      return %*{"generator":hex(reedSolomonDivisor(degree)),"remainder":hex(reedSolomonRemainder(data,degree))}
    of "raw":
      let v=integer(r.field("version"));let ecc=textValue(r.field("ecc"));let seed=requireRange(integer(r.field("seed")),0,31,"Seed");let mask=integer(r.field("mask"));let ordinal=levelIndex(ecc)
      var data:seq[uint8]
      for i in 0..<dataCodewordCount(v,ecc):data.add(uint8(if seed==0:0 elif seed==1:255 else:((i*149+v*43+ordinal*89+seed*67) xor (i shr (seed+1))) and 255))
      let inter=interleaveCodewords(data,v,ecc);let q=buildMatrix(inter.codewords,v,ecc,mask)
      var penalties:seq[int]
      for p in q.maskPenalties:penalties.add(p.penalty)
      return %*{"data":hex(data),"codewords":hex(inter.codewords),"matrix":rows(q.matrix),"matrixPacked":packed(q.matrix),"mask":q.maskPattern,"penalty":q.penalty,"penalties":penalties}
    of "gs1-build":return %*{"value":createGs1ElementString(elements(r.field("elements")))}
    of "digital-link-build":
      let lo=r.field("linkOptions",newJObject());var path:seq[string]
      if lo.hasKey("pathAis"):
        for x in lo["pathAis"]:path.add(textValue(x))
      return %*{"value":createGs1DigitalLink(elements(r.field("elements")),textValue(lo.field("baseUrl",%"https://id.gs1.org")),pathAis=path,explicitPathAis=lo.hasKey("pathAis"))}
    of "digital-link-parse":return %parseGs1DigitalLink(textValue(r.field("url")))
    of "digital-link-validate":return validateGs1DigitalLink(textValue(r.field("url")))
    of "digital-link-normalize":return %*{"value":normalizeGs1DigitalLink(textValue(r.field("url")))}
    else:discard
    var rawopts=r.field("options",newJObject())
    if rawopts.kind==JNull:rawopts=newJObject()
    let o=wireOptions(rawopts)
    if command=="capacity":
      let c=getCapacity(o.version,o.errorCorrectionLevel,o.mode)
      return %*{"maximum":c.maximum,"dataCodewords":c.dataCodewords,"capacityBits":c.capacityBits,"countBits":c.characterCountBits}
    var segs:seq[Segment]
    if r.hasKey("segments"):
      if r["segments"].kind!=JArray:bad("Segments must be array")
      for s in r["segments"]:segs.add(wireSegment(s))
    if command in ["estimate","plan"]:
      let p=if r.hasKey("segments"):planSegments(segs,o) elif r.hasKey("bytes"):plan(bytesValue(r["bytes"]),o) else:plan(textValue(r.field("text",%"")),o)
      return %*{"fits":p.ok,"version":p.capacityVersion,"requiredBits":p.dataBitLength,"capacityBits":p.capacityBits}
    if command=="structured-append":
      if r.hasKey("segments"):
        for key in ["mode","optimizeSegments","allowKanji"]:
          if rawopts.hasKey(key):fail("INVALID_MODE","Manual SA preserves caller modes")
      let maximum=integer(rawopts.field("maxSymbols",%16))
      let sa=if r.hasKey("segments"):generateSegmentsStructuredAppend(segs,o,maximum) elif r.hasKey("bytes"):generateStructuredAppend(bytesValue(r["bytes"]),o,maximum) else:generateStructuredAppend(textValue(r.field("text",%"")),o,maximum)
      var symbols=newJArray();var versions:seq[int];var masks:seq[int]
      for q in sa.symbols:symbols.add(wireSymbol(q,r));versions.add(q.version);masks.add(q.maskPattern)
      return %*{"total":sa.total,"parity":sa.parity,"inputLength":sa.inputLength,"byteLength":sa.byteLength,"symbols":symbols,"versions":versions,"masks":masks}
    if command=="generate":
      let q=if r.hasKey("segments"):generateSegments(segs,o) elif r.hasKey("bytes"):generate(bytesValue(r["bytes"]),o) else:generate(textValue(r.field("text",%"")),o)
      return wireSymbol(q,r)
    bad("Unknown command")
  except SpecQRError as e:
    return %*{"error":"SpecQRError","isSpecQRError":true,"code":e.code,"message":e.msg}
  except CatchableError as e:
    return %*{"error":"UnexpectedError","isSpecQRError":false,"code":"INTERNAL_ERROR","message":e.msg}
