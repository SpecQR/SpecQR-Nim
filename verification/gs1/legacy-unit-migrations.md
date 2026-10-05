# Historical assertions retained and explicitly migrated

Immutable baseline: SpecQR-Nim 4f9154664d35a24cecb30b75cfdba0a9f16ced3e.
The complete historical tests/test_gs1.nim is preserved as legacy_test_gs1.nim.
All 26 test groups and all original inputs remain exercised. Existing test groups
outside the five authority/lexical groups are unchanged. No skipped assertions.
The fixture-based 49 shared GS1 operations retain all original input rows too.

- The 16-host `ambiguous IPv4 aliases include empty hexadecimal digits` group is
  partitioned into exact positive parse/validate/normalize tests for `0x`, `0X`,
  `1.0x`, `0x.`, `1.0X`, `1.2.3.0x`, `0x7f000001`, `0177.0.0.1`, `127.1`,
  `2130706433`, `127.0.0.01`, `1.2.3.4.` and unchanged triple rejection tests for
  `example.0x`, `1.2.3.256`, `example.123`, `example.0xff`.
- Former host rejection inputs `user:password@example.com`, `user@example.com`,
  `%65xample.com`, `a..example`, `-bad.example`, `bad-.example`, `bad_name.example`
  now have exact positive parse/normalize/validate assertions in the credentials
  and ASCII reg-names group. The empty host spelling creates `https:///01/GTIN`:
  lexical acceptance now reaches a missing-primary placement error, independently
  represented by an ordinary-host missing-primary request. It remains rejected.
  `例.jp` and every historical invalid IPv6/zone/suffix remain rejection controls.
- The empty port now has an exact positive normalization assertion. The six other
  historical invalid ports remain rejected; default/nondefault/zero ports remain.
- `https://example.com\x/01/GTIN`, ` https://example.com/01/GTIN` and the query
  `?x=raw space` now have exact positive normalized strings in the URL lexical
  group. FTP, schemeless URLs and nonempty fragments retain rejection assertions.
- Canonical hosts, original IPv6 acceptance, warnings and all other historical
  assertions remain. Newly added overflow, malformed octal/hex, encoded host
  delimiter, userinfo escaping, strict NUL and IPv6 canonicalization controls add
  coverage rather than replace the original inputs.

Positive expectations are authored from the pinned TypeScript behavior, not
captured from candidate output. The all-1411 and shared49 ledgers retain exact
independent TypeScript responses and per-request hashes. The five main-corpus
error-precedence changes are separately bound to original Nim semantic witnesses.
