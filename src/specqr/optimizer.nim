## Exact linear-time dynamic programming with residue-class monotonic queues.
import std/[unicode, algorithm]
import ./[errors, tables, segments]
type
  OptQueue = object
    values:seq[int]
    head:int
  SegmentOptimizationTracker* = object
    version:int
    allowKanji:bool
    offsets,costs,counts,previous,chosen:seq[int]
    queues:array[4,array[3,OptQueue]]
    keys:array[4,seq[int]]
    widths:array[4,int]
proc newSegmentOptimizationTracker*(version=1;allowKanji=true):SegmentOptimizationTracker =
  validateVersion(version)
  result.version=version;result.allowKanji=allowKanji
  result.offsets= @[0];result.costs= @[0];result.counts= @[0];result.previous= @[0];result.chosen= @[0]
  for i,m in DataModes:result.widths[i]=characterCountBits(version,m)
proc base(t:SegmentOptimizationTracker;m,at:int):int =
  case m
  of 0:10*(at div 3)
  of 1:11*(at div 2)
  of 2:13*at
  else:8*t.offsets[at]
proc eligible(c:Rune;m:int;allowKanji:bool):bool =
  case m
  of 0:int(c) in ord('0')..ord('9')
  of 1:alphaValue(c)>=0
  of 2:allowKanji and canEncodeKanji(c)
  else:true
proc payload(t:SegmentOptimizationTracker;m,a,b:int):int =
  let n=b-a
  case m
  of 0:10*(n div 3)+[0,4,7][n mod 3]
  of 1:11*(n div 2)+6*(n mod 2)
  of 2:13*n
  else:8*(t.offsets[b]-t.offsets[a])
proc optCount(t:SegmentOptimizationTracker;m,a,b:int):int =
  if m==3:t.offsets[b]-t.offsets[a] else:b-a
proc appendCharacter*(t:var SegmentOptimizationTracker;c:Rune):int =
  let cp=int(c)
  if cp<0 or cp>0x10ffff or cp in 0xd800..0xdfff:fail("INVALID_INPUT","Expected Unicode scalar")
  if t.costs.len==0:fail("INVALID_INPUT","Uninitialized tracker")
  let n=t.costs.len
  if n>MaxPayloadUnits:fail("DATA_TOO_LONG","Optimizer resource limit exceeded")
  let width=if cp<128:1 elif cp<2048:2 elif cp<65536:3 else:4
  t.offsets.add(t.offsets[^1]+width)
  var bestCost=high(int);var bestCount=high(int);var bestMode= -1;var bestStart=0
  for m in 0..<4:
    let start=n-1
    let key=t.costs[start]-t.base(m,start)
    t.keys[m].add(key)
    if not eligible(c,m,t.allowKanji):
      for lane in 0..<3:t.queues[m][lane]=OptQueue()
      continue
    let lanes=if m==0:3 elif m==1:2 else:1
    let lane=start mod lanes
    while t.queues[m][lane].values.len>t.queues[m][lane].head:
      let j=t.queues[m][lane].values[^1]
      if t.keys[m][j]>key or (t.keys[m][j]==key and t.counts[j]>t.counts[start]):
        discard t.queues[m][lane].values.pop()
      else:break
    t.queues[m][lane].values.add(start)
    let limit=(1 shl t.widths[m])-1
    for k in 0..<lanes:
      while t.queues[m][k].head<t.queues[m][k].values.len and t.optCount(m,t.queues[m][k].values[t.queues[m][k].head],n)>limit:
        inc t.queues[m][k].head
      if t.queues[m][k].head>=t.queues[m][k].values.len:continue
      let j=t.queues[m][k].values[t.queues[m][k].head]
      let cost=t.costs[j]+4+t.widths[m]+t.payload(m,j,n)
      let count=t.counts[j]+1
      if cost<bestCost or (cost==bestCost and count<bestCount):
        bestCost=cost;bestCount=count;bestMode=m;bestStart=j
  if bestMode<0:fail("INVALID_INPUT","No segmentation path")
  t.costs.add(bestCost);t.counts.add(bestCount);t.chosen.add(bestMode);t.previous.add(bestStart)
  bestCost
proc appendCharacter*(t:var SegmentOptimizationTracker;c:string):int =
  let scalars=strictUtf8(c)
  if scalars.len!=1:fail("INVALID_INPUT","Expected one Unicode scalar")
  t.appendCharacter(scalars[0])
proc optimalBits*(t:SegmentOptimizationTracker):int =
  if t.costs.len==0:fail("INVALID_INPUT","Uninitialized tracker")
  t.costs[^1]
proc optimizeSegments*(text:string;version=1;allowKanji=true):seq[Segment] =
  let scalars=strictUtf8(text)
  if scalars.len>MaxSingleSymbolCharacters:fail("DATA_TOO_LONG","Optimized single-symbol input exceeds 7089 scalars")
  var t=newSegmentOptimizationTracker(version,allowKanji)
  if scalars.len==0:return @[byteSegment("")]
  for c in scalars:discard t.appendCharacter(c)
  var n=scalars.len
  while n>0:
    let j=t.previous[n];let mode=t.chosen[n]
    result.add(newSegment(DataModes[mode],text[t.offsets[j]..<t.offsets[n]]))
    n=j
  result.reverse()
proc createSegments*(input:string;mode="auto";version=1;optimize=true;eciAssignment= -1;allowKanji=true):seq[Segment] =
  validateVersion(version)
  if mode!="auto" and mode notin DataModes:fail("INVALID_MODE","Unsupported data mode")
  let scalars=strictUtf8(input)
  if eciAssignment>=0:result.add(eci(eciAssignment))
  elif eciAssignment!= -1:fail("INVALID_ECI","Invalid ECI assignment")
  if mode!="auto":result.add(newSegment(mode,input))
  elif optimize:result.add(optimizeSegments(input,version,allowKanji and eciAssignment<0))
  else:
    var numeric=true;var alpha=true;var isKanji=allowKanji and eciAssignment<0
    for c in scalars:
      numeric=numeric and int(c) in ord('0')..ord('9')
      alpha=alpha and alphaValue(c)>=0
      isKanji=isKanji and canEncodeKanji(c)
    let selected=if scalars.len>0 and numeric:"numeric" elif scalars.len>0 and alpha:"alphanumeric" elif scalars.len>0 and isKanji:"kanji" else:"byte"
    result.add(newSegment(selected,input))
proc createSegments*(input:openArray[uint8];mode="auto";version=1;optimize=true;eciAssignment= -1;allowKanji=true):seq[Segment] =
  validateVersion(version)
  if mode notin ["auto","byte"]:fail("INVALID_MODE","Binary input requires byte mode")
  if eciAssignment>=0:result.add(eci(eciAssignment))
  elif eciAssignment!= -1:fail("INVALID_ECI","Invalid ECI assignment")
  result.add(byteSegment(input))
