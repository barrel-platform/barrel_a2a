# Spec coverage

This page maps every section of the A2A v1.0.1 specification to the
module that handles it and its status. Use it to check whether a
behaviour you rely on is implemented before reading the code.
Everything is implemented in this package except the gRPC binding.

Status: `done` is implemented and tested here; `planned` is delivered
in another package.

| Spec | Handled by | Status |
|---|---|---|
| 3.1.1 SendMessage (blocking, `returnImmediately`, direct Message, follow-up, terminal rejection, contextId mismatch, ContentTypeNotSupported) | `barrel_a2a_server_core`, `barrel_a2a_task_proc` | done |
| 3.1.2 SendStreamingMessage (Message-only or Task lifecycle stream, close on terminal) | `barrel_a2a_server_core`, `barrel_a2a_http_engine` SSE loop | done |
| 3.1.3 GetTask (`historyLength` unset/0/N) | `barrel_a2a_server_core`, `barrel_a2a_task_registry` | done |
| 3.1.4 ListTasks (contextId, status, pageSize, pageToken, historyLength, statusTimestampAfter, includeArtifacts, nextPageToken, ordering, cursor pagination, authorization scoping) | `barrel_a2a_task_registry`, `barrel_a2a_server_core` | done |
| 3.1.5 CancelTask (idempotent, TaskNotCancelable, `handle_cancel/1`) | `barrel_a2a_server_core`, `barrel_a2a_task_proc`, `barrel_a2a_handler` | done |
| 3.1.6 SubscribeToTask (Task snapshot first, error on terminal, multiple streams, same order) | `barrel_a2a_task_proc` subscribers | done |
| 3.1.7 to 3.1.10 push notification configs (server id, get, list with pagination, idempotent delete, lifetime, PushNotificationNotSupported) | `barrel_a2a_push`, `barrel_a2a_server_core` | done |
| 3.1.11 GetExtendedAgentCard (auth required, UnsupportedOperation, ExtendedAgentCardNotConfigured, per-principal card) | `barrel_a2a_server_core`, `barrel_a2a_agent_card` | done |
| 3.2.2 SendMessageConfiguration (acceptedOutputModes, pushNotificationConfig at send time, historyLength, returnImmediately) | `barrel_a2a_server_core` | done |
| 3.2.6 service parameters (`A2A-Version`, `A2A-Extensions`, header or query) | `barrel_a2a_http_engine` -> request context | done |
| 3.3.1 idempotency (`messageId` duplicate detection) | `barrel_a2a_server_core` `dedupe_messages` option | done |
| 3.3.2 error model (code, message, details with `@type`, ErrorInfo, BadRequest field violations) | `barrel_a2a_error` | done |
| 3.3.4 capability validation | `barrel_a2a_server_core` | done |
| 3.4 contextId / taskId semantics (server ids, client contextId policy, taskId must exist, inferred contextId, mismatch rejected, referenceTaskIds passthrough) | `barrel_a2a_server_core`, `barrel_a2a_task_proc` | done |
| 3.5 update delivery (polling, streaming, push; ordered broadcast to every stream) | `barrel_a2a_task_proc`, `barrel_a2a_push` | done |
| 3.6 versioning (Major.Minor, empty = 0.3, VersionNotSupported, several interfaces per version) | `barrel_a2a_version`, `barrel_a2a_server_core` | done |
| 3.7 messages vs artifacts (results as artifacts, history) | `barrel_a2a_ctx`, `barrel_a2a_task_proc` | done |
| 4.1 to 4.2 data objects and events | `barrel_a2a_message`, `_part`, `_artifact`, `_task`, `_event`, `barrel_a2a_validate`, `barrel_a2a_schema` | done |
| 4.3 push payload (StreamResponse POST, `Authorization` from AuthenticationInfo, 2xx ack, at-least-once, backoff, timeout, stop after N failures) | `barrel_a2a_push_delivery` | done |
| 4.4 discovery objects (AgentCard, Provider, Capabilities, Extension, Skill, Interface, Signature) | `barrel_a2a_agent_card`, `barrel_a2a_validate`, `barrel_a2a_schema` | done |
| 4.5 security objects (every SecurityScheme variant, OAuthFlows, SecurityRequirement) | `barrel_a2a_agent_card:security_scheme/2`, `barrel_a2a_schema` | done |
| 4.6 extensions (declaration, client opt-in, echo of the active set, required enforcement, unknown ignored, no version fallback) | `barrel_a2a_extensions`, `barrel_a2a_ctx` | done |
| 5.1 to 5.4 binding equivalence, selection, method mapping, error mapping | both bindings share `barrel_a2a_server_core`; `barrel_a2a_error` | done |
| 5.5 to 5.7 naming, timestamps, field presence, unknown fields ignored | `barrel_a2a_json`, `barrel_a2a_validate`, `barrel_a2a_canonical` | done |
| 5.8 custom binding identification | `barrel_a2a_agent_card:select_interface/3`, client `transports` option | done |
| 6 workflows (basic, streaming, multi-turn, version error, listing, push, file exchange, structured data) | `test/barrel_a2a_e2e_SUITE.erl` mirrors each example | done |
| 7.1 to 7.5 authentication (TLS, verify every request, challenge info, authorization hook) | `barrel_a2a_auth`, `barrel_a2a_listener` TLS, HSTS | done |
| 7.6 in-task authorization (AUTH_REQUIRED with status message, messages accepted while paused, streams kept open, resume without a follow-up) | `barrel_a2a_task_state`, `barrel_a2a_ctx:resume/1`, `barrel_a2a_server_core` | done |
| 8.2 discovery well-known URI | `barrel_a2a_http_engine` route | done |
| 8.3 protocol declaration and client selection rules including tenant | `barrel_a2a_agent_card`, `barrel_a2a_client` | done |
| 8.4 card signing (RFC 8785 canonicalization with presence rules, JWS ES256/RS256/PS256, `protected`/`signature`/`header`, kid/jku, trusted keys or JWKS) | `barrel_a2a_canonical`, `barrel_a2a_card_sign` | done |
| 8.6 caching (Cache-Control max-age, ETag, Last-Modified, If-None-Match, client conditional refresh) | `barrel_a2a_http_engine`, `barrel_a2a_client:refresh_card/1` | done |
| 9 JSON-RPC binding (envelope, headers, SSE, error object, standard and A2A codes) | `barrel_a2a_jsonrpc`, `barrel_a2a_http_engine` | done |
| 10 gRPC binding | planned as `livery_grpc_a2a`, a separate package on `livery_grpc` | planned |
| 11 HTTP+JSON binding (paths, tenant prefix, `application/a2a+json`, query params, error body, SSE) | `barrel_a2a_rest`, `barrel_a2a_http_engine` | done |
| 12 custom bindings | `barrel_a2a_server_core:call/4` and `barrel_a2a_client_transport` are binding-neutral; see `guides/embedding.md` | done |
| 13.1 authorization scoping (owner principal on tasks; Get/List/Cancel/Subscribe/push scoped; not-found instead of forbidden) | `barrel_a2a_task_registry`, `barrel_a2a_server_core` `authorize` option | done |
| 13.2 push security (auth header, timeouts, backoff, SSRF checks for private, loopback and link-local addresses, allowlist, https option) | `barrel_a2a_push`, `barrel_a2a_push_delivery` | done |
| 13.3 extended card access control | `barrel_a2a_server_core`, `barrel_a2a_auth` | done |
| 13.4 best practices (TLS 1.2+/1.3, HSTS, body size limits, rate limit hook, auth failures logged without secrets) | `barrel_a2a_listener`, `barrel_a2a_http_engine`, `barrel_a2a_server` `rate_limit` option | done |
| 14 media type `application/a2a+json`, headers, well-known URI | `barrel_a2a_http_engine`, `barrel_a2a` | done |
| Multi-tenancy topic (request tenant must equal the interface tenant; `/{tenant}/` REST routes) | `barrel_a2a_tenant`, `barrel_a2a_http_engine`, `barrel_a2a_client` | done |

## Notes

- The task registry is in-memory (ETS) and snapshots expire after
  `task_ttl`. A persistent store is not part of this release.
- Client credentials are obtained out of band (7.3); the client only
  attaches them to requests.
