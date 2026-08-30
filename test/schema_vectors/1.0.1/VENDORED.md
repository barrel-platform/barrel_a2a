# A2A wire-schema vectors

Vendored, not fetched: the build must not depend on the network, and a
schema that changed under us would turn an unrelated commit red.

- Source: https://github.com/a2aproject/A2A, tag `v1.0.1`
- `1.0.1/a2a.json` is the JSON Schema 2020-12 bundle the project
  generates from `specification/a2a.proto` (bufbuild
  `protoc-gen-jsonschema`) and publishes at
  https://a2a-protocol.org/latest/spec/a2a.json. It is not committed
  upstream; it was fetched from the published site on 2026-08-30.
- `1.0.1/examples/<Type>/*.json` are canonical instances of each
  `$defs` entry, taken from the JSON examples in
  `docs/specification.md` (sections 6 and 8.5) and, where the
  specification has no example, written here from the proto
  definition.

The same `a2a.json` is shipped in `priv/schema/a2a.json` for runtime
validation; `barrel_a2a_schema_vectors_SUITE` checks the two are
identical.

## Updating

Deliberate, never automatic:

```sh
curl -o test/schema_vectors/<version>/a2a.json https://a2a-protocol.org/latest/spec/a2a.json
cp test/schema_vectors/<version>/a2a.json priv/schema/a2a.json
```

Then run `rebar3 ct --suite=test/barrel_a2a_schema_vectors_SUITE`. A
vector our validator refuses is either a validator bug or a schema
feature we do not implement; the second needs a skip with a reason,
never a silent pass.
