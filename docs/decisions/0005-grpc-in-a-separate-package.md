# 0005. The gRPC binding lives outside this package

## Context

A2A defines three bindings: JSON-RPC, HTTP+JSON and gRPC. The
specification does not make any of them mandatory; an agent declares
what it serves in its Agent Card (spec 5.2, 8.3). Implementing gRPC
here would have added `gpb`, a vendored `a2a.proto`, a code generation
step and the google.rpc protos to every user of the library, including
those who only ever speak JSON.

## Decision

barrel_a2a implements the two HTTP bindings and stays on `h1`, `h2` and
`hackney`. The gRPC binding is a separate package, `livery_grpc_a2a`,
built on two contracts this library exports:

- `barrel_a2a_server_core:call/4`, which is binding-neutral: it takes
  the request as the A2A JSON map and a request context describing what
  the binding knows, and returns `{ok, Reply}`, `{stream, Subscribe}`
  or `{error, Error}`. `barrel_a2a_error:grpc_status/1` supplies the
  status mapping.
- The `barrel_a2a_client_transport` behaviour, registered through
  `barrel_a2a_client:connect/2`, so the client speaks gRPC without
  knowing anything about it.

## Consequences

The dependency footprint stays small and the two HTTP bindings are the
only thing this repository has to keep green. `docs/features.md` marks
section 10 as delivered elsewhere rather than as missing.

The cost is that the binding-neutral contracts have to be real
contracts, not incidental shapes. They are documented in
`guides/embedding.md` and exercised by `barrel_a2a_embed_SUITE`, which
calls `server_core:call/4` directly for every operation the way a gRPC
binding does. If that suite is allowed to rot, the split stops working.
