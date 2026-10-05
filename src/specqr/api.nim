## Native planning and generation. Planning never builds codewords or matrices.
import std/[json, options, math]
import ./[errors, tables, core, segments, optimizer, render, gs1]
type
  Options* = object
    errorCorrectionLevel*:string = "M"
    version*:int = 0 ## 0 selects the smallest fitting version in minVersion..maxVersion.
    minVersion*:int = 1
    maxVersion*:int = 40
    maskPattern*:int = -1 ## -1 chooses the lowest penalty; ties use the first mask.
    mode*:string = "auto"
    optimizeSegments*:bool = true
    allowKanji*:bool = true
    boostErrorCorrection*:bool = false
    eciAssignment*:int = -1 ## -1 disables ECI; 26 labels UTF-8; no transcoding.
    gs1*,fnc1*:bool = false
    fnc1Second*:string = ""
    structuredAppend*:Option[Segment]
    margin*:int = 4
    scale*:int = 8
    foreground*:string = "#000000"
    background*:string = "#ffffff"
    printDpi*:Option[float]
  Capacity* = object
    version*,size*,dataCodewords*,totalCodewords*,capacityBits*:int
    errorCorrectionLevel*,mode*:string
    characterCountBits*,modeIndicatorBits*,controlBits*,payloadBits*,maximum*:int
  Plan* = object
    ok*:bool
    version*:int ## 0 for an unsuccessful automatic-range plan.
    capacityVersion*:int
    errorCorrectionLevel*,requestedErrorCorrectionLevel*:string
    boostedErrorCorrection*:bool
    dataBitLength*,capacityBits*,remainingBits*:int
    segments*:seq[Segment]
    diagnostics*:JsonNode
  QRResult* = object
    matrix*:Matrix
    version*,maskPattern*:int
    errorCorrectionLevel*:string
    dataCodewords*,codewords*:seq[uint8]
    segments*:seq[Segment]
    diagnostics*:JsonNode
    options*:Options
proc validateOptions*(o:Options) =
  discard levelIndex(o.errorCorrectionLevel)
  validateVersion(o.minVersion);validateVersion(o.maxVersion)
  if o.minVersion>o.maxVersion:fail("INVALID_VERSION","minVersion must not exceed maxVersion")
  if o.version!=0:validateVersion(o.version)
  discard requireRange(o.maskPattern,-1,7,"Mask")
  if o.mode!="auto" and o.mode notin DataModes:fail("INVALID_MODE","Unsupported data mode")
  discard requireRange(o.eciAssignment,-1,999999,"ECI assignment","INVALID_ECI")
  if o.fnc1Second!="":discard fnc1Second(o.fnc1Second)
  if o.structuredAppend.isSome and o.structuredAppend.get.mode!="structured-append":fail("INVALID_MODE","Structured append requires a header")
  if int(o.gs1 or o.fnc1)+int(o.fnc1Second!="")+int(o.eciAssignment>=0)+int(o.structuredAppend.isSome)>1:fail("INVALID_MODE","FNC1, ECI, and SA controls cannot be combined")
  discard requireRange(o.margin,0,MaxGeometryInteger,"Margin")
  discard requireRange(o.scale,1,MaxGeometryInteger,"Scale")
  discard parseColor(o.foreground,false);discard parseColor(o.background,false)
  if o.printDpi.isSome:
    let d=o.printDpi.get
    let mm=(177.0+2.0*float(o.margin))*(float(o.scale)/d*25.4)
    if classify(d) in {fcNan,fcInf,fcNegInf} or d<=0 or classify(mm) in {fcNan,fcInf,fcNegInf} or mm<=0:fail("INVALID_INPUT","DPI must produce finite positive print geometry")
proc renderOptions*(o:Options):RenderOptions=RenderOptions(margin:o.margin,scale:o.scale,foreground:o.foreground,background:o.background)
proc getCapacity*(version:int;errorCorrectionLevel="M";mode="";controlBits=0):Capacity =
  validateVersion(version);discard levelIndex(errorCorrectionLevel)
  discard requireRange(controlBits,0,high(int),"Control bits")
  let data=dataCodewordCount(version,errorCorrectionLevel)
  result=Capacity(version:version,size:qrSize(version),dataCodewords:data,totalCodewords:rawCodewordCount(version),capacityBits:data*8,errorCorrectionLevel:errorCorrectionLevel,mode:mode,controlBits:controlBits,characterCountBits: -1,modeIndicatorBits: -1,payloadBits: -1,maximum: -1)
  if mode!="":
    let width=characterCountBits(version,mode)
    let available=if controlBits>data*8:0 else:max(0,data*8-controlBits-4-width)
    var maximum=case mode
      of "numeric":available div 10*3+(if available mod 10>=7:2 elif available mod 10>=4:1 else:0)
      of "alphanumeric":available div 11*2+int(available mod 11>=6)
      of "byte":available div 8
      else:available div 13
    maximum=min(maximum,(1 shl width)-1)
    result.characterCountBits=width;result.modeIndicatorBits=4;result.payloadBits=available;result.maximum=maximum
