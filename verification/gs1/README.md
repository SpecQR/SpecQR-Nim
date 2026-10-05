# Independent GS1 verification

The library uses only the Nim standard library. Package verification consumes
pinned synthetic fixtures with Python and executes the real Nim implementation.
Node.js is an optional provenance tool, never an encoder dependency.

## Authoritative current-source cases

`fixtures/gs1-upstream.json` is unchanged: all 1,411 original requests remain.
`fixtures/current-ts-gs1-1411.json.gz` contains every request and its freshly
executed current-TypeScript result, with case IDs, request hashes, source-tree
and source-file hashes, oracle harness hash, toolchain version and output digest.
Paths here are relative to `verification/`.

Source pins:

- Historical requests: TypeScript `15ad15e5c770ea0e39072f8f88b2733018f02ffd`
- Current TypeScript: https://github.com/SpecQR/SpecQR at
  `16efc6c0a8e397c9df3d051d20fce6c1eebdfad7`, Node.js v24.19.0
- Independent native witness: https://github.com/SpecQR/SpecQR-Nim at
  `4f9154664d35a24cecb30b75cfdba0a9f16ced3e`, Nim 2.2.12 C backend;
  `src/specqr/gs1.nim` SHA256
  `9df6a11927f265108e4d01e3321a208e1bcd4f9c484ff6aad5f9b8bd42734fa3`

## Explicit compatibility accounting

The current verifier requires 1,243 exact public contracts equal to current
TypeScript. It separately gates every one of the 80 restored cases: 77 previously
rejected accepted inputs and three IPv6 canonical-spelling results. The complete
request-bound targets are in `fixtures/approved-restorations80.json`.

Exactly 168 residual differences remain explicit in
`fixtures/native-intentional-deltas168.json`:

- 132 diagnostic code/reason/count conventions
- 34 accepted-to-rejected differences: 20 strict percent/UTF-8/NUL cases,
  12 IDNA host cases, and two raw Digital Link context-primary cases
- Two safe-dot-query cases that preserve dot-only GS1 payload values

Five diagnostic values change because accepted URL normalization now reaches a
later validator. `fixtures/diagnostic-migrations5.json` binds each original
request and prior value to a newly executed independent Nim semantic witness,
its result and the validation-order rationale. It changes no acceptance result
or residual case ID. Candidate Nim outputs never generate expectations.

Comparisons require exact normalized public fields in both directions. The
cross-language normalization removes optional nulls, `length.isVariable`, empty
successful `errors`, English diagnostic wording and auxiliary diagnostic fields;
it retains all payload/catalog fields plus diagnostic code, reason and count.
Native tests separately cover complete language-native metadata and ownership.

## Existing shared vectors remain active

`fixtures/current-ts-gs1-shared49.json` independently evaluates all 49 operations
from the unchanged strict-authority and shared Digital Link fixtures. All six
valid alias hosts have 18 explicit TypeScript-positive results. `example.0x`
remains three malformed rejection controls.

`fixtures/native-shared-gs1-deltas3.json` binds only three intentional exceptions:
two safe-dot builders and the `example.0x` validation diagnostic. All 28 existing
Digital Link preservation operations remain checked. Final target outcomes are
25 accepted and 24 rejected operations. None is skipped.

The historical authority fixture and archived native unit source retain the
previous rejection profile as provenance. The explicit assertion migration map
is `legacy-unit-migrations.md`; older blanket rejections are not current pass claims.

## Optional regeneration

Supply independently verified local checkouts of the exact pinned sources:

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

The checked-in generation harnesses import neither candidate Nim code nor
candidate output. All required fixture and request hashes are enforced by
`scripts/gs1_contract.py`. All 1,411 requests execute on each tested compiler/build/memory lane.

## Additional serialization controls

`fixtures/url-serialization-controls394.json` contains 394 separately executed,
independent pinned TypeScript positives. It covers each admitted printable ASCII
path/base-path/userinfo/query character, IPv4 numeric boundaries and IPv6 equal
zero-run choices. Two explicit caret prefix cases require `%5E` serialization.
The extra cases are checked separately from the unchanged 1,411-case accounting.
