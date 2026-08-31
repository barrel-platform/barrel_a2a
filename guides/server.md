# Exposing an Agent

This guide shows how to put your agent behind an A2A server: write
the handler, publish task updates from it, and tune the server
options. You need it whenever another agent should be able to send
your agent work.

## The handler

One handler per server, invoked once per incoming message. It is a
`fun/2` or a module implementing `barrel_a2a_handler`:

```erlang
-module(my_agent).
-behaviour(barrel_a2a_handler).
-export([handle_message/2, handle_cancel/1]).

handle_message(Ctx, Message) ->
    Text = barrel_a2a_message:text(Message),
    ok = barrel_a2a_ctx:status(Ctx, working, #{message => <<"Thinking">>}),
    Answer = my_llm:complete(Text),
    {ok, Answer}.

%% Optional: called when a client cancels while the handler runs.
handle_cancel(Ctx) ->
    logger:info("task ~s canceled", [barrel_a2a_ctx:task_id(Ctx)]),
    ok.
```

Return values:

| Result | Effect |
|---|---|
| `{ok, Result}` | `Result` (text, a part, a list of parts or an artifact) becomes the final artifact; the task completes |
| `{message, Message}` | direct reply, no task (only before any ctx call created one) |
| `{input_required, Message \| Text}` | task pauses; the next message re-enters the handler |
| `{auth_required, Message \| Text}` | task pauses; resumable with `barrel_a2a_ctx:resume/1` |
| `{reject, Message \| Text}` | task is rejected |
| `ok` | the handler drove the state itself; a task still `working` completes |
| `{error, Message \| Text \| Error}` | task fails; an error from `barrel_a2a_error:new/2` is a protocol error |

A crash fails the task. `throw({a2a_error, barrel_a2a_error:new(Type, Msg)})`
surfaces a protocol error to the caller of `SendMessage`.

## Publishing updates from the handler

The ctx is a plain map; every action is a call to the task process,
so you can hand it to other processes.

```erlang
handle_message(Ctx, Message) ->
    ok = barrel_a2a_ctx:status(Ctx, working),
    ok = barrel_a2a_ctx:message(Ctx, <<"step 1 of 3">>),
    ok = barrel_a2a_ctx:artifact(Ctx, <<"first chunk ">>, #{
        artifact_id => <<"report">>, name => <<"report.txt">>
    }),
    ok = barrel_a2a_ctx:artifact(Ctx, <<"second chunk">>, #{
        artifact_id => <<"report">>, append => true, last_chunk => true
    }),
    Parts = [
        barrel_a2a_part:data(#{<<"score">> => 0.9}),
        barrel_a2a_part:file_url(<<"https://files.example/r.pdf">>, <<"application/pdf">>),
        barrel_a2a_part:file_bytes(Png, <<"image/png">>, #{filename => <<"a.png">>})
    ],
    ok = barrel_a2a_ctx:artifact(Ctx, Parts, #{name => <<"data">>}),
    ok.
```

Read the request with `barrel_a2a_ctx:message/1`, `task/1`
(`undefined` for a new task), `is_follow_up/1`, `task_id/1`,
`context_id/1`, `configuration/1`, `accepted_output_modes/1`,
`metadata/1`, `extensions/1`, `tenant/1`, `principal/1`, `binding/1`.
Poll `barrel_a2a_ctx:cancelled/1` in long loops.

## Multi-turn

A follow-up message on a task in `input_required`, `auth_required`
or `working` calls `handle_message/2` again with
`barrel_a2a_ctx:task/1` set to the current snapshot:

```erlang
handle_message(Ctx, Message) ->
    case barrel_a2a_ctx:is_follow_up(Ctx) of
        false -> {input_required, <<"Which repository?">>};
        true -> {ok, review(barrel_a2a_message:text(Message))}
    end.
```