proc segmentDiagnostic(s:Segment;v:int):JsonNode =
  %*{"mode":s.mode,"character_count":s.characterCount,"byte_count":s.byteCount,"count":s.count,"bit_length":s.bitLength(v)}
proc apiDiagnostics(segments:seq[Segment];v:int;level:string;required:int;o:Options;planning,ok:bool):JsonNode =
  let capacity=8*dataCodewordCount(v,level)
  var control=newJArray();var data=newJArray();var modes:seq[string];var inputBytes=0
  var ec= -1;var fn="";var second=none(Segment);var sa=none(Segment)
  for s in segments:
    data.add(segmentDiagnostic(s,v));inputBytes+=s.logicalBytes.len
    if s.isControl:control.add(segmentDiagnostic(s,v))
    elif s.mode notin modes:modes.add(s.mode)
    if s.mode=="eci" and ec<0:ec=s.assignmentNumber
    if s.mode=="fnc1":fn="first-position"
    if s.mode=="fnc1-second":fn="second-position";second=some(s)
    if s.mode=="structured-append":sa=some(s)
  let mode=if modes.len==0:"byte" elif modes.len==1:modes[0] else:"mixed"
  var warnings=newJArray()
  proc warn(code,severity,message:string;details:JsonNode=newJObject()) = warnings.add(%*{"code":code,"severity":severity,"message":message,"details":details})
  if o.margin<4:warn("QUIET_ZONE_TOO_SMALL","warning","QR readers expect at least four quiet-zone modules.",%*{"margin":o.margin})
  let fg=parseColor(o.foreground,false);let bg=parseColor(o.background,false)
  var ratio=newJNull()
  if fg.isSome and bg.isSome:
    let r=contrastRatio(fg.get,bg.get);ratio= %r
    if r<4.5:warn("COLOR_CONTRAST_LOW","warning","Color contrast is below the recommended minimum.",%*{"ratio":r})
    elif r<7:warn("COLOR_CONTRAST_MODERATE","info","Stronger color contrast is recommended.",%*{"ratio":r})
    if fg.get[3]<255 or bg.get[3]<255:warn("COLOR_ALPHA_USED","warning","Transparent colors can reduce scan reliability.")
  else:warn("COLOR_CONTRAST_UNKNOWN","info","These SVG colors cannot be checked for contrast.")
  if capacity-required>=0 and float(capacity-required)<float(capacity)*0.05:warn("CAPACITY_NEAR_LIMIT","info","The selected version is close to full capacity.")
  var mm=newJNull();var symbolMm=newJNull()
  if o.printDpi.isSome:
    let m=float(o.scale)/o.printDpi.get*25.4;mm= %m;symbolMm= %((float(qrSize(v))+2.0*float(o.margin))*m)
    if m<0.25:warn("PRINT_MODULE_TOO_SMALL","warning","Print modules are smaller than 0.25 mm.",%*{"module_size_mm":m})
  var blocking=newJArray()
  for w in warnings:
    if w["severity"].getStr=="warning":blocking.add(w["code"])
  if blocking.len>0:warn("SCAN_RISK","warning","One or more settings may reduce scan reliability.",%*{"blocking_warnings":blocking})
  let selection=if o.version!=0:"fixed" elif ok:"auto-minimum" else:"auto-range"
  let reason=if o.version!=0:"Version " & $v & " was requested explicitly." elif ok:"Version " & $v & " is the smallest version in " & $o.minVersion & ".." & $o.maxVersion & " that fits." else:"No version in " & $o.minVersion & ".." & $o.maxVersion & " fits; capacity is for version " & $v & "."
  result= %*{"phase":(if planning:"planning" else:"generation"),"render_planned":false,"mask_evaluated":not planning,"codewords_built":not planning,"ok":ok,"capacity_version":v,"error_correction_level":level,"requested_error_correction_level":o.errorCorrectionLevel,"boosted_error_correction":level!=o.errorCorrectionLevel,"version_selection":selection,"version_selection_reason":reason,"mode":mode,"control_segments":control,"segments":data,"data_bit_length":required,"capacity_bits":capacity,"remaining_bits":capacity-required,"overflow_bits":max(0,required-capacity),"capacity_utilization":float(required)/float(capacity),"input_bytes":inputBytes,"gs1":fn=="first-position","gs1_validation":{"enabled":false,"element_count":0,"ais":newJArray(),"has_separators":false},"warnings":warnings}
  result["version"]=if ok or o.version!=0: %v else:newJNull()
  result["size"]=if ok or o.version!=0: %qrSize(v) else:newJNull()
  result["eci_assignment_number"]=if ec>=0: %ec else:newJNull()
  result["fnc1"]=if fn!="": %fn else:newJNull()
  result["fnc1_second"]= %*{"enabled":second.isSome,"application_indicator":(if second.isSome: %second.get.applicationIndicator else:newJNull()),"application_indicator_codeword":(if second.isSome: %second.get.applicationIndicatorCodeword else:newJNull())}
  result["structured_append"]= %*{"enabled":sa.isSome}
  for field in ["index","total","parity","sequence_index","sequence_total","sequence_indicator"]:result["structured_append"][field]=newJNull()
  if sa.isSome:
    let s=sa.get
    result["structured_append"]= %*{"enabled":true,"index":s.index,"total":s.total,"parity":s.parity,"sequence_index":s.index-1,"sequence_total":s.total-1,"sequence_indicator":((s.index-1) shl 4) or (s.total-1)}
  result["quiet_zone"]= %*{"modules":o.margin,"recommended_modules":4,"is_sufficient":o.margin>=4}
  result["colors"]= %*{"ratio":ratio,"is_inspectable":ratio.kind!=JNull,"foreground_alpha":(if fg.isSome: %fg.get[3] else:newJNull()),"background_alpha":(if bg.isSome: %bg.get[3] else:newJNull()),"is_strong":ratio.kind!=JNull and ratio.getFloat>=7,"is_sufficient":ratio.kind!=JNull and ratio.getFloat>=4.5 and fg.get[3]==255 and bg.get[3]==255}
  result["print"]= %*{"dpi":(if o.printDpi.isSome: %o.printDpi.get else:newJNull()),"module_pixels":o.scale,"module_size_mm":mm,"symbol_size_mm":symbolMm,"recommended_minimum_module_size_mm":0.25,"is_module_size_sufficient":(if mm.kind!=JNull: %(mm.getFloat>=0.25) else:newJNull())}
