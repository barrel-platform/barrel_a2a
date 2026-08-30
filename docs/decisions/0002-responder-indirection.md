# 0002. The engine writes through a responder

## Context

The library ships its own listener over `h1` and `h2`, but the same
protocol has to be servable from an HTTP server the application
already runs (the `livery_a2a` bridge was the immediate case). Writing
the engine against `h1`/`h2` directly would have forced an embedder to
either adopt our listener or reimplement the bindings.

## Decision

`barrel_a2a_http_engine:handle/6` never touches a socket. It writes
through a responder: a map of four closures (`reply`, `stream_start`,
`stream_chunk`, `stream_end`) plus a `disconnected/1` predicate that
recognizes the transport's own disconnect message. The listener builds
one over `h1`/`h2`; an embedder builds one over its adapter.

## Consequences

The engine is testable with no sockets at all: `barrel_a2a_embed_SUITE`
drives it with a responder that sends to the test process, which is how
the SSE ordering cases are written.

The cost is that the engine cannot recognize a disconnect by itself and
must be handed that knowledge, and that it inherits the caller's
process: it runs there, blocks there for the life of a stream, and
takes over that mailbox. Those are invariants E1 and E2 in
`docs/internals/invariants.md`, and they are the contract an embedder
must respect.

An alternative was to give the engine a process of its own and have
transports send it requests. It was rejected because the streaming path
would then need its own flow control and its own disconnect signalling,
duplicating what h1, h2 and livery each already do.
