# 0006. Processes the server owns are linked, not supervisor children

## Context

A server instance needs three collaborators that outlive no request but
must die with it: `barrel_a2a_task_sup`, `barrel_a2a_push_sup`, and,
when the task store is process-backed, the store's writer.

The obvious arrangement is to make all of them children of
`barrel_a2a_server_inst_sup` alongside the server. That was the first
attempt and it deadlocked. A supervisor starts its children one at a
time, and `supervisor:which_children/1` is a call to the supervisor
process, which is busy inside `start_children` until the last child
returns from its `init/1`. So the server, started as a child, cannot ask
its own supervisor for a sibling: the supervisor is blocked waiting for
the server, and the server is blocked waiting for the supervisor.

Working around it means either resolving siblings lazily on first use,
which puts a lookup on the request path, or introducing a fourth child
that owns a registry table the others write to and the server reads.
Both are more machinery than the problem needs.

## Decision

The server process `start_link`s the task and push supervisors from its
own `init/1` and records their pids in its configuration, which is where
every reader already finds them. A process-backed task store reports its
writer through the optional `barrel_a2a_task_store:owner/1`, and the
server treats it the same way.

`barrel_a2a_server_inst_sup` therefore supervises exactly one child, the
server, and is `one_for_one`.

## Consequences

The lifecycle is closed, and each part of it is a rule somewhere:

- **Ownership.** The server holds `task_sup`, `push_sup` and
  `store_owner` in `cfg()`, and links all three.
- **Startup rollback.** `init/1` returning `{stop, _}` does not run
  `terminate/2`, so `undo/1` erases the `persistent_term` entry, closes
  the registry and stops a listener that already started. The catch is
  wide enough to cover a crash, not only a thrown option error
  (invariant F3).
- **Shutdown propagation.** The linked supervisors are the server's
  children in the OTP sense: an exit from their parent shuts them down
  normally, and `terminate/2` stops the listener and closes the registry.
- **Restart.** The server traps exits and turns the death of any of the
  three into its own `{stop, _}`, so the instance supervisor rebuilds the
  whole instance rather than leaving the server holding a dead pid. This
  matters most for the store writer, which owns the ETS working copy:
  its death destroys the data (invariant F4).
- **Evidence.** `losing_the_task_supervisor_stops_the_server` and
  `losing_the_task_store_writer_stops_the_server` in
  `test/barrel_a2a_embed_SUITE.erl` kill each one and assert the server
  goes with it; `failed_start_leaves_nothing_behind` asserts the rollback
  leaves no `persistent_term` entry and no orphan listener.

A2A prescribes no supervision shape, and an audit that asks for every
process to be a direct supervisor child is applying a rule Erlang systems
do not follow: linked and monitored owned processes are ordinary. The
question worth asking of this design is not whether the processes are
children but whether their death is noticed, and it is.

Revisit this if a reader needs the collaborators without the server, or
if the server ever wants them to survive its own restart. Neither is true
today.
