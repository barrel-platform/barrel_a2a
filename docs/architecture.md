# Architecture

This page describes how barrel_a2a is put together: the process tree,
the path a request takes through the server, the life of a task
process, and where validation and push delivery happen. Read it before
changing `src/` or embedding the engine in another HTTP server.

## Process tree

`application:ensure_all_started(barrel_a2a)` starts supervisors only.
No listener and no singleton process exists until you call
`barrel_a2a_server:start/2` or `barrel_a2a_client:connect/2`.

```
barrel_a2a_sup (one_for_one)
 |
 +-- barrel_a2a_listener_sup (one_for_one)
 |     +-- barrel_a2a_listener  {barrel_a2a_server, ServerPid}   one per listening server
 |           +-- acceptors -> connection processes -> h1/h2 request processes
 |
 +-- barrel_a2a_server_sup (simple_one_for_one)
 |     +-- barrel_a2a_server_inst_sup (rest_for_one)             one per server
 |           +-- task_sup  barrel_a2a_task_sup (simple_one_for_one)
 |           |     +-- barrel_a2a_task_proc                       one per task
 |           +-- push_sup  barrel_a2a_push_sup (simple_one_for_one)
 |           |     +-- barrel_a2a_push_delivery                   one per push config
 |           +-- server    barrel_a2a_server (gen_server)
 |
 +-- barrel_a2a_client_sup (simple_one_for_one)
       +-- client transport processes started on demand
```

`barrel_a2a_server` builds the configuration, stores it in
`persistent_term` under `{barrel_a2a_server, Pid}` so request
processes read it without a message hop, starts the listener (unless
`listen => false`), finalizes the card (interfaces, capabilities,
signature) and expires old task snapshots on a timer. `rest_for_one`
means a crash of the task supervisor restarts the push supervisor and
the server, but the server is the last child so the registry and the
push store it owns are rebuilt together.

`barrel_a2a_remote_task` handles on the client side are plain
`gen_server` processes started with `gen_server:start/3`; they monitor
the process that created them and stop when it exits.

## Request flow: unary call

```
socket --> barrel_a2a_listener (per request process, h1 or h2)
             read body (max_body, body_timeout)
             build responder map over the protocol module
             |
             v
           barrel_a2a_http_engine:handle(Method, Path, Headers, Body, Responder, Config)
             card route: cache headers, ETag, 304
             JSON-RPC: decode, classify, method -> op
             REST:     match route, tenant prefix, query and body -> request object
             build ReqCtx #{binding, headers, version, extensions, tenant, peer, principal?}
             |
             v
           barrel_a2a_server_core:call(Server, Op, Request, ReqCtx)
             rate_limit -> authenticate -> tenant -> version -> extensions
             -> capability -> validate (structural, then JSON Schema)
             -> authorization scoping -> dispatch(Op)
             |
             v
           barrel_a2a_task_registry / barrel_a2a_task_proc / barrel_a2a_push
             |
             v
           {ok, Reply} | {error, Error}
             |
             v
           engine encodes for the binding, adds A2A-Extensions, HSTS,
           WWW-Authenticate or Retry-After, and calls Responder.reply/3
```

A blocking `SendMessage` subscribes the request process to the task,
starts the handler and waits in `barrel_a2a_task_proc:await/2` until
the task is terminal or interrupted, a direct message arrives, or
`blocking_timeout` elapses (then the current snapshot is returned).

## Request flow: streaming call

`SendStreamingMessage` and `SubscribeToTask` make the core return
`{stream, Subscribe}`. The engine runs the stream in the request
process; nothing else is spawned:

```
engine                                   task process
  Subscribe(self())  ------------------>  subscribe + run (new task)
                     <------------------  {ok, [Task snapshot]} or {ok, []}
  Responder.stream_start(200, SSE hdrs)
  send initial events as SSE frames
  loop:
    receive {a2a_task_event, TaskId, Ev} -> stream_chunk(frame)
            final event                  -> stream_end, return
            {a2a_task_error, _, E}       -> error frame, stream_end
            'DOWN' of the task           -> stream_end
            Msg with Disconnected(Msg)   -> return
    after keepalive_ms                   -> ": keepalive" comment
```

