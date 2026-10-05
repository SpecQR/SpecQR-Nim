import std/[json, os]
import ./protocol
const LineBudget = 16*1024*1024
proc readBoundedLine(line:var string; oversized:var bool):bool =
  line.setLen(0);oversized=false
  while not stdin.endOfFile:
    let c=stdin.readChar()
    result=true
    if c=='\n':break
    if line.len<LineBudget:line.add(c)
    else:oversized=true
proc boundedDepth(line:string):bool =
  var depth=0;var quoted=false;var escaped=false
  for c in line:
    if quoted:
      if escaped:escaped=false
      elif c=='\\':escaped=true
      elif c=='"':quoted=false
    elif c=='"':quoted=true
    elif c in {'[','{'}:
      inc depth
      if depth>64:return false
    elif c in {']','}'}:dec depth
  true
if "--runtime" in commandLineParams():
  echo $(%*{"nim":NimVersion,"os":hostOS,"arch":hostCPU,"wordSize":sizeof(int)*8})
  quit(0)
var line:string;var oversized:bool
while readBoundedLine(line,oversized):
  if oversized or not boundedDepth(line):
    echo $(%*{"error":"SpecQRError","isSpecQRError":true,"code":"INVALID_INPUT","message":"JSON input resource limit"})
  else:
    try:echo $runRequest(parseJson(line))
    except CatchableError:
      echo $(%*{"error":"SpecQRError","isSpecQRError":true,"code":"INVALID_INPUT","message":"Malformed JSON"})
