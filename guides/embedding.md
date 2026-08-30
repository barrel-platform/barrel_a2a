# Embedding

This guide describes the contracts for serving barrel_a2a from an
HTTP server you already run (the `livery_a2a` bridge) and for adding
another protocol binding such as gRPC (`livery_grpc_a2a`). You need
it when the built-in listener is not the right front door, or when you
implement a binding of your own (spec 12).

## The engine contract (livery_a2a)

Start the server without a listener and hand its routes to your
router. The engine never touches sockets: it writes through a
responder map.

### 1. Start without a listener

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    listen => false,
    url => <<"https://agent.example">>,   %% public base URL for supportedInterfaces
    base_path => <<"/a2a">>
}).
```

Tasks, the core, push delivery and the auth hook all run; only the
listener is missing. The card must end up with `supportedInterfaces`:
either declare them in `Card` or let `url` plus `base_path` fill
them. `barrel_a2a_server:child_spec(Card, Opts)` gives a child spec
for your supervisor.

### 2. Build the engine configuration once

```erlang
Config = barrel_a2a_server:engine_config(Server, #{
    base_path => <<"/a2a">>,
    card_path => <<"/.well-known/agent-card.json">>,
    card_cache_max_age => 3600,
    hsts => true,
    keepalive_ms => 15000,
    tenant => undefined
}).
```

`engine_config/2` merges the overrides on the server defaults and
validates them: a bad option raises `{invalid_engine_option, Key, Value}`
at mount time, not per request.

### 3. Mount the routes

```erlang
Routes = barrel_a2a_http_engine:routes(Config).
%% [{<<"GET">>, <<"/.well-known/agent-card.json">>},
%%  {<<"HEAD">>, <<"/.well-known/agent-card.json">>},
%%  {<<"POST">>, <<"/a2a/jsonrpc">>},
%%  {<<"POST">>, <<"/a2a/v1/message:send">>},
%%  {<<"GET">>, <<"/a2a/v1/tasks/:id">>}, ...]
```

Patterns use `:name` segments. The engine matches the raw path itself
and answers 404/405 on its own, so your router only needs to send
these paths to the handler.

A `:verb` suffix such as `/tasks/:id:cancel` is a custom method
(AIP-136), and the engine reads it strictly: an id never holds an
unescaped colon, so an unknown verb is 404 and a known verb reached
with the wrong method is 405 naming the method that serves it. A
router that cannot express the suffix can forward a catch-all
`/tasks/:id` and let the engine sort it out.

### 4. Handle a request

```erlang
ok = barrel_a2a_http_engine:handle(Method, Path, Headers, Body, Responder, Config).
```

`handle/6` runs in the caller's process, may block in `receive` for
an SSE stream, never spawns the stream owner, and returns after the
response is fully written. `Method` is an uppercase binary, `Path`
the raw path with its query string, `Headers` a list of
`{Name, Value}` binaries (any case), `Body` the full request body.
`Config` may carry two per-request keys: `principal` (skips the auth
hook when set, for a principal your own middleware established) and
`peer`.

### 5. The responder

```erlang
-type responder() :: #{
    reply        := fun((Status, Headers, iodata()) -> ok),
    stream_start := fun((Status, Headers) -> ok),
    stream_chunk := fun((iodata()) -> ok | {error, term()}),
    stream_end   := fun(() -> ok),
    disconnected := fun((term()) -> boolean())
}.
```

`reply/3` writes a complete response. `stream_start/2` writes the
headers of a streaming response, `stream_chunk/1` one SSE frame,
`stream_end/0` closes it. `disconnected/1` is called with every
message the stream loop receives that it does not recognize and must
return `true` for your transport's disconnect message; that and
`stream_chunk/1` returning `{error, _}` are the only ways the engine
learns the peer went away. Keepalive interval and body limits are in
`Config`, not in the responder. `barrel_a2a_listener` builds the same
map over h1/h2, so the contract cannot drift from the built-in path.

### Sketch of livery_a2a

```erlang
%% livery_a2a (livery repo)
-export([handler/1, router/1, router/2]).

