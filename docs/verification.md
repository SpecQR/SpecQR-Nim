# 検証ガイド

## 検証対象と非対象

公開前ゲートは Linux x86-64 の実処理系 Nim 2.2.0 / 2.2.12、C バックエンド、debug / release × ARC / ORC の計 8 lanes です。Windows、macOS、32-bit、JavaScript バックエンドは未検証です。OS 固有分岐は実装していません。標準ライブラリからの通常の C ランタイム利用は Nim の実行モデルに含まれます。

「チェックを書くこと」と「そのチェックの成功」は別です。各実行の report.json は status、正確なコンパイラー／実行ファイルのハッシュ、実行 OS、コマンド、exit status、stdout/stderr のハッシュ、ソース不変性を記録します。途中失敗は failed のまま保存します。最終の公開 commit と GitHub Actions 結果は、その公開時の実行に対応します。

## 固定データ

SpecQR の既存実装間で共有した言語非依存の 10,186 件を同梱しています。ソース provenance は fixtures の manifest に保持しています。

- public: 5,610 件、SHA-256 `f1649de0f2e62c87fa7b369cdd1f99bd7c092b6a1a2fa52e2e0caf5aea136f82`
- internal: 4,576 件、SHA-256 `140eec7223af96822572f87cf67a80b612619bde250db552c1cad83b603ae67e`
- GF(256) の全 65,536 組、Reed–Solomon degree 1..255
- V1..40 × 4 ECC × 8 マスク（1,280 組）、さらに複数のパターンと自動マスク
- 正確な codeword bytes、行列 hash、packed matrix、容量、最適化結果、22 SA セット

fixture の期待値を候補 Nim コードで再生成しません。比較は必須 field の型と値、配列長まで確認します。boolean を数値の代用として許可しません。

## 実行

```sh
python3 scripts/prepare_ci.py verify
python3 scripts/prepare_ci.py stage --output /tmp/SpecQR-Nim-source
python3 /tmp/SpecQR-Nim-source/scripts/verify_native.py \
  --nim /absolute/path/to/nim --expect-version 2.2.12 \
  --output /tmp/SpecQR-Nim-evidence
```

実装を更新した開発者だけが `prepare_ci.py manifest` で manifest を更新し、再度全ゲートを実行してください。配布物を消費する側は verify を使います。出力先はソース外の新規ディレクトリです。

各 lane は 60 の native test groups、10,186 corpus requests、301 malformed-input checks、31 CLI processes を実行します。テストバイナリは exit 0 と stderr なしが必要です。JSON-line bridge は入力 EOF で終了し、余分な stdout、遅れて出る stderr、非 0 exit、タイムアウトを合格として扱いません。

ローカル Nimble consumer は新しい package copy、リモートを持たないローカル Git snapshot（Nimble 0.16.1 の tracked-file 検証用）、新しい HOME/NIMBLE_DIR、空の packages_official.json、`--offline` を使います。インストール後の全 Nim source bytes を元ソースと比較し、別ディレクトリで import / SVG / PNG / plan のプログラムをコンパイル・実行します。インターネット上の Nimble レジストリー登録とは別です。

## 独立画像・デコーダー検証

テスト専用依存: ZXing-C++ 3.1.1、Pillow 12.1.1、ZXing Java 3.5.4、Java、librsvg。Nim ランタイムには不要です。Python wheel と Java JAR はハッシュ固定、CI action も commit 固定です。

```sh
python3 scripts/verify_decoders.py --binary /path/to/bridge \
  --decoder cpp --scale 8 --python-deps /path/to/test-wheels --output /tmp/cpp.json
python3 scripts/verify_decoders.py --binary /path/to/bridge \
  --decoder java --java /path/to/java --jar /path/to/core-3.5.4.jar --output /tmp/java.json
```

C++ gate は版 1 / 7 / 40 の暗黙 default PNG を明示 scale=8 と byte 単位で比較し、それぞれ独立に復号します。さらに scale 8 の **実 PNG** 764 件を生成し、CRC、DEFLATE/Adler、全ピクセルと行列の対応、独立検出、payload、ECI、FNC1、SA、版とマスクを確認します。Java gate は scale 3 の実 PNG と直接行列の両方を確認します。

Java の scale 8 での検出は `characterize_java_default_scale.py` で独立に記録します。候補 PNG と別実装の同一ピクセル PNG、matrix decode、scale 3 と C++ を対照にし、Java の拒否を成功に数えません。default scale 8 の C++ 合格や Java scale 3 の全件合格の代用にはしません。

`verify_render_decoders.py` は SVG を librsvg で独立に rasterize し、PNG と RGBA を全ピクセル比較します。data URL の round-trip も確認します。

`verify_shared_regressions.py` はリテラル `%` の 102 vectors、manual semantics、Digital Link dot-only data、query、strict numeric-host aliases、finite DPI、ECC を検証します。各 case の容量期待値を独立に計算し、あらゆる DATA_TOO_LONG を一括で許可しません。

## ハーネス自身の陰性対照

`test_harness.py` は 24 tests で、ソース改変、extra stdout、late stderr、nonzero exit、EOF 未到達、timeout、不正 JSON、誤った fixture outcome、auxiliary decoder/rasterizer の不正出力などが実際に失敗することを確認します。これらは実 Python subprocess のハーネス試験で、Nim 実行や decoder 実行の代用ではありません。

## 処理系の出所

公式 Nim download page と `nim-lang/nightlies` の固定 release asset を使用します。

- 2.2.12: commit `8e8fbf60693418dc95bb0d762fd660231d08a583`、asset SHA-256 `7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638`。公式 release API の digest と一致。
- 2.2.0: commit `78983f1876726a49c69d65629ab433ea1310ece1`、asset SHA-256 `942e047879fd81193b2ff3c105436a0c5016800c4e97864f90039ae204f89ded`。古い API asset に digest field がないため、公式 asset から取得した固定ハッシュを使用。

この記録は暗号学的署名・第三者認証を意味しません。

Sources: [Nim install](https://nim-lang.org/install.html), [Nim memory management](https://nim-lang.org/docs/mm.html), [Nim manual](https://nim-lang.org/docs/manual.html), [Nim 2.2.12 announcement](https://nim-lang.org/blog/2026/09/08/nim-2212.html).
