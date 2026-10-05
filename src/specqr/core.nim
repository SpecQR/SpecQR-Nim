## QR Model 2 Reed–Solomon arithmetic, layout, and mask scoring.
import ./[errors, tables]

type
  Matrix* = seq[seq[bool]]
  Block* = object
    data*, ecc*: seq[uint8]
  Interleaved* = object
    codewords*: seq[uint8]
    blocks*: seq[Block]
    dataCodewords*, errorCorrectionCodewords*, totalCodewords*: int
  MatrixResult* = object
    matrix*: Matrix
    maskPattern*, penalty*: int
    maskPenalties*: seq[tuple[maskPattern, penalty: int]]
  Grid = object
    side: int
    modules, functions: Matrix

proc copyMatrix*(a: Matrix): Matrix =
  for row in a:
    var r = newSeq[bool](row.len)
    for i, b in row: r[i] = b
    result.add(r)
proc blankMatrix(n: int): Matrix =
  for y in 0..<n: result.add(newSeq[bool](n))
proc validateMatrix*(m: Matrix) =
  if m.len < 1 or m.len > 177: fail("INVALID_INPUT", "Matrix must be square, 1..177 modules")
  for r in m:
    if r.len != m.len: fail("INVALID_INPUT", "Matrix must be square")
proc checkedBytes(data: openArray[uint8]) =
  if data.len > 3706: fail("INVALID_INPUT", "QR codeword count exceeds 3706")
proc padDataBits*(bits: openArray[int]; version: int; level: string): seq[uint8] =
  let capacity = dataCodewordCount(version, level)
  if bits.len > capacity*8: fail("DATA_TOO_LONG", "Bits exceed data capacity")
  result = newSeq[uint8](capacity)
  for i, b in bits:
    if b notin 0..1: fail("INVALID_INPUT", "Bits must contain only 0 or 1")
    result[i div 8] = result[i div 8] or uint8(b shl (7-i mod 8))
  let terminated = bits.len+min(4, capacity*8-bits.len)
  let paddedBytes = (terminated+7) div 8
  for i in paddedBytes..<capacity: result[i] = if (i-paddedBytes) mod 2 == 0: 0xec'u8 else: 0x11'u8
proc gfMultiplyUnchecked(a, b: int): int =
  var left = a; var right = b
  while right != 0:
    if (right and 1) != 0: result = result xor left
    right = right shr 1
    left = left shl 1
    if (left and 0x100) != 0: left = left xor 0x11d
proc gfMultiply*(a, b: int): int =
  discard requireRange(a, 0, 255, "GF left operand")
  discard requireRange(b, 0, 255, "GF right operand")
  gfMultiplyUnchecked(a, b)
proc reedSolomonDivisor*(degree: int): seq[uint8] =
  discard requireRange(degree, 1, 255, "RS degree")
  result = newSeq[uint8](degree+1); result[0] = 1
  var root = 1
  for factor in 0..<degree:
    for i in countdown(factor+1, 1):
      result[i] = result[i] xor uint8(gfMultiplyUnchecked(int(result[i-1]), root))
    root = gfMultiplyUnchecked(root, 2)
proc remainder(data: openArray[uint8]; divisor: seq[uint8]): seq[uint8] =
  let degree = divisor.len-1
  result = newSeq[uint8](degree)
  for b in data:
    let factor = int(b xor result[0])
    for i in 0..<degree-1: result[i] = result[i+1] xor uint8(gfMultiplyUnchecked(int(divisor[i+1]), factor))
    result[^1] = uint8(gfMultiplyUnchecked(int(divisor[^1]), factor))
proc reedSolomonRemainder*(data: openArray[uint8]; degree: int): seq[uint8] =
  checkedBytes(data)
  remainder(data, reedSolomonDivisor(degree))
