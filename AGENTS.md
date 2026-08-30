# Agents

Instructions for AI coding agents working on this project.

## Project Overview

barrel_a2a is an Erlang library implementing the Agent2Agent (A2A)
protocol, version 1.0, for both server and client sides: protocol
objects, the JSON-RPC and HTTP+JSON bindings with SSE streaming, task
lifecycle, push notifications, Agent Card discovery and signing. It
implements the A2A boundary only: no agent runtime, planner, memory,
MCP or LLM abstraction. One OTP application; `src/` is flat and every
module is prefixed `barrel_a2a_`:

```
src/    Protocol objects: barrel_a2a (constants/types), _agent_card,
        _message, _part, _artifact, _task, _task_state, _event, _error
        Codec and validation: _json, _jsonrpc, _rest, _sse, _validate,
        _schema (+ _jsonschema, the 2020-12 validator), _canonical
        (RFC 8785), _card_sign (JWS), _version, _extensions, _tenant
        Server: _server (facade), _server_sup / _server_inst_sup,
        _server_core (binding-neutral dispatcher), _http_engine
        (card, JSON-RPC, REST, SSE over a responder), _listener
        (h1/h2 serve_socket hand-off) / _listener_sup, _task_proc /
        _task_sup / _task_registry, _ctx, _handler, _auth,
        _push / _push_delivery / _push_sup,
        _task_store (behaviour) + _task_store_ets / _task_store_dets
        Client: _client (facade), _remote_task, _client_transport
        (behaviour), _client_http (hackney), _client_auth, _webhook
priv/   schema/a2a.json (official JSON Schema), jsonschema/ (metaschema)
test/   EUnit + Common Test (e2e over both bindings, schema vectors,
        official JSON Schema suite, Python interop)
guides/ ex_doc guides; docs/ spec coverage and architecture
examples/ Runnable example apps (echo, streaming)
```

The HTTP server is built on the sibling hex libraries `h1` and `h2`
(HTTP/1.1 + HTTP/2 on one port via ALPN, `serve_socket/2`), the
client on `hackney`. Do not reimplement HTTP/1, HTTP/2 or HPACK here.
The gRPC binding is not part of this package; it is built on these
contracts in `livery_grpc` (see `guides/embedding.md`).

Authoritative behaviour is the test suites under `test/`, the spec
(`docs/a2a.proto` and https://a2a-protocol.org/latest/specification),
and the module docs.

Read before changing the runtime: `docs/internals/tour.md` (where to
start, what a change touches), `docs/internals/invariants.md` (the
rules no single module shows, such as subscribe before run and
registry write before event publication),
`docs/internals/messages.md` (every inter-process message) and
`docs/internals/adding-an-operation.md`. `docs/decisions/` records why
the library is shaped as it is; add a record rather than editing one
when a decision changes.

## Required Checks

Every change must be formatted and pass all checks before committing
or opening a PR:

```bash
rebar3 fmt          # Auto-format (always run first)
rebar3 compile      # Must compile cleanly (warnings_as_errors)
rebar3 lint         # Elvis linter
rebar3 xref         # Cross-reference analysis
rebar3 dialyzer     # Type checking
rebar3 eunit        # Unit tests
rebar3 ct           # Common Test (e2e, schema, embed suites)
```

`make check` runs them all. CI runs `format`, `lint`, `xref` and
`dialyzer` as distinct jobs alongside `tests`, `examples` and the
Python `interop` job, all gated on `compile`.

## Build & Development Commands

```bash
rebar3 compile                                  # Build
rebar3 shell                                    # Boot a dev shell
rebar3 ct --suite=test/barrel_a2a_e2e_SUITE     # One suite
rebar3 eunit --module=barrel_a2a_sse_tests      # One eunit module
rebar3 fmt --check                              # Format check
make examples-test                              # Example apps
make interop-python                             # a2a-sdk interop
```

## Architecture

### Request flow

Listener (or an embedder such as livery_a2a) reads the body and calls
`barrel_a2a_http_engine:handle/6` with a responder map in the request
process. The engine parses the binding (JSON-RPC or REST), builds a
request context (headers, version, extensions, tenant) and calls
`barrel_a2a_server_core:call/4`, which performs rate limiting, auth,
tenant, version and extension negotiation, capability validation,
request validation (structural then JSON Schema), authorization
scoping and the operation. Streaming replies return a subscribe fun;
the engine subscribes the request process and writes SSE frames until
the task ends or the peer disconnects.

### Tasks

One `barrel_a2a_task_proc` per task runs the application handler in a
linked worker, validates every transition through
`barrel_a2a_task_state`, keeps history and artifacts, fans events out
to subscribers and push workers, and updates the registry row used by
GetTask and ListTasks. Tasks start unmaterialized so a handler can
answer with a direct Message.

### Conventions

- Protocol objects are the wire JSON maps (binary camelCase keys).
  Accessor modules wrap them; there is no internal representation.
- Every state transition goes through `barrel_a2a_task_state`.
- Task rows go through a `barrel_a2a_task_store`; the DETS store is an
  ETS working copy with an asynchronous flush, never a synchronous
  disk write on the request path.
- Auth, authorization and rate limiting are hooks; the library never
  decides policy.
- Run `rebar3 fmt` before committing; elvis must pass. New per-module
  elvis ignores belong in `rebar.config` with a one-line reason.
- Commit messages: one imperative subject line, body only for
  non-obvious "why". No diff restatement, no "generated by" /
  "co-authored-by" trailers.
- Do not use the em-dash character in code, docs, or messages.
- `rebar.lock` is committed: CI keys its build cache on the lock hash.
- Vendored test data (`test/json_schema_suite`, `test/schema_vectors`,
  `priv/jsonschema`) is updated deliberately; see the VENDORED.md
  files.
