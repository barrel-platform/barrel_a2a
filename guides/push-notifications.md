# Push Notifications

This guide shows how a server delivers task events to a client
webhook and how a client registers and receives them. You need it
when the client cannot keep a stream open, for tasks that run longer
than a connection should.

## Enable on the server

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    push_notifications => #{
        require_https => true,
        allow => [<<"hooks.partner.example">>],   %% or fun((Host) -> boolean())
        ssrf_guard => true,
        timeout => 15000,
        max_failures => 5,
        backoff => {1000, 2},
        max_backoff => 60000
    }
}).
```

Any map (even `#{}`) enables the capability; the card then advertises
`pushNotifications`. Defaults: `ssrf_guard` true, `require_https`
false, `timeout` 15000 ms, `max_failures` 5, `max_queue` 1000,
`backoff` `{1000, 2}`, `max_backoff` 60000 ms. A receiver slow enough
to fill `max_queue` is treated as failing: delivery is at-least-once,
so events are never silently discarded to make room. The queue depth
counts toward `max_failures` like any other failure, and a receiver
that never keeps up loses its configuration. Hosts in `allow` skip the SSRF guard; the
guard refuses `localhost`, URLs with credentials, and hosts resolving
to loopback, private, link-local, CGNAT or unspecified addresses.

## Register from the client

At send time:

```erlang
PushCfg = #{
    url => <<"https://hooks.partner.example/a2a">>,
    token => <<"tok-1">>,
    authentication => #{scheme => <<"Bearer">>, credentials => <<"hook-secret">>}
},
{ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"long job">>, #{
    push_notification_config => PushCfg,
    return_immediately => true
}).
```

Or on an existing task:

```erlang
TaskId = barrel_a2a_task:id(Task),
{ok, Created} = barrel_a2a_client:create_push_config(Agent, TaskId, PushCfg),
ConfigId = maps:get(<<"id">>, Created),
{ok, Created} = barrel_a2a_client:get_push_config(Agent, TaskId, ConfigId),
{ok, #{configs := Configs, next_page_token := Next}} =
    barrel_a2a_client:list_push_configs(Agent, TaskId, #{page_size => 10}),
ok = barrel_a2a_client:delete_push_config(Agent, TaskId, ConfigId).
```

The server assigns the config id. Configs are removed when the task
ends (after the final delivery) or on delete; delete is idempotent.
A server without the capability answers
`push_notification_not_supported`.

## Receive on the webhook

Every event is a `POST` of the `StreamResponse` JSON with
`Content-Type: application/a2a+json`, the config `authentication`
as `Authorization: <scheme> <credentials>` and the config `token` as
`X-A2A-Notification-Token`. Decode it with `barrel_a2a_webhook` from
any HTTP server:

```erlang
handle_post(Headers, Body) ->
    case barrel_a2a_webhook:receive_notification(Headers, Body, #{
        token => <<"tok-1">>,
        authorization => <<"Bearer hook-secret">>,     %% or fun((Value | undefined) -> boolean())
        task_ids => [TaskId],
        validate_schema => true
    }) of
        {ok, Event} ->
            handle_event(barrel_a2a_event:kind(Event), Event),
            barrel_a2a_webhook:ack();                  %% {200, Headers, <<>>}
        {error, unauthenticated} -> {401, [], <<>>};
        {error, unexpected_task} -> {404, [], <<>>};
        {error, bad_payload} -> {400, [], <<>>}
    end.
```

Answer 2xx to acknowledge. Anything else, a timeout or a connection
error is retried.

## Delivery guarantees

One worker per config sends events one at a time; the next event
waits for the acknowledgement of the previous one. Failures retry the
same event with exponential backoff; after `max_failures`
consecutive failures the config is dropped. Delivery is therefore
ordered per webhook and at-least-once: keep your handler idempotent
on `taskId` plus the event content.

## Across restarts

Configs live in memory by default, so a restart loses them and the
webhook never hears how its task ends. When you persist tasks
(`task_store`), persist their push configs too, with any
`barrel_a2a_task_store`:

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    push_notifications => #{},
    task_store => {barrel_a2a_task_store_dets, #{file => "/var/lib/my_agent/tasks.dets"}},
    push_config_store => {barrel_a2a_task_store_dets, #{file => "/var/lib/my_agent/push.dets"}}
}).
```

- Every create and delete is written through; configs are read back on
  start, so `GetTaskPushNotificationConfig` and delivery work on the
  same ids after a restart.
- A config whose task is gone (expired) is dropped on start.
- A config whose task is terminal was never cleared by its worker, so
  its final event was not delivered: the task ended as the node went
  down, or the restart failed it. The server sends the final
  `statusUpdate` again on start, then the config is cleared as usual.
- A resumed task (`resume` option, see [Server](server.md)) notifies
  its webhooks like any live task.
- Use a separate file from `task_store`. The option is ignored when
  `push_notifications` is off.

## Notes

- The first event delivered is the `Task` snapshot, then
  `statusUpdate` and `artifactUpdate` events, then the final
  `statusUpdate`; `barrel_a2a_event:is_final/1` tells you when to
  stop expecting more.
- An `http_post` fun in the options replaces hackney for tests
  (`fun((Url, Headers, Body) -> {ok, Status} | {error, Reason})`).
- `barrel_a2a_push:validate_url/2` applies the same URL policy
  outside the server if you need to pre-check a webhook.
