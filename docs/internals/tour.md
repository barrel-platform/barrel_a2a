# Code tour

This page is for someone who has to change barrel_a2a, not use it. It
says what to read first, what you can skip, where the risk is, and
which files a given kind of change touches. Read it once before your
first change; the other pages in `docs/internals/` are references you
come back to.

## The shape of the tree

`src/` is flat, 50 modules, about 11.8k lines. It divides into three
parts that need very different amounts of attention.

| Part | Size | What it is | How to read it |
|---|---|---|---|
| Protocol shape | ~2.8k lines | `barrel_a2a_message`, `_part`, `_artifact`, `_task`, `_agent_card`, `_event`, `_error`, `_json`, `_jsonrpc`, `_rest`, `_sse`, `_validate`, `_task_state`, `_version`, `_extensions`, `_tenant`, `_time`, `_id` | Mechanical. Each is accessors over a wire JSON map, or one table from the specification. Check against the spec section named in the module header, not against your intuition. |
| Self-contained algorithms | ~2.4k lines | `barrel_a2a_jsonschema` (JSON Schema 2020-12), `_canonical` (RFC 8785), `_card_sign` (JWS), `_schema` | Skip on a first read. They implement published specifications, have their own test vectors, and never call the rest of the library. |
| Runtime machinery | ~5.7k lines | `barrel_a2a_server`, `_server_core`, `_http_engine`, `_listener`, `_task_proc`, `_task_registry`, `_ctx`, `_auth`, `_push`, `_push_delivery`, `_client`, `_client_http`, `_remote_task` | This is where every subtle bug will be. Read `invariants.md` and `messages.md` before changing any of it. |

## Reading order

1. `README.md` for what the library does, then `docs/architecture.md`
   for the process tree and the two request flows.
2. `src/barrel_a2a.erl`. Small, and it defines the vocabulary: the
   eleven operations, the task states, the roles, the binding names.
3. `src/barrel_a2a_task_state.erl`. The state machine as one table.
   Everything about task behaviour follows from it.
4. `src/barrel_a2a_server_core.erl`, top to bottom. `call/4` is the
   pipeline every request goes through; `dispatch/2` is one clause per
   operation. Ignore the helpers on the first pass.
5. `src/barrel_a2a_task_proc.erl`. One process per task. Read the
   header, then the record, then `handle_result/2`.
6. `src/barrel_a2a_http_engine.erl` for how a binding turns into calls
   on the core, and `src/barrel_a2a_listener.erl` for how bytes turn
   into a request. Both are thin over `h1`/`h2`.
7. `guides/embedding.md` last. It states the contracts the engine and
   the core expose, which is a good check that you read them right.

Do not start with `barrel_a2a_client`. The client is a separate world
that only meets the server on the wire; read it when you need it.

## Where a change lands

| You want to | Read and change |
|---|---|
| Add or alter a protocol operation | `docs/internals/adding-an-operation.md`, then the eight sites it names |
| Change how a task behaves | `_task_state` (the table), `_task_proc` (the process), `_ctx` (what a handler can do) |
| Change what goes on the wire | `_rest` (paths), `_jsonrpc` (envelopes), `_http_engine` (headers, SSE), `_error` (status mapping) |
| Add a binding (gRPC, WebSocket) | `_server_core:call/4` and `_client_transport`; nothing else. See `guides/embedding.md` |
| Serve from another HTTP server | `_http_engine:handle/6` and the responder type in `_listener`. See `guides/embedding.md` |
| Change validation | `_validate` (required fields, oneof, enums) and `_schema` (the published JSON Schema) |
| Store tasks somewhere else | `_task_store` behaviour only. The registry keeps filtering and pagination |
| Change auth or scoping | `_auth` (who the caller is), `_server_core` `authorized/2` and `scope_filter/2` (what they see) |

## What the tests are for

The suites are the safety net that makes this code changeable. They
are large (1264 eunit, 84 Common Test, 26 Python interop) and they run
in about two minutes. Change something, run them, and the ones that
fail tell you which contract you moved.

- `barrel_a2a_e2e_SUITE` runs a real server and a real client over
  each binding. If a change is visible to a user, it fails here.
- `barrel_a2a_embed_SUITE` drives the engine and the core directly.
  It is the contract test for embedders.
- `barrel_a2a_schema_vectors_SUITE` validates everything the server
  emits against the official JSON Schema.
- `barrel_a2a_python_interop_SUITE` runs the reference `a2a-sdk`
  against us in both directions. It only runs with `INTEROP_PYTHON`
  set; run it before touching anything that shapes the wire.

`guides/testing.md` has the commands.

## Module header standard

When you add a module, or substantially change one of the runtime
modules, the header should answer these in this order. The existing
headers of `barrel_a2a_task_store` and `barrel_a2a_task_proc` are the
models.

1. What the module owns, in one sentence.
2. The shape of its state or of the maps it passes, with a comment per
   non-obvious field.
3. Who calls it and whom it calls, when that is not obvious from the
   exports.
4. The specification section it implements, by number.
5. The invariants it relies on, or a pointer to `invariants.md`.
6. How to exercise it in isolation, if that is not just "call it".

Prose belongs where a reader would otherwise have to reconstruct
intent. An accessor like `barrel_a2a_task:id/1` needs a spec and
nothing else.