## Starting the server

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    http => #{port => 8443, ip => {0, 0, 0, 0},
              tls => #{certfile => "cert.pem", keyfile => "key.pem"}},
    url => <<"https://agent.example">>,
    base_path => <<"/a2a">>,
    auth => {bearer, fun my_tokens:verify/1},
    authorize => owner,
    validate_schema => inbound,
    push_notifications => #{require_https => true},
    extended_card => fun(Principal) -> my_cards:for(Principal) end,
    blocking_timeout => 30000,
    task_ttl => 3600000,
    history_default => all
}).
```

Options:

- `handler` (required): module or `fun/2`.
- `http`: `#{port, ip, tls => #{certfile, keyfile, cacertfile, versions}, acceptors, max_connections, max_body, body_timeout, handshake_timeout}`. Default port 8080 on `127.0.0.1`.
- `listen`: `false` runs without a listener (see [Embedding](embedding.md)).
- `url`: public base URL written into `supportedInterfaces` when the card does not declare them; default derived from the bound address.
- `base_path`: mount point, default `/a2a` (JSON-RPC at `{base}/jsonrpc`, REST under `{base}/v1`).
- `card_path` (default `/.well-known/agent-card.json`), `card_cache_max_age` seconds (default 3600).
- `tenant`: see [Multi-tenancy](multi-tenancy.md).
- `auth`, `authorize` (`owner` default, `any`, or `fun((Principal, TaskEntry) -> boolean())`): see [Authentication](authentication.md).
- `validate_schema`: `inbound` (default: checks requests against the A2A
  schema and ignores fields it does not declare), `strict` (as `inbound`,
  but an undeclared field is rejected), `all` (replies too), `false`.
- `push_notifications`: `false` (default) or a map; enables the capability. See [Push notifications](push-notifications.md).
- `streaming`: capability flag, default `true`.
- `extended_card`: a card or `fun((Principal) -> Card)`; enables the capability. Served only to an authenticated caller.
- `signing`: `#{key, alg, kid, jku}`; see [Card signing](card-signing.md).
- `supported_versions` (default `[<<"1.0">>]`), `accept_legacy_version` (accept a missing `A2A-Version`, default `false`).
- `accept_client_context_id` (default `true`), `dedupe_messages` (default `false`; when true a repeated `messageId` returns the existing task).
- `blocking_timeout` ms (default 30000) or `infinity`: how long a
  blocking `SendMessage` waits for a terminal or interrupted state
  before answering with the current snapshot. `infinity` is what the
  specification asks for literally, at the cost of a request that never
  returns on its own.
- `task_ttl` ms (default 3600000): how long finished task snapshots stay readable.
- `task_store`: `{Module, Opts}` implementing `barrel_a2a_task_store`. Default `{barrel_a2a_task_store_ets, #{}}` (in memory). `{barrel_a2a_task_store_dets, #{file => "tasks.dets"}}` keeps tasks across restarts; see below.
- `history_default`: `all` or an integer applied when a request has no `historyLength`.
- `hsts` (default `true` with TLS), `rate_limit => fun((ReqCtx) -> ok | {error, RetryAfterSeconds})`.
- `keepalive_ms`: SSE keepalive interval, default 15000.

## Persisting tasks

Tasks live in memory by default and vanish with the server. To keep
finished tasks readable after a restart, use the DETS store:

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    task_store => {barrel_a2a_task_store_dets, #{file => "/var/lib/my_agent/tasks.dets"}}
}).
```

Notes:

- Rows are served from ETS; a writer process flushes dirty rows to the
  DETS file every `flush_interval` ms (default 1000) or once `flush_max`
  rows are dirty (default 500), so the request path never waits on
  the disk. `sync => true` makes each write wait for its flush.
  `barrel_a2a_task_store_dets:flush/1` forces a flush. One file per
  server.
- A task that was still running when the server stopped cannot resume:
  on open it is marked `failed` with the status message "Task interrupted
  by a server restart". Terminal tasks keep their snapshot, artifacts and
  history.
- Any other backend implements the `barrel_a2a_task_store` behaviour
  (`open/1`, `put/2`, `get/2`, `delete/2`, `all/1`, `close/1`) over
  rows keyed by task id; filtering and pagination stay in the registry.

## Managing the server

```erlang
Card = barrel_a2a_server:card(Server),          %% published card, signed and with interfaces
ok = barrel_a2a_server:update_card(Server, Card2),
Port = barrel_a2a_server:port(Server),
Url = barrel_a2a_server:url(Server),
ok = barrel_a2a_server:stop(Server).
```

Under your own supervisor:

```erlang
init([]) ->
    {ok, {#{strategy => one_for_one}, [
        barrel_a2a_server:child_spec(my_agent:card(), #{handler => my_agent, http => #{port => 8080}})
    ]}}.
```

## Notes

- Media types are checked against the card: a part whose `mediaType`
  is not among `defaultInputModes` or any skill `inputModes` is
  refused with `content_type_not_supported`, as is an
  `acceptedOutputModes` list that matches nothing the card produces.
- The card advertises `streaming`, `pushNotifications` and
  `extendedAgentCard` capabilities from the options; you do not set
  them by hand.
- Tasks live in ETS. They survive handler crashes but not a node
  restart.
