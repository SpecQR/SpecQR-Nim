import ./errors

const EccCodewordsPerBlock* = [
  [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]
const NumErrorCorrectionBlocks* = [
  [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]

const ErrorCorrectionLevels* = ["L", "M", "Q", "H"]
proc validateVersion*(v: int) = discard requireRange(v,1,40,"QR version","INVALID_VERSION")
proc levelIndex*(level: string): int =
  for i,l in ErrorCorrectionLevels:
    if l == level: return i
  fail("INVALID_ECC_LEVEL", "ECC must be L, M, Q, or H")
proc formatBits*(level: string): int = [1,0,3,2][levelIndex(level)]
proc qrSize*(v: int): int =
  validateVersion(v)
  4*v+17
proc rawCodewordCount*(v: int): int =
  validateVersion(v)
  result=(16*v+128)*v+64
  if v>=2:
    let n=v div 7+2
    result-=(25*n-10)*n-55
    if v>=7: result-=36
  result=result div 8
proc blockInfo*(v: int; level: string): tuple[blocks,eccPerBlock,rawCodewords,dataCodewords:int] =
  validateVersion(v)
  let i=levelIndex(level)
  result.blocks=NumErrorCorrectionBlocks[i][v-1]
  result.eccPerBlock=EccCodewordsPerBlock[i][v-1]
  result.rawCodewords=rawCodewordCount(v)
  result.dataCodewords=result.rawCodewords-result.blocks*result.eccPerBlock
proc dataCodewordCount*(v: int; level: string): int = blockInfo(v,level).dataCodewords
proc alignmentPositions*(v: int): seq[int] =
  validateVersion(v)
  if v==1: return @[]
  let n=v div 7+2
  let denominator=n*2-2
  let step=if v==32: 26 else: ((v*4+4+denominator-1) div denominator)*2
  result.add(6)
  for i in countdown(n-2,0): result.add(qrSize(v)-7-i*step)
proc characterCountBits*(v: int; mode: string): int =
  validateVersion(v)
  let group=if v<=9:0 elif v<=26:1 else:2
  case mode
  of "numeric": [10,12,14][group]
  of "alphanumeric": [9,11,13][group]
  of "byte": [8,16,16][group]
  of "kanji": [8,10,12][group]
  else: fail("INVALID_MODE","Expected a data mode")
