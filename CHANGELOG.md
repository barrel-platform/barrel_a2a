# Changelog

## Unreleased

- Pluggable task storage: `barrel_a2a_task_store` behaviour with ETS (default) and DETS backends; `task_store` server option.

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