proc interleaveCodewords*(data: openArray[uint8]; version: int; level: string): Interleaved =
  let info = blockInfo(version, level)
  checkedBytes(data)
  if data.len != info.dataCodewords: fail("INVALID_INPUT", "Wrong data codeword count")
  let shortCount = info.blocks-info.rawCodewords mod info.blocks
  let shortLength = info.rawCodewords div info.blocks-info.eccPerBlock
  let divisor = reedSolomonDivisor(info.eccPerBlock)
  var offset = 0
  for i in 0..<info.blocks:
    let n = shortLength+int(i >= shortCount)
    let d = @data[offset..<offset+n]
    result.blocks.add(Block(data: d, ecc: remainder(d, divisor)))
    offset+=n
  for col in 0..shortLength:
    for b in result.blocks:
      if col < b.data.len: result.codewords.add(b.data[col])
  for col in 0..<info.eccPerBlock:
    for b in result.blocks: result.codewords.add(b.ecc[col])
  result.dataCodewords = info.dataCodewords
  result.totalCodewords = info.rawCodewords
  result.errorCorrectionCodewords = info.rawCodewords-info.dataCodewords
  if offset != data.len or result.codewords.len != info.rawCodewords: fail("INVALID_INPUT", "Inconsistent interleaving")
proc maskUnchecked(mask, x, y: int): bool =
  case mask
  of 0: (x+y) mod 2 == 0
  of 1: y mod 2 == 0
  of 2: x mod 3 == 0
  of 3: (x+y) mod 3 == 0
  of 4: (y div 2+x div 3) mod 2 == 0
  of 5: x*y mod 2+x*y mod 3 == 0
  of 6: (x*y mod 2+x*y mod 3) mod 2 == 0
  else: ((x+y) mod 2+x*y mod 3) mod 2 == 0
proc maskCondition*(mask, x, y: int): bool =
  discard requireRange(mask, 0, 7, "Mask")
  discard requireRange(x, 0, 176, "Column")
  discard requireRange(y, 0, 176, "Row")
  maskUnchecked(mask, x, y)
proc linePenalty(line: seq[bool]): int =
  var runColor = -1; var runLength = 0; var window = 0
  for i, v in line:
    let value = int(v)
    if value == runColor: inc runLength
    else:
      if runLength >= 5: result+=runLength-2
      runColor = value; runLength = 1
    window = ((window shl 1) or value) and 0x7ff
    if i >= 10 and window in [0b10111010000, 0b00001011101]: result+=40
  if runLength >= 5: result+=runLength-2
proc penaltyScore*(matrix: Matrix): int =
  validateMatrix(matrix)
  let n = matrix.len
  var dark = 0
  for i in 0..<n:
    result+=linePenalty(matrix[i])
    var column = newSeq[bool](n)
    for j in 0..<n:
      column[j] = matrix[j][i]
      dark+=int(matrix[j][i])
    result+=linePenalty(column)
  for y in 0..<n-1:
    for x in 0..<n-1:
      if matrix[y][x] == matrix[y][x+1] and matrix[y][x] == matrix[y+1][x] and matrix[y][x] ==
          matrix[y+1][x+1]: result+=3
  result+=abs(dark*20-n*n*10) div (n*n)*10
proc setFunction(g: var Grid; x, y: int; dark: bool) =
  if x >= 0 and x < g.side and y >= 0 and y < g.side:
    g.modules[y][x] = dark; g.functions[y][x] = true
proc finder(g: var Grid; left, top: int) =
  for dy in -1..7:
    for dx in -1..7:
      let inside = dx in 0..6 and dy in 0..6
      g.setFunction(left+dx, top+dy, inside and (dx in [0, 6] or dy in [0, 6] or (dx in 2..4 and
          dy in 2..4)))
