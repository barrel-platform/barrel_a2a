# 0003. Tasks materialize lazily

## Context

A2A lets an agent answer a message either with a `Task` that the client
then follows, or with a bare `Message` and no task at all (spec 3.1.1).
The library cannot know which one a handler will produce until the
handler returns, but it must already have somewhere to run that handler
and to collect ctx calls.

## Decision

A task process is created for every incoming message, but starts
*unmaterialized*: no registry row, no `Task` event, invisible to
`GetTask`, `ListTasks`, `CancelTask` and `SubscribeToTask`. It
materializes on the first thing that implies a task exists: any
`barrel_a2a_ctx` call, a handler result other than `{message, _}`, an
explicit `materialize/1` from a caller that must answer with a task, or
a follow-up message.

## Consequences

A handler that returns `{message, M}` produces a direct message reply
with no task, and a protocol error thrown before materialization
becomes a real error response rather than a failed task. Both are what
the specification asks for, and neither needs the handler to declare
its intent up front.

The price is that "does this task exist" has two answers depending on
where you stand, and that several code paths branch on `materialized`.
Moving when materialization happens changes the wire contract without
failing a test: that is case A in the list of dangerous edits, and the
reason the flag is documented on the record field.

The alternative, deciding from the request (for instance treating
`SendStreamingMessage` as always producing a task), was rejected
because it makes the handler's choice depend on how the caller asked
rather than on what the agent did.
