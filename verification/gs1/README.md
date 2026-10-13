# Independent GS1 verification

The library uses only the Nim standard library.

パッケージ検証では、固定した合成 fixture を Python で読み、実際の Nim 実装を実行します。Node.js は任意で使う出典確認用ツールであり、エンコーダーの依存関係ではありません。

## Authoritative current-source cases

`fixtures/gs1-upstream.json` は変更せず、元の 1,411 requests をすべて保持しています。`fixtures/current-ts-gs1-1411.json.gz` には、全 request と、新たに実行した現行 TypeScript の各結果を保存しています。case IDs、request hashes、source-tree と source-file の hashes、oracle harness hash、toolchain の版、出力の digest も含みます。ここでのパスは `verification/` からの相対パスです。

固定した参照元:

- 過去の requests: TypeScript `15ad15e5c770ea0e39072f8f88b2733018f02ffd`
- 現行 TypeScript: https://github.com/SpecQR/SpecQR の
  `16efc6c0a8e397c9df3d051d20fce6c1eebdfad7`、Node.js v24.19.0
- 独立した native witness: https://github.com/SpecQR/SpecQR-Nim の
  `4f9154664d35a24cecb30b75cfdba0a9f16ced3e`、Nim 2.2.12 C バックエンド。
  `src/specqr/gs1.nim` SHA256
  `9df6a11927f265108e4d01e3321a208e1bcd4f9c484ff6aad5f9b8bd42734fa3`

## Explicit compatibility accounting

現行 verifier は、現行 TypeScript と厳密に一致する 1,243 件の公開契約を要求します。復元した 80 cases もすべて個別に検査し、以前は拒否していた受理対象の入力 77 件と、IPv6 の正規表記の結果 3 件を確認します。request に結びついた対象全体は `fixtures/approved-restorations80.json` にあります。

残る差分は厳密に 168 件であり、`fixtures/native-intentional-deltas168.json` に明示しています。

- diagnostic code/reason/count の規約による差分 132 件
- 受理から拒否になる差分 34 件: 厳密な percent/UTF-8/NUL cases 20 件、IDNA host cases 12 件、raw Digital Link context-primary cases 2 件
- dot-only GS1 payload 値を保持する safe-dot-query cases 2 件

受理した URL の正規化が後段の validator に到達するようになったため、診断値 5 件が変わります。`fixtures/diagnostic-migrations5.json` は、各原 request と以前の値を、新たに実行した独立した Nim semantic witness、その結果、検証順序の根拠に結びつけています。受理・拒否の結果や残存差分の case ID は変更しません。候補 Nim の出力から期待値を生成することはありません。

比較では、正規化した公開 field が双方向で厳密に一致する必要があります。言語間の正規化では、省略可能な null、`length.isVariable`、成功時の空の `errors`、英語の診断文、補助診断 field を除去します。全 payload/catalog fields と、診断の code、reason、count は保持します。native tests は、言語固有の全 metadata と所有権を別途検査します。

## Existing shared vectors remain active

`fixtures/current-ts-gs1-shared49.json` は、変更していない strict-authority と共有 Digital Link fixtures の全 49 operations を独立に評価しています。有効な別表記の host 6 個すべてについて、TypeScript が受理する 18 件の明示的な結果があります。`example.0x` は、不正入力を拒否する 3 controls として保持しています。

`fixtures/native-shared-gs1-deltas3.json` が結びつける意図的な例外は、safe-dot builders 2 件と `example.0x` の検証診断の計 3 件だけです。既存の Digital Link preservation operations 28 件は、すべて検査を継続しています。最終的な対象結果は受理 25 operations、拒否 24 operations です。省略するものはありません。

過去の authority fixture と保存した native unit source は、出典として以前の拒否 profile を保持しています。assertion の明示的な移行対応表は `legacy-unit-migrations.md` です。以前の一律拒否を、現在の合格結果として主張するものではありません。

## Optional regeneration

固定した参照元と厳密に一致し、独立に検証したローカルチェックアウトを用意します。

```sh
nim c --path:/path/to/SpecQR-Nim/src \
  --nimcache:/tmp/specqr-gs1-oracle-cache \
  -o:/tmp/specqr-gs1-oracle verification/gs1/nim_oracle.nim
/tmp/specqr-gs1-oracle verification/fixtures/gs1-upstream.json > /tmp/gs1-nim.json
node verification/gs1/current_ts_oracle.mjs /path/to/SpecQR \
  verification/fixtures/gs1-upstream.json > /tmp/gs1-current-ts.json
python3 scripts/verify_gs1.py \
  --binary /path/to/compiled-bridge --output /tmp/gs1-nim-restored.json
```

チェックインした生成 harness は、候補 Nim コードも候補の出力も import しません。`scripts/gs1_contract.py` が必須の fixture と request のハッシュをすべて検査します。検査対象の各 compiler/build/memory lane で、全 1,411 requests を実行します。

## Additional serialization controls

`fixtures/url-serialization-controls394.json` は、別途実行した独立した固定 TypeScript の正例 394 件を含みます。受理する印字可能な ASCII path/base-path/userinfo/query の各文字、IPv4 の数値境界、IPv6 の同長ゼロ列の選択を対象とします。明示した caret prefix cases 2 件では、`%5E` への直列化を要求します。追加の cases は、変更していない 1,411 件の集計と分けて検査します。