proc addControls(data:seq[Segment];o:Options):seq[Segment] =
  if o.eciAssignment>=0:result.add(eci(o.eciAssignment))
  elif o.gs1 or o.fnc1:result.add(fnc1())
  elif o.fnc1Second!="":result.add(fnc1Second(o.fnc1Second))
  elif o.structuredAppend.isSome:result.add(o.structuredAppend.get)
  result.add(data);result=normalizeSegments(result)
proc selectPlan(factory:proc(v:int):seq[Segment] {.closure.};o:Options):Plan =
  o.validateOptions()
  let lo=if o.version==0:o.minVersion else:o.version
  let hi=if o.version==0:o.maxVersion else:o.version
  var cache:array[3,seq[Segment]];var used:array[3,bool];var required:array[3,int];var fitCounts:array[3,bool]
  var v=hi;var data:seq[Segment];var req=0;var ok=false
  for candidate in lo..hi:
    let g=if candidate<=9:0 elif candidate<=26:1 else:2
    if not used[g]:
      cache[g]=factory(candidate);used[g]=true
      required[g]=segmentsBitLength(cache[g],candidate);fitCounts[g]=true
      for s in cache[g]:
        if not s.isControl and s.count>=(1 shl characterCountBits(candidate,s.mode)):fitCounts[g]=false
    v=candidate;data=cache[g];req=required[g]
    ok=fitCounts[g] and req<=8*dataCodewordCount(v,o.errorCorrectionLevel)
    if ok:break
  var level=o.errorCorrectionLevel
  if ok and o.boostErrorCorrection:
    for i in levelIndex(level)..3:
      if req<=8*dataCodewordCount(v,ErrorCorrectionLevels[i]):level=ErrorCorrectionLevels[i]
  let capacity=8*dataCodewordCount(v,level)
  result=Plan(ok:ok,version:(if ok or o.version!=0:v else:0),capacityVersion:v,errorCorrectionLevel:level,requestedErrorCorrectionLevel:o.errorCorrectionLevel,boostedErrorCorrection:level!=o.errorCorrectionLevel,dataBitLength:req,capacityBits:capacity,remainingBits:capacity-req,segments:data,diagnostics:apiDiagnostics(data,v,level,req,o,true,ok))
proc plan*(value:string;o=Options()):Plan =
  o.validateOptions()
  let scalars=strictUtf8(value)
  var validation=newJNull()
  if o.gs1:
    let parsed=parseGs1ElementString(value)
    var ais=newJArray()
    for e in parsed.elements:ais.add(%e.ai)
    validation= %*{"enabled":true,"element_count":parsed.elements.len,"ais":ais,"has_separators":value.contains('\x1d')}
  var mode=o.mode
  if (o.gs1 or o.fnc1 or o.fnc1Second!="") and value.contains('%'):
    if mode=="alphanumeric":fail("INVALID_MODE","High-level FNC1 literal percent requires byte mode; manual alpha data is already escaped")
    if mode=="auto":mode="byte"
  result=selectPlan(proc(v:int):seq[Segment]=addControls(createSegments(value,mode,v,o.optimizeSegments and scalars.len<=MaxSingleSymbolCharacters,-1,o.allowKanji and o.eciAssignment<0),o),o)
  if validation.kind!=JNull:result.diagnostics["gs1_validation"]=validation
