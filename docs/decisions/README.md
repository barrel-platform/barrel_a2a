# Decisions

Short records of the choices that shaped this library, written so that
someone who disagrees can tell whether the reason still holds. One file
per decision, numbered, never edited after the fact: if a decision is
reversed, add a new record that supersedes it.

Format: context, decision, consequences. Keep them to a page.

- [0001](0001-wire-json-maps.md) Protocol objects are wire JSON maps
- [0002](0002-responder-indirection.md) The engine writes through a responder
- [0003](0003-lazy-task-materialization.md) Tasks materialize lazily
- [0004](0004-task-store-async-flush.md) The persistent task store is ETS with an async flush
- [0005](0005-grpc-in-a-separate-package.md) The gRPC binding lives outside this package
