# GS1 と GS1 Digital Link

Nim 標準ライブラリだけで動作する、SpecQR の限定 GS1 カタログです。Nim 2.2.0 以降の C バックエンドを対象とします。通信、DNS 解決、外部コマンドの呼び出しは行いません。

## 基本例

```nim
import specqr/gs1

let elements = @[
  GS1Element(ai: "01", value: "09506000134352"),
  GS1Element(ai: "10", value: "LOT-A"),
  GS1Element(ai: "17", value: "271231")
]
let raw = createGs1ElementString(elements)
# 010950600013435210LOT-A\x1D17271231
assert parseGs1ElementString(raw).elements == elements
assert gs1ToHumanReadable(elements) ==
  "(01)09506000134352(10)LOT-A(17)271231"
let link = createGs1DigitalLink(elements)
# https://id.gs1.org/01/09506000134352/10/LOT-A?17=271231
assert parseGs1DigitalLink(link).elements == elements
```

`normalizeGs1Elements` は要素配列、解析結果、または文字列を受け付けます。文字列が `(` で始まる場合は人間可読形式、それ以外は生の要素文字列として解析します。値中の `%` は通常のデータであり、この層では FNC1 に置き換えません。

## 対応 AI と値の検査

対応 AI は 50 個です。

- `00`, `01`, `02`, `10`, `11`, `12`, `13`, `15`, `16`, `17`, `20`, `21`, `22`, `30`, `37`
- `240`, `241`, `400`, `410`～`415`, `420`, `422`, `424`, `425`, `426`
- `3100`～`3105`, `3200`～`3205`, `91`～`99`

`getSupportedGs1Ais()` で全メタデータ、`getGs1AiInfo(ai)` で `Option[GS1AiInfo]` を取得できます。固定長・可変長、数字限定・印字可能 ASCII、GTIN/SSCC チェックデジットを検査します。人間可読形式の括弧や U+001D は値中に使用できません。

この限定カタログは GS1 総合認証ではありません。日付 AI は 6 桁を検査し、暦上の実在日や GS1 の全組み合わせ規則までは判定しません。GLN (`410`～`415`) は現在の共通カタログに従い 13 桁を検査します。

可変長フィールドの後には U+001D が必要です。ビルダーが自動挿入します。パーサーは固定長フィールドと疑われる末尾から区切り欠落を検出する、SpecQR 共通の保守的な判定を使用します。

## チェックデジット

- `calculateGs1CheckDigit`, `validateGs1CheckDigit`
- `calculateGtinCheckDigit`, `appendGtinCheckDigit`, `validateGtinCheckDigit`
- `calculateSsccCheckDigit`, `appendSsccCheckDigit`, `validateSsccCheckDigit`

計算関数は本体だけを、検証関数はチェックデジットを含む値を受け付けます。GTIN 本体は 7・11・12・13 桁、SSCC 本体は 17 桁です。不正な桁数や文字は例外、正しい形式でチェックデジットだけが違う場合は `false` です。

## Digital Link

`createGs1DigitalLink` の既定ベースは `https://id.gs1.org`、既定主キーは `01` です。`primaryAi` に `00` または `414` も指定できます。`01` の修飾子 `10`, `21`, `22` は既定でパスに置き、残りを AI 順のクエリに置きます。重複 AI は拒否します。

`pathAis = @["21"]` で選択を限定できます。修飾子をすべてクエリに置く場合は `explicitPathAis = true` と空の `pathAis` を指定します。主キー以外の許可されない AI をパスに指定するとエラーです。

`parseGs1DigitalLink` は `elements`, `primary`, `pathElements`, `queryElements`, `unknownQuery` を返します。既定では GS1 以外のクエリ項目の重複と順序を保持します。拒否するには `unknownQuery = "reject"` を指定します。`normalizeGs1DigitalLink` は既知クエリを決定的に並べ、未知クエリの順序を保持します。

### URL 構文プロファイル

このプロファイルはオフラインの厳格な構文検査です。公開インターネットへの到達可能性や URL の安全性を保証するものではありません。

