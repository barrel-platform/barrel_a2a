# Changelog

## 0.2.0

Conformance work against A2A v1.0.1, plus the maintainer documentation.
Four of the changes are visible to a running deployment; see below.

### Breaking changes

- `blocking_timeout` now defaults to `infinity`. A send with
  `returnImmediately` unset or false waits for a terminal or interrupted
  state, as the specification requires, and ends early if the peer
  disconnects. Set `blocking_timeout => 30000` to keep the old deadline,
  remembering that answering a blocking send with a non-final task is a
  deviation.
- `GetExtendedAgentCard` answers `unauthenticated` when the caller is
  anonymous. A server running `auth => none` has no authenticated agent
  to serve it to; configure an authentication scheme, or supply a
  `principal` in the request context if your embedding authenticates the
  peer itself.
- A duplicate JSON key now keeps the last occurrence, as ProtoJSON
  requires. It previously kept the first.
- An explicit `ListTasks` `pageSize` outside 1 to 100 is rejected with
  `invalid_params` instead of being clamped. The range is fixed by the
  specification. `ListTaskPushNotificationConfigs` is unaffected: the
  specification gives it no bounds.
- Unknown request fields are ignored by default, for forward
  compatibility with a later minor version. Set
  `validate_schema => strict` to reject them as before.

### Conformance

- `ListTasks` applies the authorization rule inside the registry filter,
  so `totalSize` and `nextPageToken` no longer describe rows the caller
  cannot see, and `statusTimestampAfter` is inclusive as specified.
- `validate_schema => all` now validates streamed events as well as
  unary replies; an off-schema event travels as an in-band error and
  ends the stream.
- Push delivery never discards an event to make room: a full queue
  counts as a delivery failure, so a receiver that cannot keep up loses
  its configuration through `max_failures` rather than silently missing
  notifications.

### Fixed

- A request field sent as JSON `null` is treated as unset, which is
  what ProtoJSON requires ("null is accepted and treated as the default
  value"). It was rejected as a malformed value. Found by the
  JavaScript SDK, whose serializer emits `"pageSize": null` for an
  unset page size.

### Resource bounds

- Every buffer a peer can fill is bounded with a stated policy: task
  follow-ups (`max_task_queue`, answering `rate_limited`), stream
  subscribers (`max_subscriber_queue`), push delivery queue and worker
  mailbox (`max_queue`, counted as failures), client stream listeners
  (`max_listener_queue`), client replies and Agent Cards (`max_body`),
  and webhook responses.
- `max_history` optionally caps stored task history. It defaults to
  `unlimited`, matching the reference SDK, where `historyLength`
  truncates the reply rather than the stored task.
- A failed `init/1` erases its `persistent_term` entry, closes the
  registry and stops a listener it had already opened. Losing the task
  supervisor, the push supervisor or a process-backed store's writer now
  stops the server so the instance supervisor rebuilds it.
- The DETS store names its table after the file path instead of an atom
  derived from it, which leaked one atom per distinct file.
- `task_ttl => 0` no longer schedules a zero-delay timer in a loop.

### Added

- Pluggable task storage: `barrel_a2a_task_store` behaviour with ETS (default) and DETS backends; `task_store` server option. A process-backed store reports its process through the optional `owner/1` so the server can watch it.
- Maintainer documentation: `docs/internals/` (code tour, invariants, message catalogue, adding an operation) and `docs/decisions/` (why the library is shaped as it is), published as ex_doc extras.
- `docs/features.md` lists the deliberate deviations from a literal reading of the specification, with the reasoning for each.
- `make check-vectors` compares the vendored schema and proto against what upstream publishes, run weekly rather than on every pull request.

### Changed

- The REST binding reads a `:verb` segment strictly as a custom method (AIP-136): a path binding no longer matches an unescaped colon, so an unknown verb is 404 and a known verb reached with the wrong method is 405 naming that method. Percent-encoded colon ids are unaffected.

## 0.1.0

First release. Implements A2A v1.0.1 without the gRPC binding.

- Protocol objects as wire JSON maps with accessor modules for
  messages, parts, artifacts, tasks, events, agent cards and errors.
- Structural validation plus JSON Schema 2020-12 validation against
  the official `a2a.json`.
- Server: `barrel_a2a_server` with a single handler per agent,
  task processes, JSON-RPC and HTTP+JSON bindings on one `h1`/`h2`
  listener (HTTP/1.1 and HTTP/2, TLS with ALPN), SSE streaming,
  push notifications with ordered retried delivery and SSRF guard,
  authentication and authorization hooks, extended cards, card
  signing, extensions, version negotiation, multi-tenancy, rate
  limit hook, HSTS, card caching headers.
- Client: `barrel_a2a_client` and `barrel_a2a_remote_task` over
  `hackney` with card discovery and conditional refresh, signature
  verification, interface selection, blocking and streaming sends,
  follow-ups, task listing, cancel, push config management, retries
  for idempotent operations; `barrel_a2a_webhook` receiver helper.
- Embedding contracts: `listen => false`, `engine_config/2`,
  `barrel_a2a_http_engine:routes/1` and `handle/6` over a responder
  map, `barrel_a2a_server_core:call/4` and the
  `barrel_a2a_client_transport` behaviour for other bindings.
- Tests: eunit suites per module, end-to-end Common Test suite on
  both bindings with and without TLS and tenant, official JSON Schema
  test suite, spec schema vectors, examples, Python a2a-sdk interop
  target.
