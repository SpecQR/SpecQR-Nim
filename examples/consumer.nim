import specqr
let qr = generate("SpecQR 日本語 🙂", Options(eciAssignment:26,mode:"byte"))
doAssert qr.version >= 1
doAssert qr.size == 17 + 4 * qr.version
doAssert qr.moduleAt(0,0)
doAssert qr.toSvg.len > 100
doAssert qr.toPng[0] == 137'u8
let estimate = plan("0123456789", Options(errorCorrectionLevel:"H"))
doAssert estimate.ok
doAssert estimate.dataBitLength == 48
let manual = generateSegments([fnc1(),alphanumeric("10LOT%21SER%%IAL")])
doAssert manual.segments.len == 2
echo "consumer passed"
