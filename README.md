# barrel_a2a

Agent2Agent (A2A) protocol v1.0 for Erlang/OTP: the protocol objects,
a server that exposes your agent over the JSON-RPC and HTTP+JSON
bindings, and a client that talks to any A2A agent. The server runs
on `h1`/`h2` (HTTP/1.1 and HTTP/2 on one port), the client on
`hackney`. Requires OTP 27 or later.

## What A2A is

A2A is a protocol for one autonomous agent to communicate and
collaborate with another autonomous agent: discover it through an
Agent Card, send it messages, follow the task it runs, receive the
artifacts it produces. It differs from MCP: MCP lets an agent invoke
tools and capabilities, A2A lets agents talk to each other as peers.
This library implements the A2A boundary only; see
[a2a-protocol.org](https://a2a-protocol.org) for the specification.

## What this library does

- Protocol objects as plain JSON maps (wire shape, binary camelCase
  keys) with accessor modules: `barrel_a2a_message`, `barrel_a2a_part`,
  `barrel_a2a_artifact`, `barrel_a2a_task`, `barrel_a2a_agent_card`,
  `barrel_a2a_event`, `barrel_a2a_error`.
- A server (`barrel_a2a_server`) with one handler per agent, task
  processes, streaming over SSE, push notifications, authentication
  and authorization hooks, extended cards, card signing, extensions,
  versioning and multi-tenancy, on both HTTP bindings.
- A client (`barrel_a2a_client`, `barrel_a2a_remote_task`) with card
  discovery and caching, signature verification, interface selection,
  blocking and streaming sends, follow-ups, task listing, cancel,
  push configs and a webhook receiver helper.
- Validation: structural checks plus JSON Schema 2020-12 validation
  against the official `a2a.json`.

## What it deliberately does not do

- No agent runtime, planner, memory, MCP implementation, LLM
  abstraction or orchestration. The application owns agent execution;
  the library exposes it over A2A.
- No gRPC binding in this package. It is planned as `livery_grpc_a2a`,
  a separate package on `livery_grpc`, built on the binding-neutral
  contracts described in [guides/embedding.md](guides/embedding.md).

## Installation

```erlang
{deps, [
    {barrel_a2a, "0.1.0"}
]}.
```

Or from git:

```erlang
{deps, [
    {barrel_a2a,
        {git, "https://github.com/barrel-platform/barrel_a2a.git", {tag, "v0.1.0"}}}
]}.
```

## Server quick start

```erlang
Card = barrel_a2a_agent_card:new(#{
    name => <<"Echo Agent">>,
    description => <<"Repeats whatever you say">>,
    version => <<"1.0.0">>,
    skills => [#{id => <<"echo">>, name => <<"Echo">>, tags => [<<"demo">>]}]
}),
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => fun(_Ctx, Message) -> {ok, barrel_a2a_message:text(Message)} end,
    http => #{port => 8080}
}).
```

The card is served at `http://127.0.0.1:8080/.well-known/agent-card.json`,
JSON-RPC at `/a2a/jsonrpc`, REST under `/a2a/v1`. See
[guides/server.md](guides/server.md).

## Client quick start

```erlang
{ok, Agent} = barrel_a2a_client:connect(<<"http://127.0.0.1:8080">>),
Card = barrel_a2a_client:card(Agent),

%% Blocking send: the task (or a direct message) when it settles.
{ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"hello">>),
completed = barrel_a2a_task:state(Task),

%% Streaming: a remote task handle that pushes events to a process.
{ok, RT} = barrel_a2a_client:start(Agent, <<"review this repository">>),
ok = barrel_a2a_remote_task:stream_to(RT, self()),
{ok, Final} = barrel_a2a_remote_task:result(RT, 60000),
Text = barrel_a2a_remote_task:text(RT).
```

See [guides/client.md](guides/client.md).

## Task lifecycle

Every transition goes through `barrel_a2a_task_state:transition/2`:

```
submitted      -> working | input_required | auth_required
                | completed | failed | canceled | rejected
working        -> working | input_required | auth_required
                | completed | failed | canceled
input_required -> working | canceled | failed
auth_required  -> working | canceled | failed
terminal       -> nothing
```

Handler results map to states:

| Result | State |
|---|---|
| `{ok, Result}` | `completed`, `Result` becomes the final artifact |
| `{message, Message}` | no task, a direct message reply |
| `{input_required, Message}` | `input_required`, next message re-enters the handler |
| `{auth_required, Message}` | `auth_required`, resumable with `barrel_a2a_ctx:resume/1` |
| `{reject, Message}` | `rejected` |
| `ok` | as left by the ctx calls; a task still `working` completes |
| `{error, Reason}` or a crash | `failed` |

See [guides/task-lifecycle.md](guides/task-lifecycle.md).

## Streaming

`SendStreamingMessage` and `SubscribeToTask` return SSE on both
bindings (JSON-RPC frames `{"jsonrpc":"2.0","id":..,"result":<StreamResponse>}`,
REST frames the bare `StreamResponse`). The stream opens with the
`Task` snapshot, then `statusUpdate` and `artifactUpdate` events, and
closes on a terminal state. Handlers publish with
`barrel_a2a_ctx:status/2,3`, `barrel_a2a_ctx:artifact/2,3` and
`barrel_a2a_ctx:message/2`. On the client `barrel_a2a_remote_task`
pushes events (`stream_to/2`) or lets you pull them (`next/2`), and
falls back to polling when the agent does not stream. See
[guides/streaming.md](guides/streaming.md).

## Push notifications

Enable with `push_notifications => #{...}` on the server; clients
register webhooks at send time or with
`barrel_a2a_client:create_push_config/3`, and decode deliveries with
`barrel_a2a_webhook:receive_notification/3`. Delivery is ordered per
config, retried with backoff, and guarded against SSRF. See
[guides/push-notifications.md](guides/push-notifications.md).

## Authentication hooks

Server side (`auth` option):

```erlang
none
| {bearer, fun((Token) -> {ok, Principal} | {error, unauthenticated | forbidden})}
| {api_key, HeaderName, fun((Key) -> ...)}
| {basic, fun((User, Password) -> ...)}
| {Module, State}                     %% Module:authenticate(Request, State)
| fun((Request) -> ...)               %% Request = #{headers, op, binding, peer}
```

Client side (`auth` option): `{bearer, Token | fun(() -> Token)}`,
`{api_key, HeaderName, Value}`, `{basic, User, Password}`,
`fun((Op) -> Headers)` or `none`; or `credentials`, a map keyed by
security scheme name resolved against the card. See
[guides/authentication.md](guides/authentication.md).

## Architecture

- Protocol objects: `barrel_a2a_message`, `_part`, `_artifact`,
  `_task`, `_task_state`, `_agent_card`, `_event`, `_error`.
- Codec and validation: `barrel_a2a_json`, `_jsonrpc`, `_rest`,
  `_sse`, `_validate`, `_schema`, `_jsonschema`, `_canonical`,
  `_card_sign`, `_version`, `_extensions`, `_tenant`.
- Server: `barrel_a2a_listener` (accept, TLS, ALPN, h1/h2) ->
  `barrel_a2a_http_engine` (routes, bindings, SSE loops) ->
  `barrel_a2a_server_core` (auth, tenant, version, extensions,
  capabilities, validation, scoping, operations) ->
  `barrel_a2a_task_proc` (one process per task) and `barrel_a2a_push`.
- Client: `barrel_a2a_client` (facade) -> `barrel_a2a_client_transport`
  behaviour (`barrel_a2a_client_http` for both HTTP bindings) ->
  `barrel_a2a_remote_task`.

The engine never touches sockets: it writes through a responder map
(`reply`, `stream_start`, `stream_chunk`, `stream_end`,
`disconnected`) that the listener builds over h1/h2 and that an
embedding application such as `livery_a2a` builds over its own
adapter. Embedding into livery uses `barrel_a2a_server:start/2` with
`listen => false`, `barrel_a2a_server:engine_config/2`,
`barrel_a2a_http_engine:routes/1` and
`barrel_a2a_http_engine:handle/6`. See
[docs/architecture.md](docs/architecture.md) and
[guides/embedding.md](guides/embedding.md).

## Spec coverage

Every operation, object and normative behaviour of A2A v1.0.1 is
handled here, except the gRPC binding which is planned as
`livery_grpc_a2a`. The section-by-section table is in
[docs/features.md](docs/features.md).

## Development

```bash
make compile       # rebar3 compile
make lint          # rebar3 lint
make xref          # rebar3 xref
make dialyzer      # rebar3 dialyzer
make eunit         # rebar3 eunit
make ct            # rebar3 ct
make examples-test # build and test examples/* against this checkout
make interop-python # a2a-sdk interop suite (needs python3)
make check         # fmt compile lint xref dialyzer eunit ct
```

## License

Apache-2.0
