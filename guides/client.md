# Talking to an Agent

This guide covers `barrel_a2a_client`: connecting to a remote agent,
sending work, following it, and managing its tasks. You need it when
your application delegates to another agent over A2A.

## Connect

```erlang
{ok, Agent} = barrel_a2a_client:connect(<<"https://agent.example">>, #{
    prefer => [jsonrpc, rest],
    auth => {bearer, fun my_tokens:current/0},
    extensions => [<<"https://example.com/ext/traces">>],
    timeout => 30000,
    retries => 2,
    verify_signatures => #{keys => [Jwk], required => true},
    transport_opts => #{ssl_options => [{cacertfile, "ca.pem"}]}
}).
```

`connect/2` fetches `/.well-known/agent-card.json` (override with
`card_path`), verifies the signature when `verify_signatures` is set,
selects an interface, and opens the transport. Options: `prefer`
(binding order, atoms or wire names), `transports` (extra
`{BindingName, Module}` pairs implementing
`barrel_a2a_client_transport`), `auth` or `credentials` (see
[Authentication](authentication.md)), `version` (default `<<"1.0">>`),
`extensions`, `timeout`, `retries` and `retry_backoff_ms` for
idempotent operations, `validate_schema` (check replies, default
`false`), `card_path`, `transport_opts` (`ssl_options`, `proxy`,
`hackney_options`).

If you already have a card, skip discovery:

```erlang
{ok, Agent} = barrel_a2a_client:from_card(Card, #{prefer => [rest]}).
```

Inspect the handle:

```erlang
Card = barrel_a2a_client:card(Agent),
Skills = barrel_a2a_client:skills(Agent),
Interface = barrel_a2a_client:interface(Agent),
<<"JSONRPC">> = barrel_a2a_client:binding(Agent),
{ok, Agent1} = barrel_a2a_client:refresh_card(Agent),      %% conditional GET with ETag
{ok, Agent2} = barrel_a2a_client:extended_card(Agent).     %% authenticated card
```

## Send and wait

`send/2,3` is the blocking `SendMessage`. The content is text, a
part, a list of parts, or a full message built with
`barrel_a2a_message:new/2`.

```erlang
{ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"summarise this">>, #{
    context_id => <<"conv-1">>,
    accepted_output_modes => [<<"text/plain">>],
    history_length => 5,
    metadata => #{<<"trace">> => <<"abc">>}
}),
case barrel_a2a_task:state(Task) of
    completed -> [barrel_a2a_artifact:text(A) || A <- barrel_a2a_task:artifacts(Task)];
    input_required -> barrel_a2a_message:text(barrel_a2a_task:status_message(Task));
    failed -> barrel_a2a_task:status_message(Task)
end.
```

A direct reply comes back as `{ok, {message, Message}}`. With
`return_immediately => true` the server answers as soon as the task
exists; poll it with `get_task/2,3`.

Follow up on a paused task by naming it:

```erlang
{ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"the second one">>, #{
    task_id => barrel_a2a_task:id(Task),
    context_id => barrel_a2a_task:context_id(Task)
}).
```

Send options: `context_id`, `task_id`, `message_id`, `metadata`
(message), `request_metadata` (request), `accepted_output_modes`,
`history_length`, `return_immediately`, `push_notification_config`,
`reference_task_ids`, `timeout`.

## Start and follow

`start/2,3` returns a `barrel_a2a_remote_task` handle that streams
when the agent supports it and polls otherwise:

```erlang
{ok, RT} = barrel_a2a_client:start(Agent, <<"review this repository">>),
ok = barrel_a2a_remote_task:stream_to(RT, self()),
{ok, Final} = barrel_a2a_remote_task:result(RT, 60000),
Text = barrel_a2a_remote_task:text(RT),
ok = barrel_a2a_remote_task:send(RT, <<"more input">>),      %% follow-up on input_required
{ok, Canceled} = barrel_a2a_remote_task:cancel(RT),
ok = barrel_a2a_remote_task:stop(RT).
```

See [Streaming](streaming.md) for the event messages.

## Tasks

```erlang
{ok, Task} = barrel_a2a_client:get_task(Agent, TaskId, #{history_length => 0}),
{ok, #{tasks := Tasks, next_page_token := Next, total_size := N}} =
    barrel_a2a_client:list_tasks(Agent, #{
        context_id => <<"conv-1">>,
        status => working,
        page_size => 20,
        page_token => <<>>,
        history_length => 0,
        status_timestamp_after => <<"2026-01-01T00:00:00Z">>,
        include_artifacts => true
    }),
{ok, Canceled} = barrel_a2a_client:cancel(Agent, TaskId, #{metadata => #{}}),
{ok, RT} = barrel_a2a_client:subscribe(Agent, TaskId).
```

Push configs: `create_push_config/3`, `get_push_config/3`,
`list_push_configs/3`, `delete_push_config/3`; see
[Push notifications](push-notifications.md).

## Errors

Every call returns `{error, Error}` with `Error` a map
`#{type, message, details}`; `type` is the A2A error as a snake_case
atom (`task_not_found`, `unsupported_operation`,
`content_type_not_supported`, `version_not_supported`,
`unauthenticated`, ...) or `transport` / `timeout` for client-side
failures. Retries apply only to `get_task`, `list_tasks`,
`get_push_config`, `list_push_configs` and `get_extended_agent_card`.

## Low level

`call/3,4` runs any unary operation with a raw request object;
`stream/4` opens a raw SSE stream; `headers/2` returns the headers the
client would send (credentials, `A2A-Version`, `A2A-Extensions`).

```erlang
{ok, Reply} = barrel_a2a_client:call(Agent, get_task, #{<<"id">> => TaskId}).
```

## Notes

- The handle is a map, not a process. `close/1` closes the transport;
  for the HTTP transport this is a no-op since hackney pools sockets.
- The `tenant` field of the selected interface is added to every
  request automatically.