A `stream_chunk` returning `{error, _}` ends the loop as well. The
JSON-RPC frame wraps each `StreamResponse` in a `result` envelope with
the request id; the REST frame is the bare object.

## Task process lifecycle

```
create (server_core, message without taskId)
  |
  |  unmaterialized: no registry row, no Task event
  |
  |  first ctx call | handler result other than {message, _}
  |  | materialize/1 (blocking and returnImmediately callers)
  v
materialized: registry row written, Task snapshot sent to subscribers
  |
  |  transitions via barrel_a2a_task_state:transition/2
  |  events {a2a_task_event, TaskId, StreamResponse} to subscribers
  |  and to the push fan-out, in order
  |
  +-- input_required | auth_required: handler worker gone, process alive,
  |     follow-up message or ctx:resume/1 starts a new worker
  |
  v
terminal (completed | failed | canceled | rejected)
  final snapshot to the registry, linger 100 ms, exit normal
  registry keeps the snapshot until task_ttl (in the configured
  barrel_a2a_task_store: ETS by default, DETS for persistence)
```

The handler runs in a worker process linked to the task process. Its
return value (`{ok, _}`, `{message, _}`, `{input_required, _}`,
`{auth_required, _}`, `{reject, _}`, `ok`, `{error, _}`) or its crash
is folded into a transition. A handler returning `{message, M}` on a
task that was never materialized produces a direct message reply and
the process exits without a registry row. Follow-up messages arriving
while a worker runs are queued; `handle_message/2` is never concurrent
for one task. Cancel stops the worker (after `handle_cancel/1` for
module handlers) and transitions to `canceled`.

## Bindings share the core

`barrel_a2a_server_core:call/4` is the only entry point for
operations. The JSON-RPC and REST paths of the engine differ solely in
how they parse the request and encode the reply; a gRPC binding calls
the same function with `binding => grpc` and metadata as headers. The
same applies to the client: `barrel_a2a_client` builds the request
object and headers and hands them to a `barrel_a2a_client_transport`
module.

## Where JSON Schema validation runs

- `priv/schema/a2a.json` is loaded into `persistent_term` on first
  use by `barrel_a2a_schema`; each `$defs` type is compiled once.
- Inbound: `barrel_a2a_server_core` runs the hand-written structural
  checks of `barrel_a2a_validate` first, then, with
  `validate_schema => inbound` (default) or `all`, validates the
  request against the schema type of the operation. Failures are
  `invalid_params` errors with `BadRequest` field violations.
- Outbound: with `validate_schema => all`, `barrel_a2a_http_engine`
  validates every unary reply and turns a mismatch into
  `invalid_agent_response` (HTTP 500).
- Client: with `validate_schema => true`, `barrel_a2a_client` checks
  each unary reply against the schema of the operation.
- `barrel_a2a_webhook:receive_notification/3` validates the push
  payload as a `StreamResponse` when `validate_schema => true`.

## Push delivery ordering

```
task process --event--> barrel_a2a_push:notify(Store, TaskId, Event)
                            |
                            +--> worker for config A  (queue, sequential POST)
                            +--> worker for config B  (queue, sequential POST)
```

Each push config gets its own `barrel_a2a_push_delivery` worker,
started on the first event and registered in the push store under
`{worker, ConfigId}`. A worker POSTs one event at a time; the next
event leaves the queue only after a 2xx. On failure it waits
`backoff` (initial ms times factor per failure, capped by
`max_backoff`) and retries the same event; after `max_failures`
consecutive failures it drops the config and stops. After a final
event (terminal state or direct message) the worker removes its config
and stops. Deleting a config stops its worker. The result is ordered,
at-least-once delivery per webhook.
