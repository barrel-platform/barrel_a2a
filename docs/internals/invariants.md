# Invariants

These are the rules the runtime relies on and that a reader cannot see
from one module. Each one names the code that enforces it and what
breaks if you move it. Check this page before changing anything under
"runtime machinery" in `tour.md`; the invariant comments in the source
point back here.

Most of these have the same failure signature: nothing crashes, no
test fails in a quiet system, and the protocol is subtly wrong under
load or on a slow machine. That is why they are written down.

## Task process

**T1. Subscribe strictly before run.**
`barrel_a2a_task_proc:subscribe/2` is a `gen_server:call` and
`run/1` is a `gen_server:cast`. That asymmetry is the only thing
guaranteeing the subscription exists before the handler can produce
events (`barrel_a2a_server_core.erl` around the `subscribe` then `run`
pairs, and `subscribe_new/1`). Reverse them, or make `subscribe` a
cast, and a fast handler finishes before anyone is listening: the
blocking caller waits its whole `blocking_timeout` and the streaming
caller gets an open stream that never produces an event.

**T2. Registry write precedes event publication.**
`do_materialize/1` and `transition/3` in `barrel_a2a_task_proc` write
the registry row and only then publish the event. A client that reacts
to an SSE event by calling `GetTask` must not read a staler state than
the event it just saw. Swapping the two lines breaks read-your-writes
and no unit test notices, because both orders are correct when nothing
else is running.

**T3. The linger delay must outlive the reply path.**
`finish/1` arms `?LINGER_MS` (100 ms) before the process stops. The
blocking reply path calls back into the task process *after* it has
consumed the terminal event (`await/2`, then `materialize/1` to fetch
the final snapshot), and the core's snapshot helper may ask a task
that has just finished for its latest state. Shorten the linger, or
stop immediately on terminal, and a completed task is reported to the
caller as `internal_error` / `task_process_down` whenever the request
process is descheduled for longer than the delay.

**T4. `handle_cancel/1` must not call `barrel_a2a_ctx`.**
`stop_worker/1` blocks the task process in a selective receive for up
to `?CANCEL_GRACE_MS` (5 s) while the cancel callback runs. Every
`barrel_a2a_ctx` action is a `gen_server:call` to that same blocked
process with the default 5 s timeout, so the callback would time out
and crash. `handle_cancel/1` is for releasing external resources.

**T5. `unlink` before `kill`.**
`stop_worker/1` unlinks the worker before killing it. Without the
unlink the exit signal races back into the task process, which traps
exits and would turn a deliberate cancel into a failed task.

**T6. One worker per task; handlers are never concurrent.**
`maybe_start_worker/1` starts a worker only when there is none, and
follow-up messages queue. A handler can therefore keep per-task state
in its own process without locking.

**T7. Worker results are matched by reference, not by pid.**
`{worker_result, Ref, Result}` carries the `Ref` stored in the state.
A result from a worker that was killed during cancel arrives with a
stale reference and must fall through to the catch-all clause.

**T8. Nothing is published after a terminal event.**
`barrel_a2a_event:is_final/1` treats terminal states and a direct
`message` as final. Consumers act on it irreversibly: the engine
writes `stream_end` and returns, the push worker deletes its config
and stops. A post-terminal event is invisible to streams and webhooks
but still lands in the registry, so `GetTask` and the stream disagree
with no error anywhere.

**T9. The task process is the only writer of its registry row.**
Two deliberate exceptions: the registry repairs rows when a persistent
store opens, and the server closes the registry while task processes
may still be alive, which is why the task process tolerates a closed
table when it writes its final row.

**T10. `push_notify` runs inside the task process.**
The fan-out to webhooks happens on the task process, so a slow push
hook stalls task progress and every open stream for that task.

## Engine and transport

**E1. The engine owns the mailbox of the process that calls it.**
`barrel_a2a_http_engine:handle/6` runs in the caller's process, blocks
there for the whole life of a stream, subscribes that process to task
events, and drains leftovers afterwards. An embedder that calls it
from a long-lived worker loses that worker's other messages. Give it a
process per request, as the listener and `livery_a2a` do.

**E2. The responder closures must be called from the request process.**
The listener tracks "have headers gone out" in the process dictionary
(`headers_sent`), shared between the request function and the closures,
and h2 delivers stream events only to the pid registered as the stream
handler. Handing a responder to another process loses the 500 fallback
and every disconnect notification.

**E3. A stream must be answered before anything is written.**
`stream/5` calls `Subscribe(Pid)` first precisely so that a refusal
(terminal task, gone task) can still be answered with a normal HTTP
status. Once `stream_start` has been called the status is committed and
an error can only travel as an in-band event.

**E4. Ordering of events is Erlang message ordering, nothing else.**
All events for a task are sent by the task process to each subscriber
with `!`, and there is no sequence number on the wire. Anything that
introduces a second sender, or a queue in between, breaks ordering
silently.

## Client

**C1. A transport sends `done` or an error exactly once, after the
last event.** The contract is in `barrel_a2a_client_transport`. The
HTTP transport does not send `done` after a transport error or after a
cancel; `barrel_a2a_remote_task` survives this because it settles on an
error and because it is the only thing that cancels a stream. A new
transport should not rely on that.

**C2. Opening a stream is asynchronous.** `barrel_a2a_client_http`
spawns the stream process and returns before the request is issued, so
failures arrive as `{a2a_stream, Ref, {error, _}}`, never as a return
value from `stream/5`.

**C3. A paused task does not settle an attached handle.**
`barrel_a2a_remote_task` keeps `attach_state` so that attaching to a
task that is already `input_required` does not immediately report that
state as the outcome, and `rearm` un-settles the handle when the task
goes back to `working` after a follow-up. Removing either makes
`result/2` return a stale answer.

## Configuration

**F1. The server's `persistent_term` entry must outlive in-flight
requests.** `barrel_a2a_server:config/1` is read on every request with
no process hop, and erased in `terminate/2`. Reads that can happen
after a server stops go through the guarded helper in the engine.

**F2. Building the config reads it back.** The `init/1` of
`barrel_a2a_server` writes a partial config, starts the listener (whose
handler builds an engine config by reading the term), then writes the
complete one. The write is repeated at each step deliberately; do not
collapse it without breaking that cycle another way.

**F3. A failed `init/1` has to clean up after itself.** Returning
`{stop, _}` from `init/1`, or crashing in it, does not run
`terminate/2`. `undo/1` erases the `persistent_term` entry, closes the
registry and stops a listener that already started. It reads the
partial config back from `persistent_term`, which is why F2's repeated
write matters for more than the listener.

**F4. The task and push supervisors are linked, not supervised.** The
server starts them from its own `init/1` (see
`barrel_a2a_server_inst_sup` for why). It therefore traps exits and
turns the death of either into its own `{stop, _}`, so the instance
supervisor rebuilds the whole server rather than leaving one holding a
dead pid.