- HTTP / HTTPS、ASCII URL reg-name、数値 IPv4 別表記、括弧付き RFC IPv6 を受理。ASCII reg-name は DNS ラベル規則だけには限定しません
- HTTP は検証結果に警告を追加。localhost、プライベート IP、ループバックは構文として受理
- 空フラグメント、空のベースクエリ、HTTP(S) の不足／余分なスラッシュ、端の ASCII 空白・制御文字、TAB/LF/CR の字句整理を受理。authority/path のバックスラッシュはスラッシュ、クエリ内は元のデータとして保持
- userinfo は復号時の妥当性を検査してから必要な文字だけをエスケープし、既存のパーセント表記を保持。資格情報を追加の診断に含めません
- ASCII ホストのパーセント表記、`127.1`、`0177.0.0.1`、`0x` などのブラウザー互換数値 IPv4 を正規化。数値は上限検査つきで蓄積し、オーバーフローや不正な octal/hex を拒否
- IPv6 は最長かつ最初のゼロ列を圧縮し、埋め込み IPv4 を 16 進グループへ正規化
- ポートは 0～65535 の十進表記。空ポートと既定ポートを除去し、先頭ゼロを正規化
- 非空フラグメント、不正なパーセント符号化、不正 UTF-8、復号された NUL、ホスト内の符号化された区切り文字、不正 IPv6 とゾーン ID は拒否

非 ASCII / IDNA ホストは明示的な制限です。Nim 標準ライブラリには完全な UTS46 処理がなく、実行時依存なしの条件下で不完全な独自 IDNA を代用しません。ASCII の punycode 形式も reg-name として扱い、ACE ラベルの IDNA 妥当性まで保証しません。例えば `xn--a` は以前から、`xn--` は reg-name 拡張後に受理されますが、TypeScript は拒否します。この制限は全 URL や通常 QR の制限ではありません。

固定 TypeScript commit `16efc6c0a8e397c9df3d051d20fce6c1eebdfad7` を実行した独立期待値に対し、元の 1,411 入力を全件保持し、77 件の受理と 3 件の IPv6 正規化を復元しました。残る 168 差分は診断 132、厳密な percent/UTF-8/NUL 検査 20、IDNA ホスト 12、raw Digital Link 主キー文脈 2、安全な dot-only query ビルダー 2 です。これらを曖昧に「すべて互換」とはしません。

値が `.` / `..` だけの場合、ビルダーは安全なクエリへ移します。実 GS1 ペイロードや主キー文脈を消すパス中の生／符号化ドット値は引き続き拒否します。`%2e` という文字列そのものは `%252e` として可逆に保存します。ベース URL の接頭パスだけにはドットセグメント整理を適用します。既存の接頭パス整理は連続 `/` もまとめるため、例えば builder の `/a//b` は `/a/b` になり、TypeScript の URL 文字列表現と異なる場合があります。これらは原 1,411 件の外の制限で、168 差分の内訳には含めません。

この拡張は通常 QR と両立します。GS1 URL ヘルパーだけの受理・直列化を改善し、通常テキスト／バイナリ QR、matrix/codeword、FNC1 の percent 処理は変更しません。正規化した URL は既存の `generate` へ通常の文字列として渡せます。

## 検証結果と上限

`validateGs1Elements`, `validateGs1ElementString`, `validateGs1DigitalLink` は `JsonNode` を返します。`ok`, `errors`, `warnings` および該当する解析結果を持ち、キーは camelCase です。要素検証は既定で全要素のエラーを収集し、`collectAllErrors = false` で最初のエラーに止められます。

例外の公開カテゴリは `SpecQRError.code == "INVALID_GS1"`、詳細理由は `detailCode` の `GS1_*` です。検証結果の issue `code` は詳細理由を保持します。`elementIndex` と `offset` は 0 始まりです。

入力は最大 1,000,000 UTF-16 相当文字、要素数は最大 16,384、要素配列の AI と値の合計は最大 1,000,000 UTF-8 バイトです。出力と URL 構成要素数にも上限があります。未対応 AI を黙って受理する設定はありません。

```sh
nim c -r --path:src tests/test_gs1.nim
```
