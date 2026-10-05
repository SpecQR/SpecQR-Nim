# SpecQR Nim

A from-scratch QR Code Model 2 encoder using only the Nim standard library at runtime. No QR package, QR-service calls, foreign QR wrapper, or image codec dependency.

[日本語](README.md) · [Guide](docs/guide.md) · [Verification](docs/verification.md)

Supports versions 1–40, L/M/Q/H, all eight masks, exact numeric/alphanumeric/byte/Kanji optimization, strict Unicode scalar UTF-8, raw bytes, ECI, FNC1 first/second position, a bounded 50-AI GS1 profile, Digital Link, 2–16-symbol Structured Append, arithmetic planning, diagnostics, SVG, pure PNG, pixels and data URLs.

## Build and use

Requires Nim >= 2.2.0 and a C compiler. Linux x86-64 with Nim 2.2.0 and 2.2.12 is the verification profile, using both debug/release and ARC/ORC. Windows, macOS, 32-bit and the JavaScript backend are not claimed as tested.

```sh
nim c -d:release --path:src -o:specqr_cli src/specqr_cli.nim
./specqr_cli --text 'Hello 日本語 🙂' --eci 26 --mode byte --format png --output qr.png
```

```nim
import specqr
let q = generate("Hello", Options(errorCorrectionLevel: "H"))
writeFile("qr.svg", q.toSvg)
doAssert plan("123456").ok
```

Import using `--path:/path/to/SpecQR-Nim/src`, or install a local checkout with Nimble. This project has not been submitted to the Nimble registry. No release tags or release assets are created by the test tools.

Rendering defaults to eight pixels per module and four quiet-zone modules. Raster output is bounded at 2,048 pixels per edge. Text input uses strict shortest-form UTF-8; ECI labels without transcoding; binary bytes remain opaque. Kanji uses a pinned 6,953-scalar normative mapping. High-level FNC1 literals containing `%` use byte fallback (forced alphanumeric rejects); manual segments retain the caller's QR escape semantics.

GS1 / Digital Link implement a documented subset, not GS1 certification or a remote URL safety check. Structured Append XOR is not authentication. Independent decoders differ in metadata and default-scale detection behavior; see the verification guide for the separate Java detector characterization.

## Checks

`python3 scripts/verify_native.py --nim /absolute/path/to/nim --expect-version 2.2.12 --output /tmp/specqr-nim-validation` runs the compiler, four build/memory lanes, 60 native test groups, all 10,186 pinned reference cases, malformed-input checks, CLI checks, and a fresh offline Nimble consumer. Test-only independent decoder dependencies are separate from runtime code.

MIT license. Fixture provenance and hashes are retained in verification/fixtures/manifest.json.