proc plan*(value:openArray[uint8];o=Options()):Plan =
  o.validateOptions()
  if o.gs1:fail("INVALID_GS1","High-level GS1 requires text")
  let owned= @value
  result=selectPlan(proc(v:int):seq[Segment]=addControls(createSegments(owned,o.mode,v,o.optimizeSegments,-1,o.allowKanji),o),o)
proc planSegments*(values:openArray[Segment];o=Options()):Plan =
  o.validateOptions()
  if o.gs1:fail("INVALID_GS1","Manual GS1 requires an explicit FNC1 segment")
  let found=addControls(normalizeSegments(values),o)
  selectPlan(proc(v:int):seq[Segment]=found,o)
proc build(p:Plan;o:Options):QRResult =
  o.validateOptions()
  if not p.ok:fail("DATA_TOO_LONG","Input does not fit the selected QR capacity")
  let v=p.capacityVersion;let level=p.errorCorrectionLevel
  let data=padDataBits(segmentsBits(p.segments,v),v,level)
  let inter=interleaveCodewords(data,v,level)
  let built=buildMatrix(inter.codewords,v,level,o.maskPattern)
  var d=apiDiagnostics(p.segments,v,level,p.dataBitLength,o,false,true)
  d["gs1_validation"]=p.diagnostics["gs1_validation"].copy()
  d["mask_pattern"]= %built.maskPattern;d["mask_penalty"]= %built.penalty
  d["mask_penalties"]=newJArray()
  for x in built.maskPenalties:d["mask_penalties"].add(%*{"mask_pattern":x.maskPattern,"penalty":x.penalty})
  d["mask_selection_reason"]= %(if o.maskPattern<0:"Lowest penalty; first mask wins ties." else:"Explicit mask requested.")
  d["data_codewords"]= %data.len;d["error_correction_codewords"]= %(inter.codewords.len-data.len);d["total_codewords"]= %inter.codewords.len
  QRResult(matrix:built.matrix,version:v,maskPattern:built.maskPattern,errorCorrectionLevel:level,dataCodewords:data,codewords:inter.codewords,segments:p.segments,diagnostics:d,options:o)
proc generate*(value:string;o=Options()):QRResult=build(plan(value,o),o)
proc generate*(value:openArray[uint8];o=Options()):QRResult=build(plan(value,o),o)
proc generateSegments*(values:openArray[Segment];o=Options()):QRResult=build(planSegments(values,o),o)
proc generate*(values:openArray[Segment];o=Options()):QRResult=generateSegments(values,o)
proc plan*(values:openArray[Segment];o=Options()):Plan=planSegments(values,o)
proc estimate*[T](value:T;o=Options()):Plan=plan(value,o)
proc analyzeSegments*(values:openArray[Segment];o=Options()):Plan=planSegments(values,o)
proc diagnostics*(q:QRResult):JsonNode =
  if q.diagnostics.isNil:fail("INVALID_INPUT","Uninitialized diagnostics result")
  copyJsonChecked(q.diagnostics)
proc diagnostics*(p:Plan):JsonNode =
  if p.diagnostics.isNil:fail("INVALID_INPUT","Uninitialized diagnostics result")
  copyJsonChecked(p.diagnostics)
proc size*(q:QRResult):int=q.matrix.len
proc moduleAt*(q:QRResult;x,y:int):bool =
  validateMatrix(q.matrix)
  discard requireRange(x,0,q.size-1,"Column");discard requireRange(y,0,q.size-1,"Row")
  q.matrix[y][x]
proc toSvg*(q:QRResult):string=toSvg(q.matrix,q.options.renderOptions)
proc toSvg*(q:QRResult;o:RenderOptions):string=toSvg(q.matrix,o)
proc toPng*(q:QRResult):seq[uint8]=toPng(q.matrix,q.options.renderOptions)
proc toPng*(q:QRResult;o:RenderOptions):seq[uint8]=toPng(q.matrix,o)
proc toPixels*(q:QRResult):Pixels=toPixels(q.matrix,q.options.renderOptions)
proc toPixels*(q:QRResult;o:RenderOptions):Pixels=toPixels(q.matrix,o)
proc toSvgDataUrl*(q:QRResult):string=toSvgDataUrl(q.matrix,q.options.renderOptions)
proc toPngDataUrl*(q:QRResult):string=toPngDataUrl(q.matrix,q.options.renderOptions)
