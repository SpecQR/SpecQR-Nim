# SpecQR Nim 利用ガイド

## Options と座標

`Options()` の既定値は M、version=0（自動）、minVersion=1、maxVersion=40、maskPattern=-1（自動）、mode="auto"、最適化あり、Kanji 自動利用あり、ECC boost なし、余白 4、倍率 8 です。

`version=1..40` は固定です。`eciAssignment=-1` は未指定、`0..999999` は ECI です。`printDpi` と `structuredAppend` は `std/options` の Option 値です。FNC1 / ECI / Structured Append は、この実装では異なる制御ファミリーを併用できません。

行列は `seq[seq[bool]]` の `[y][x]`。`moduleAt(q,x,y)` は **0-based** です。返却値・入力の byte seq は独立した値として扱えます。公開結果の行列を変更しても、他の結果の行列を書き換えません。未初期化／不正な公開結果を診断・座標取得へ渡すと `SpecQRError` になります。

## 手動セグメントと Unicode

```nim
import specqr
let q = generateSegments([
  numeric("0123456789"),
  alphanumeric("SPECQR / "),
  byteSegment("🙂"),
  kanji("漢字")
])
let binary = generate([0'u8, 255, 128, 29])
let utf8 = generate("é é 🙂", Options(mode:"byte", eciAssignment:26))
```

Nim の string は任意 byte を保持できますが、text API は不正 UTF-8、過長符号化、孤立サロゲート、U+10FFFF 超を拒否します。binary API は `openArray[uint8]` で、内容を文字として解釈しません。ECI は変換を行わないため、UTF-8 以外の ECI を使う場合は利用者が対応する raw byte を渡します。

Kanji の対応表は QR の Shift-JIS 範囲に入る CP932 の最初の対応です。全 Unicode 漢字を含むわけではありません。auto は利用可能なら Kanji を使い、それ以外は UTF-8 byte を使います。ECI 指定時の auto は Kanji を選びません。

## plan / estimate / capacity

```nim
let p = plan("1234567890", Options(errorCorrectionLevel:"H"))
doAssert p.ok
assert p.dataBitLength == 48
let c = getCapacity(10,"M","byte")
echo c.maximum
```

`Plan.ok`、`capacityVersion`、`dataBitLength`、`capacityBits`、`remainingBits`、`segments` を返します。auto が収まらなかった場合 `version=0`、`capacityVersion=maxVersion` です。固定 version で不適合ならその版が保持されます。`generate` は収まらない入力に `DATA_TOO_LONG` を返します。plan は符号語・Reed–Solomon・行列・マスクを構築しません。

容量はモードごとの count field 上限も考慮します。`getCapacity` の `controlBits` は制御に先に使うビット数です。mode を空にするとモード別の値は -1 です。

最適化は 4 モード、numeric の 3 剰余・alpha の 2 剰余を含む monotonic queue の動的計画法です。ビット数、セグメント数の順に最小化し、同率では固定したモード順を用います。`SegmentOptimizationTracker` は `newSegmentOptimizationTracker` で作り、`appendCharacter` で Unicode scalar を一つずつ追加できます。

## FNC1 / GS1

```nim
let manual = generateSegments([fnc1(),alphanumeric("10LOT%21SER%%IAL")])
let high = generate("10LOT%" & "\x1d" & "21SER%%IAL", Options(gs1:true))
let second = generate("ABC%DEF", Options(fnc1Second:"A"))
```

手動 alpha では `%` が GS、`%%` がリテラル `%` を表します。高水準は入力本文の `%` を保存するため、auto を byte に切り替えます。明示 alphanumeric は `INVALID_MODE` にします。連続 GS も raw byte として失わずに符号化します。`gs1:true` はさらに element string の AI/長さ等を検証します。`fnc1:true` は GS1 内容の検証をしません。

Digital Link は構文をオフラインで検証します。HTTP/HTTPS、正規の DNS / IPv4 / bracketed IPv6 などの限定プロファイルであり、localhost / private IP のアクセスを防ぐ SSRF フィルターではありません。このライブラリは URL を開きません。曖昧な数値ホスト別表現、資格情報、パス破損につながる dot-only segments は拒否します。作成時の dot-only qualifier は query に回し、未知 query の順序と重複を保存します。詳しくは [GS1 ガイド](gs1.md)。

## Structured Append

```nim
let set = generateStructuredAppend(newSeq[uint8](256), Options(version:2))
for q in set.symbols:
  echo q.version, " / ", q.maskPattern
```

入力が 1 シンボルに収まる場合は SA を強制せず `INVALID_INPUT`。指定範囲で 2..maxSymbols 個に分割できなければ `DATA_TOO_LONG` です。同じ版・ECC で、先頭から最大の収まる部分を取ります。文字列は Unicode scalar 境界、raw bytes は byte 境界です。手動セグメントでは non-byte は分割せず、byte だけを分割します。

`calculateStructuredAppendParity` は原文 UTF-8 または raw byte の XOR。`calculateStructuredAppendSegmentsParity` は手動データの論理 byte 列の XOR。`mergeStructuredAppendParts` は JSON 配列の `{index,total,parity,data}` を受け、重複・欠落・異なる型・パリティ不一致を拒否し、index 順の `MergeResult.data` を返します。`data` は全パート同じ型の文字列または整数 byte 配列にしてください。空の default result の diagnostics、nil を含む malformed JSON は型付きエラーになります。

## レンダリング

`toSvg`、`toPng`、`toPixels`、`toSvgDataUrl`、`toPngDataUrl` が利用できます。結果のオプションを使うか、`RenderOptions(scale:3,margin:4,foreground:"#000",background:"#fff")` を指定してください。PNG は RGBA8、filter 0、stored DEFLATE、CRC-32 / Adler-32 を自前で出力します。

SVG は hex / ASCII CSS 色名。PNG は hex RGB/RGBA、black、white、transparent のみです。診断は quiet zone、alpha 合成後のコントラスト、容量使用率、任意 DPI での module mm を評価します。警告は読み取り成功を保証するものではありません。

- payload: 1,000,000 Unicode scalars または raw bytes、text byte 最大 4,000,000
- 単一シンボル最適化: 最大 7,089 scalars
- 手動セグメント: 最大 16,384
- QR: 177×177 modules、最大 3,706 codewords
- ラスター: 最大 4,194,304 pixels、辺 2,048 pixels
- SVG: 最大 8 MiB characters、data URL: 最大 32 MiB
- geometry 整数: 最大 1,000,000,000、積は事前に検証

## CLI / エラー

`--text`、`--text-file`、`--bytes-file` のいずれか一つを指定します。ファイルはサイズ確認後も上限付きで読み、サイズが変わっても無制限に読みません。成功は exit 0、失敗は exit 2 と stderr の `CODE: message` です。PNG の標準出力はバイナリであり、他のメッセージを混ぜません。

公開失敗は `SpecQRError`、`e.code` を判定してください。主要カテゴリは INVALID_INPUT / INVALID_VERSION / INVALID_ECC_LEVEL / INVALID_MODE / INVALID_ECI / INVALID_GS1 / INVALID_COLOR / INVALID_OUTPUT / DATA_TOO_LONG。GS1 には追加の `detailCode` があります。
