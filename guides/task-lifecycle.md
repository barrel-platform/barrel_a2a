# Task Lifecycle

This guide describes the task state machine, which handler results
and client actions drive it, and what a task looks like when it is
paused, canceled or finished. You need it when your agent does more
than answer in one step.

## States

Eight states, from `barrel_a2a_task_state:states/0`, exposed as
short atoms (`barrel_a2a_task:state/1`) and as
`TASK_STATE_*` strings on the wire:

```
submitted      -> working | input_required | auth_required
                | completed | failed | canceled | rejected
working        -> working | input_required | auth_required
                | completed | failed | canceled
input_required -> working | canceled | failed
auth_required  -> working | canceled | failed
terminal       -> nothing
```

`working -> working` lets a handler attach a progress message without
changing state. Terminal states are `completed`, `failed`, `canceled`,
`rejected` (`barrel_a2a_task_state:is_terminal/1`); interrupted
states are `input_required`, `auth_required` (`is_interrupted/1`). A
task accepts follow-up messages and cancellation while it is not
terminal.

## What moves a task

| Trigger | Transition |
|---|---|
| task created | `submitted` |
| `barrel_a2a_ctx:status(Ctx, working)` | `working` |
| `barrel_a2a_ctx:artifact/2,3`, `message/2` | stays `working` (first call moves to `working`) |
| handler returns `{ok, Result}` | `completed` with `Result` as artifact |
| handler returns `ok` | unchanged, or `completed` when still `working` or `submitted` |
| handler returns `{input_required, M}` | `input_required`, `M` as status message |
| handler returns `{auth_required, M}` | `auth_required`, `M` as status message |
| handler returns `{reject, M}` | `rejected` |
| handler returns `{error, R}` or crashes | `failed` |
| client `CancelTask` | `canceled` (after `handle_cancel/1`, worker killed) |
| follow-up message | `working` when the handler makes a ctx call, then as above |
| `barrel_a2a_ctx:resume/1,2` | `working`, handler re-invoked |

A handler can also set states directly with
`barrel_a2a_ctx:status(Ctx, completed, #{message => <<"done">>})` and
return `ok`. Invalid transitions return `{error, {invalid_transition, From, To}}`.

## Pausing for input

```erlang
handle_message(Ctx, Message) ->
    case barrel_a2a_ctx:is_follow_up(Ctx) of
        false -> {input_required, <<"Which file?">>};
        true -> {ok, process(barrel_a2a_message:text(Message))}
    end.
```

The client sees `input_required` with the question in
`barrel_a2a_task:status_message/1`, then answers with
`barrel_a2a_client:send/3` (`task_id`, `context_id`) or
`barrel_a2a_remote_task:send/2`. A message whose `contextId` does not
match the task is refused with `invalid_params`.

## Pausing for authorization

For credentials obtained out of band (spec 7.6), keep the ctx and
resume without a client message:

```erlang
handle_message(Ctx, Message) ->
    case my_auth:has_grant(barrel_a2a_ctx:principal(Ctx)) of
        true ->
            {ok, do_work(Message)};
        false ->
            my_auth:await_grant(Ctx),  %% stores Ctx; calls resume later
            {auth_required, <<"Approve access at https://example/consent">>}
    end.

%% elsewhere, when the grant arrives:
ok = barrel_a2a_ctx:resume(Ctx).
```

`resume/1` re-invokes the handler with the original message;
`resume/2` with a message of your own. Open streams stay open across
the pause and see the continuation.

## Cancellation

```erlang
handle_message(Ctx, _Message) ->
    work_loop(Ctx).

work_loop(Ctx) ->
    case barrel_a2a_ctx:cancelled(Ctx) of
        true -> ok;
        false -> step(), work_loop(Ctx)
    end.
```

`CancelTask` on a non-terminal task calls `handle_cancel/1` (module
handlers only), kills the worker and transitions to `canceled`.
Canceling an already canceled task returns the task again;
canceling any other terminal task returns `task_not_cancelable`.

## History and artifacts

- `history` holds the user messages and the agent status messages, in
  order. `historyLength` on `GetTask`, `ListTasks` and
  `SendMessageConfiguration` trims it: unset keeps everything (or the
  server `history_default`), `0` omits the field, `N` keeps the last
  N.
- Artifacts are keyed by `artifactId`; a chunk with `append => true`
  concatenates parts onto the existing one, otherwise it replaces it.
- `ListTasks` omits `artifacts` unless `includeArtifacts` is true.

## After the end

The task process exits shortly after a terminal state. The snapshot
stays in the registry for `task_ttl` (default one hour) and is served
by `GetTask` and `ListTasks`. Subscribing to a finished task fails with
`unsupported_operation`; sending it a message fails the same way.

## Notes

- Task ids and context ids are server-generated UUIDs. A client may
  propose a `contextId` (`accept_client_context_id`, default `true`)
  but never a `taskId` for a new task.
- Tasks are owned by the principal that created them; see
  [Authentication](authentication.md) for scoping.
