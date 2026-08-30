# Message catalogue

Every message the library sends between processes, in one table. Use
it when you are reading a `receive` and cannot tell who sends what, or
when you add a process and need to know which vocabulary to reuse.

Nothing here is on the wire; these are Erlang messages inside one
node.

## Server side

| Message | From | To | Meaning |
|---|---|---|---|
| `{a2a_task_event, TaskId, StreamResponse}` | task process | every subscriber (a request process, or the push fan-out) | One protocol event: the initial `Task`, a status update, an artifact update, or a direct `Message`. Ordering is Erlang send ordering, see `invariants.md` E4 |
| `{a2a_task_error, TaskId, Error}` | task process | subscribers | A protocol error raised by the handler before the task materialized, so it can still be answered as an error rather than a failed task |
| `{worker_result, Ref, Result}` | handler worker | its task process | The return value of `handle_message/2`, including crashes already converted to data. `Ref` guards against a result from a killed worker |
| `linger_done` | task process | itself | The 100 ms grace after a terminal state is over; stop now |
| `{socket_ready, Socket}` / `{socket_failed, Reason}` | acceptor | the connection process it just spawned | Ownership of the accepted socket has been transferred, or could not be |
| `restart_acceptor` | listener | itself | An acceptor died; start a replacement after the backoff |
| `expire` | server | itself | Sweep task snapshots older than `task_ttl` |
| `flush` | DETS store writer | itself | The flush interval elapsed; write dirty rows to disk |
| `{dirty, Id, Op}` | any process writing a task row | DETS store writer | This row changed; include it in the next flush |

## Client side

| Message | From | To | Meaning |
|---|---|---|---|
| `{a2a_stream, Ref, {event, StreamResponse}}` | a client transport | the process that opened the stream (always a remote task) | One protocol event, decoded |
| `{a2a_stream, Ref, {error, Error}}` | a client transport | same | The stream failed. Terminates the stream |
| `{a2a_stream, Ref, done}` | a client transport | same | The stream ended cleanly. Sent exactly once, after the last event, see `invariants.md` C1 |
| `{a2a_cancel_stream, Owner}` | remote task | its stream process | Close the connection and exit without sending `done` |
| `{a2a_event, RemoteTask, StreamResponse}` | remote task | a listener registered with `stream_to/2` | The same event, handed to application code |
| `{a2a_done, RemoteTask, Task \| {message, M}}` | remote task | listeners | The task settled |
| `{a2a_error, RemoteTask, Error}` | remote task | listeners | The task or the stream failed |
| `poll` | remote task | itself | Time to call `GetTask` again, when the agent does not support streaming |

## Borrowed from the sibling libraries

The listener consumes these; their shapes are defined by `h1` and `h2`,
not here.

| Message | Meaning |
|---|---|
| `{h1_stream, StreamId, {data, Bin, Fin}}` / `{trailers, _}` / `{stream_reset, _}` | Request body and disconnect on HTTP/1.1 |
| `{h2, Conn, {data, StreamId, Bin, Fin}}` / `{trailers, ...}` / `{stream_reset, ...}` / `{closed, _}` / `{goaway, ...}` | The same on HTTP/2 |
| `{hackney_response, Ref, ...}` | Client responses, consumed by the HTTP transport |

## One event, three names

The same protocol event is called something different at each layer,
because each layer wraps the one below:

```
task process   --{a2a_task_event, TaskId, Ev}-->  request process (server)
                                                        |
                                                     the wire (SSE)
                                                        |
stream process --{a2a_stream, Ref, {event, Ev}}-->  remote task (client)
                                                        |
remote task    --{a2a_event, RT, Ev}------------->  your code
```

`Ev` is the same `StreamResponse` map throughout. When you see one of
the three tags, this is which side of the wire you are on.
