# Streaming

This guide explains how task updates flow as Server-Sent Events on
both HTTP bindings, how a handler produces them and how a client
consumes them. You need it for long-running tasks where the caller
wants progress and partial artifacts before the end.

## On the wire

`SendStreamingMessage` (`POST {base}/jsonrpc` with method
`SendStreamingMessage`, or `POST {base}/v1/message:stream`) and
`SubscribeToTask` (`POST {base}/v1/tasks/{id}:subscribe`) answer with
`Content-Type: text/event-stream`. Each `data:` line carries one
`StreamResponse`, wrapping exactly one of `task`, `message`,
`statusUpdate` or `artifactUpdate`:

```
JSON-RPC:  data: {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{...}}}
REST:      data: {"statusUpdate":{...}}
```

The first event is the `Task` snapshot, the stream closes after a
terminal state or a direct `message`, and a `: keepalive` comment is
sent every `keepalive_ms` (default 15 s) while idle. Every subscriber
of a task sees the same events in the same order.

## Producing events (server)

Each ctx call in the handler becomes one event:

```erlang
handle_message(Ctx, Message) ->
    ok = barrel_a2a_ctx:status(Ctx, working, #{message => <<"Reading">>}),   %% statusUpdate
    Words = binary:split(barrel_a2a_message:text(Message), <<" ">>, [global]),
    Total = length(Words),
    lists:foldl(
        fun(Word, N) ->
            ok = barrel_a2a_ctx:artifact(Ctx, <<Word/binary, " ok\n">>, #{ %% artifactUpdate
                artifact_id => <<"review">>,
                name => <<"review.txt">>,
                append => N > 1,
                last_chunk => N =:= Total
            }),
            N + 1
        end,
        1,
        Words
    ),
    ok.   %% still working -> completed (final statusUpdate)
```

`append => true` concatenates parts onto the artifact with the same
`artifact_id`; `last_chunk => true` marks the end. Both sides merge
chunks with these flags (`barrel_a2a_task:put_artifact/3`).

Streaming is on by default; `streaming => false` on the server
removes the capability and makes streaming operations fail with
`unsupported_operation`.

## Consuming events (client)

`barrel_a2a_client:start/2,3` returns a `barrel_a2a_remote_task`
process. Push mode:

```erlang
{ok, RT} = barrel_a2a_client:start(Agent, Text),
ok = barrel_a2a_remote_task:stream_to(RT, self()),
loop(RT).

loop(RT) ->
    receive
        {a2a_event, RT, #{<<"task">> := Task}} ->
            loop(RT);
        {a2a_event, RT, #{<<"statusUpdate">> := #{<<"status">> := Status}}} ->
            io:format("~s~n", [maps:get(<<"state">>, Status)]),
            loop(RT);
        {a2a_event, RT, #{<<"artifactUpdate">> := #{<<"artifact">> := A}}} ->
            io:format("~s", [barrel_a2a_artifact:text(A)]),
            loop(RT);
        {a2a_done, RT, {message, Message}} ->
            {ok, barrel_a2a_message:text(Message)};
        {a2a_done, RT, Task} ->
            {ok, Task};
        {a2a_error, RT, Error} ->
            {error, Error}
    end.
```

Pull mode:

```erlang
{ok, Ev} = barrel_a2a_remote_task:next(RT, 5000),   %% eof once settled
{ok, Task} = barrel_a2a_remote_task:result(RT, 60000).
```

"Settled" means terminal, interrupted (`input_required`,
`auth_required`) or a direct message. `stream_to/2` replays events
queued before the listener was attached. `barrel_a2a_event:kind/1`
returns `task | message | status_update | artifact_update`.

Attach to a running task from anywhere:

```erlang
{ok, RT} = barrel_a2a_client:subscribe(Agent, TaskId),
ok = barrel_a2a_remote_task:stream_to(RT, self()).
```

After `input_required`, `barrel_a2a_remote_task:send(RT, Text)`
opens a new stream for the follow-up on the same handle.

## Polling fallback

When the card does not declare `streaming`, the handle sends with
`returnImmediately` and polls `GetTask` every second
(`poll_interval_ms` in the connect options changes it). A stream that
closes without a terminal event also falls back to polling, so
`result/2` always ends.

## Raw streams

For your own event loop, bypass the handle:

```erlang
{ok, Ref} = barrel_a2a_client:stream(Agent, subscribe_to_task, #{<<"id">> => TaskId}, self()),
receive
    {a2a_stream, Ref, {event, StreamResponse}} -> ok;
    {a2a_stream, Ref, {error, Error}} -> ok;
    {a2a_stream, Ref, done} -> ok
end,
ok = barrel_a2a_client:cancel_stream(Agent, Ref).
```

## Notes

- Subscribing to a terminal task is refused with
  `unsupported_operation`; read it with `get_task` instead.
- Disconnecting a stream does not cancel the task; call
  `barrel_a2a_remote_task:cancel/1` or `barrel_a2a_client:cancel/2`.
- On the server the SSE loop runs in the request process; a client
  disconnect ends it and unsubscribes it from the task.
