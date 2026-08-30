# Getting Started

This guide takes you from an empty project to an A2A agent you can
talk to from another Erlang node, in three steps. Follow it the first
time you use barrel_a2a; the other guides go deeper into each part.

## Installation

Add the dependency to `rebar.config`:

```erlang
{deps, [
    {barrel_a2a, "0.1.0"}
]}.
```

Or track git:

```erlang
{deps, [
    {barrel_a2a,
        {git, "https://github.com/barrel-platform/barrel_a2a.git", {branch, "main"}}}
]}.
```

The application needs OTP 27 or later (it uses the built-in `json`
module) and pulls `h1`, `h2` and `hackney`.

## 1. Describe your agent

An Agent Card tells clients who you are and what you can do.
`barrel_a2a_agent_card:new/1` accepts snake_case atom keys and fills
the required defaults.

```erlang
card() ->
    barrel_a2a_agent_card:new(#{
        name => <<"Echo Agent">>,
        description => <<"Repeats whatever you say">>,
        version => <<"1.0.0">>,
        skills => [
            #{
                id => <<"echo">>,
                name => <<"Echo">>,
                description => <<"Returns the received text as an artifact">>,
                tags => [<<"demo">>]
            }
        ]
    }).
```

## 2. Start a server

The handler is a `fun((Ctx, Message) -> Result)` or a module
implementing `barrel_a2a_handler`. `{ok, Text}` completes the task
with one text artifact.

```erlang
{ok, Server} = barrel_a2a_server:start(card(), #{
    handler => fun(_Ctx, Message) -> {ok, barrel_a2a_message:text(Message)} end,
    http => #{port => 8080}
}).
```

Check it from a shell:

```bash
curl http://127.0.0.1:8080/.well-known/agent-card.json

curl -X POST http://127.0.0.1:8080/a2a/jsonrpc \
  -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage",
       "params":{"message":{"messageId":"m1","role":"ROLE_USER",
                            "parts":[{"text":"hello"}]}}}'
```

`port => 0` picks a free port; read it with `barrel_a2a_server:port/1`
or the full base URL with `barrel_a2a_server:url/1`.

## 3. Talk to it

```erlang
{ok, Agent} = barrel_a2a_client:connect(<<"http://127.0.0.1:8080">>),
{ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"hello">>),
completed = barrel_a2a_task:state(Task),
[Artifact] = barrel_a2a_task:artifacts(Task),
<<"hello">> = barrel_a2a_artifact:text(Artifact),
ok = barrel_a2a_client:close(Agent).
```

`connect/1` fetches the card, picks the first interface it supports
(JSON-RPC or HTTP+JSON, in card order) and returns a handle map you
can share between processes.

## Notes

- Stop a server with `barrel_a2a_server:stop(Server)`. To run it under
  your own supervisor use `barrel_a2a_server:child_spec(Card, Opts)`.
- The two examples under `examples/` (`echo_server`, `echo_client`,
  `streaming_server`, `streaming_client`) are runnable with
  `make examples-setup` then `rebar3 shell` in the example directory.

## Next steps

- [Exposing an agent](server.md): options, handler results, the ctx API.
- [Talking to an agent](client.md): sends, follow-ups, listing, cancel.
- [Streaming](streaming.md): events on both sides.
- [Task lifecycle](task-lifecycle.md): states and transitions.
- [Authentication](authentication.md), [Push notifications](push-notifications.md),
  [Card signing](card-signing.md), [Multi-tenancy](multi-tenancy.md),
  [Extensions](extensions.md), [Embedding](embedding.md), [Testing](testing.md).