router(Server) -> router(Server, #{}).
router(Server, Opts) ->
    Config = barrel_a2a_server:engine_config(Server, Opts),
    H = handler(Config),
    livery_router:compile([{M, P, H} || {M, P} <- barrel_a2a_http_engine:routes(Config)]).

handler(Config) -> fun(Req) -> serve(Req, Config) end.

serve(Req, Config) ->
    Adapter = livery_req:adapter(Req), Stream = livery_req:stream(Req),
    ok = barrel_a2a_http_engine:handle(
        livery_req:method(Req), livery_req:path(Req), livery_req:headers(Req), read_body(Req),
        responder(Adapter, Stream),
        Config#{principal => livery_ext:user(Req, undefined), peer => livery_req:peer(Req)}),
    #livery_resp{status = 200, body = taken_over}.

responder(Adapter, Stream) ->
    #{reply => fun(S, H, B) -> ... Adapter:send_headers/4 + send_data/3 ... end,
      stream_start => fun(S, H) -> ... end,
      stream_chunk => fun(D) -> Adapter:send_data(Stream, iolist_to_binary(D), #{end_stream => false}) end,
      stream_end => fun() -> ... end,
      disconnected => fun({livery_disconnect, _, _}) -> true; (_) -> false end}.
```

`read_body/1` is the livery three-way body reader
(`empty | {buffered, _} | {stream, Reader}` with
`livery_body:read_all/2`). Mount with
`livery:start_service(#{router => livery_router:nest(<<"/a2a">>, livery_a2a:router(Server)), ...})`
or merge into an existing router. Authentication can be livery
middleware (`livery_auth_bearer` sets `meta(user)`, passed as
`principal`) or barrel_a2a's own `auth` hook.

### Guarantees you can rely on

- No process is registered by name on the engine path; several
  servers coexist in one node, one per route tree. All state hangs
  off the `server` pid in `Config`.
- `application:ensure_all_started(barrel_a2a)` starts supervisors
  only; no listener, no singleton.
- `hackney`, `h1` and `h2` are the only runtime dependencies.

## The binding contract (livery_grpc_a2a)

### Server side

```erlang
Reply = barrel_a2a_server_core:call(Server, Op, Request, ReqCtx).
```

- `Op` is one of the eleven operations (`send_message`,
  `send_streaming_message`, `get_task`, `list_tasks`, `cancel_task`,
  `subscribe_to_task`, `create_push_config`, `get_push_config`,
  `list_push_configs`, `delete_push_config`,
  `get_extended_agent_card`).
- `Request` is the A2A JSON map of the request object (ProtoJSON
  shape, camelCase binary keys); a gRPC binding converts gpb maps to
  this shape and back.
- `ReqCtx = #{binding => grpc, headers => Metadata, version => Bin | undefined, extensions => [Uri], tenant => Bin | undefined, peer => term(), principal => term()}`.
  `headers` are the metadata pairs; `principal` is optional and skips
  the auth hook.
- `Reply` is `{ok, ReplyObject}`, `{stream, Subscribe}` or
  `{error, Error}`. `Subscribe(Pid)` registers `Pid` for
  `{a2a_task_event, TaskId, StreamResponse}` messages and returns
  `{ok, InitialEvents}` (the `Task` snapshot when one exists); the
  binding writes the initial events, then loops on the messages until
  `barrel_a2a_event:is_final/1` is true or `{a2a_task_error, TaskId, Error}`
  arrives.
- `barrel_a2a_error:grpc_status(Type)` gives the gRPC status atom
  (`not_found`, `failed_precondition`, `invalid_argument`,
  `unauthenticated`, ...) and `barrel_a2a_error:error_info/2` the
  `google.rpc.ErrorInfo` detail with the `reason` and the
  `a2a-protocol.org` domain. `barrel_a2a_server_core:active_extensions/2`
  returns the set to echo in trailing metadata.

### Client side

Implement `barrel_a2a_client_transport`:

```erlang
-module(livery_grpc_a2a_client).
-behaviour(barrel_a2a_client_transport).
-export([connect/2, call/4, stream/5, cancel_stream/2, close/1]).

connect(#{<<"url">> := Url}, Opts) -> {ok, #{channel => open(Url, Opts)}}.
call(Conn, Op, Request, #{headers := H, timeout := T}) -> ... {ok, ReplyJson} | {error, Error}.
stream(Conn, Op, Request, Owner, CallOpts) -> ... {ok, Ref}.   %% Owner gets the messages below
cancel_stream(Conn, Ref) -> ok.
close(Conn) -> ok.
```

The stream sends `Owner` the messages `{a2a_stream, Ref, {event, StreamResponse}}`,
`{a2a_stream, Ref, {error, Error}}` and `{a2a_stream, Ref, done}`,
exactly one `done` or error per stream after the last event. The
client builds the request object and the headers (credentials,
`A2A-Version`, `A2A-Extensions`) and passes them in `CallOpts`; the
transport only carries them.

Register it:

```erlang
{ok, Agent} = barrel_a2a_client:connect(Url, #{
    transports => [{<<"GRPC">>, livery_grpc_a2a_client}],
    prefer => [grpc, jsonrpc]
}).
```

`barrel_a2a_agent_card:select_interface/3` honours registered
bindings; card fetching, caching, signature verification, auth and
`barrel_a2a_remote_task` are shared by every transport.

## Custom bindings

The same two contracts serve any binding named by a URI in
`supportedInterfaces` (spec 5.8): call `barrel_a2a_server_core:call/4`
on the server, implement `barrel_a2a_client_transport` on the client,
and map `barrel_a2a_error` types with `jsonrpc_code/1`,
`http_status/1` or `grpc_status/1` as fits your wire.

## Notes

- Use `barrel_a2a_http_engine:sse_headers/0` if your bridge needs to
  set streaming headers itself.
- The engine expects header names in any case and lowercases them;
  the listener additionally prepends `x-a2a-scheme` (`http` or
  `https`) which the engine does not require.
