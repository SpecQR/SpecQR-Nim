# SpecQR Nim

Nim 標準ライブラリだけで動作する、フルスクラッチの QR Code Model 2 エンコーダーです。QR ライブラリ、外部画像コーデック、FFI の QR ラッパー、ネットワークサービスを実行時に使用しません。

[English](README.en.md) · [日本語ガイド](docs/guide.md) · [GS1 / Digital Link](docs/gs1.md) · [検証方法](docs/verification.md)

## 対応機能

- バージョン 1–40、誤り訂正 L/M/Q/H、8 マスクと自動選択
- numeric / alphanumeric / byte / Kanji、厳密 UTF-8、バイナリ入力、ECI
- 線形時間の厳密なセグメント最適化、手動セグメント、容量計算、行列を作らない plan / estimate
- FNC1 第 1 / 第 2 位置、50 AI の GS1 プロファイル、GS1 Digital Link
- 2–16 シンボルの Structured Append、順序・パリティを確認する再結合
- SVG、PNG、RGBA ピクセル、SVG / PNG data URL、印刷・コントラスト診断
- ネイティブ Nim API と CLI、Nimble 用のパッケージ定義

## 動作条件

Nim 2.2.0 以降と C コンパイラーが必要です。検証対象は Linux x86-64、Nim 2.2.0 / 2.2.12、C バックエンド、debug / release と ARC / ORC です。ソースは OS 固有の QR 実装を使いませんが、Windows・macOS・32-bit・JavaScript バックエンドは検証済みとはしていません。

Nim 本体は [公式インストール案内](https://nim-lang.org/install_unix.html) から導入できます。C コンパイラーは Nim の通常のビルド要件です。実行時のサードパーティ依存はありません。

```sh
nim c -d:release --path:src -o:specqr_cli src/specqr_cli.nim
./specqr_cli --text 'SpecQR 日本語 🙂' --eci 26 --mode byte --format png --output qr.png
```

CLI の標準倍率は 8 pixels/module、余白は 4 modules です。ファイル名と本文に Unicode を使用できます。

## ライブラリ

```nim
import specqr

let qr = generate("SpecQR 日本語 🙂",
  Options(errorCorrectionLevel: "M", mode: "byte", eciAssignment: 26))
writeFile("qr.svg", qr.toSvg)
let pngBytes = qr.toPng
let matrix = qr.matrix
let estimate = plan("0123456789", Options(errorCorrectionLevel: "H"))
doAssert estimate.ok
```

`nim c --path:/path/to/SpecQR-Nim/src app.nim` で利用できます。ローカル Nimble インストールも可能です。レジストリーへの登録・タグ／リリース公開は行っていません。

## 重要な境界

- テキストは最短形式の Unicode scalar UTF-8。壊れた UTF-8 は拒否し、raw byte 配列はそのまま符号化します。
- ECI はラベルです。文字コード変換はしません。Kanji は同梱した 6,953 scalar の QR/CP932 対応表を利用します。
- 高水準 FNC1 でリテラル `%` を含む auto 入力は byte に切り替えます。明示 alphanumeric は拒否します。手動 FNC1 の alphanumeric は利用者が QR の `%` / `%%` 表現を用意します。
- GS1 の AI、Digital Link の URI 構文は限定されたプロファイルです。空 fragment／query、userinfo、ASCII reg-name、数値 IPv4、IPv6 正規化などの互換性を復元し、通常 QR の機能と両立します。全 GS1 仕様の適合認証、リモート URL の到達性／安全性検査を意味しません。
- Structured Append の XOR は破損確認の補助であり、暗号学的な真正性確認ではありません。デコーダーごとに SA / FNC1 第 2 位置の公開情報が異なります。
- 通常の入力は 1,000,000 単位まで。単一シンボルの容量は QR 仕様が優先されます。ラスターは 4,194,304 pixels、辺 2,048 pixels までです。詳細はガイドを参照してください。

## 検証

```sh
python3 scripts/prepare_ci.py verify
python3 scripts/verify_native.py --nim /absolute/path/to/nim \
  --expect-version 2.2.12 --output /tmp/specqr-nim-validation
```

この検証はコンパイラーを実際に実行し、4 build/memory lanes、60 ネイティブテスト群、10,186 固定期待値、1,411 GS1 入力と 80 URL 互換性復元、CLI、ローカルのオフライン Nimble consumer を確認します。外部デコーダーの検証依存はテスト専用です。実施結果と未検証範囲は [検証ガイド](docs/verification.md) を確認してください。

MIT License。QR エンコーダーの実装は SpecQR プロジェクト自身のものです。Nim 移植の検証データの出所・固定ハッシュは verification/fixtures/manifest.json にあります。