proc drawFormat(g: var Grid; level: string; mask: int) =
  let data = (formatBits(level) shl 3) or mask
  var rem = data
  for i in 0..<10: rem = (rem shl 1) xor (((rem shr 9) and 1)*0x537)
  let bits = ((data shl 10) or rem) xor 0x5412
  for i in 0..5: g.setFunction(8, i, ((bits shr i) and 1) != 0)
  g.setFunction(8, 7, ((bits shr 6) and 1) != 0)
  g.setFunction(8, 8, ((bits shr 7) and 1) != 0)
  g.setFunction(7, 8, ((bits shr 8) and 1) != 0)
  for i in 9..14: g.setFunction(14-i, 8, ((bits shr i) and 1) != 0)
  for i in 0..7: g.setFunction(g.side-1-i, 8, ((bits shr i) and 1) != 0)
  for i in 8..14: g.setFunction(8, g.side-15+i, ((bits shr i) and 1) != 0)
proc drawFunctions(g: var Grid; v: int; level: string) =
  g.finder(0, 0); g.finder(g.side-7, 0); g.finder(0, g.side-7)
  for i in 8..g.side-9:
    g.setFunction(i, 6, i mod 2 == 0); g.setFunction(6, i, i mod 2 == 0)
  let positions = alignmentPositions(v)
  for yi, y in positions:
    for xi, x in positions:
      if (xi == 0 and yi == 0) or (xi == positions.high and yi == 0) or (xi == 0 and yi ==
          positions.high): continue
      for dy in -2..2:
        for dx in -2..2: g.setFunction(x+dx, y+dy, max(abs(dx), abs(dy)) != 1)
  g.drawFormat(level, 0); g.setFunction(8, g.side-8, true)
  if v >= 7:
    var rem = v
    for i in 0..<12: rem = (rem shl 1) xor (((rem shr 11) and 1)*0x1f25)
    let bits = (v shl 12) or rem
    for i in 0..17:
      let a = g.side-11+i mod 3; let b = i div 3
      g.setFunction(a, b, ((bits shr i) and 1) != 0); g.setFunction(b, a, ((bits shr i) and 1) != 0)
proc drawCodewords(g: var Grid; codewords: openArray[uint8]) =
  var bitIndex = 0; var right = g.side-1
  while right >= 1:
    if right == 6: right = 5
    for vertical in 0..<g.side:
      let y = if ((right+1) and 2) == 0: g.side-1-vertical else: vertical
      for x in countdown(right, right-1):
        if not g.functions[y][x]:
          if bitIndex < codewords.len*8: g.modules[y][x] = ((codewords[bitIndex div 8] shr (
              7-bitIndex mod 8)) and 1) != 0
          inc bitIndex
    right-=2
  if bitIndex-codewords.len*8 notin 0..7: fail("INVALID_INPUT", "Inconsistent data-module count")
proc buildMatrix*(codewords: openArray[uint8]; version: int; level: string;
    maskPattern = -1): MatrixResult =
  let n = qrSize(version)
  discard levelIndex(level); discard requireRange(maskPattern, -1, 7, "Mask")
  checkedBytes(codewords)
  if codewords.len != rawCodewordCount(version): fail("INVALID_INPUT", "Wrong interleaved codeword count")
  var base = Grid(side: n, modules: blankMatrix(n), functions: blankMatrix(n))
  base.drawFunctions(version, level); base.drawCodewords(codewords)
  result.penalty = high(int)
  let first = if maskPattern < 0: 0 else: maskPattern
  let last = if maskPattern < 0: 7 else: maskPattern
  for m in first..last:
    var candidate = Grid(side: n, modules: copyMatrix(base.modules), functions: copyMatrix(
        base.functions))
    for y in 0..<n:
      for x in 0..<n:
        if not candidate.functions[y][x] and maskUnchecked(m, x, y): candidate.modules[y][
            x] = not candidate.modules[y][x]
    candidate.drawFormat(level, m)
    let score = penaltyScore(candidate.modules)
    result.maskPenalties.add((m, score))
    if score < result.penalty:
      result.matrix = copyMatrix(candidate.modules); result.maskPattern = m; result.penalty = score
