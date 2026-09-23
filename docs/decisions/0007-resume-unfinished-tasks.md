# 0007. The application may resume an unfinished task on start

## Context

With a persistent task store, a task that was running when the node
stopped is found again on open. Until 0.2.1 the registry failed every
such row ("Task interrupted by a server restart"): the handler ran in a
linked worker, so the work died with the process.

That holds only when the work is the process. An application that fronts
durable executions (hornbeam derives an execution id from the task id)
can find the work again after a restart and wait for its result. Failing
the task then lies to the client: the execution completes, and `GetTask`
on the original id never shows it.

## Decision

A server option `resume => fun((Task) -> {resume, Fun} | fail)`. The
registry asks it once per unfinished row on open. `fail`, a crash or any
other answer fails the row as before; `{resume, Fun}` keeps the row and
clears its pid. The server then starts an ordinary task process for each
resumed task, before its listener opens. The process starts from the
stored snapshot, already materialized, takes its row in `init/1`, moves
the task to `working`, and runs `Fun(Ctx)` in place of the handler. Its
answer goes through the same result path as a handler's.

Cancel differs in one respect: a resumed worker is not killed at once.
It gets the cancel grace period, during which `barrel_a2a_ctx:cancelled/1`
answers `true`, so the fun can stop the work it follows (invariant T12).
A handler worker is killed as before; changing that would change the
behaviour of every existing handler.

## Consequences

- No option, no change: the default path is the old one, pinned by
  `barrel_a2a_task_store_tests` and `barrel_a2a_resume_SUITE`.
- The task process stays the only writer of its row after start (T9).
- The decision fun runs inside server `init/1` and blocks start while it
  runs. It is meant to be a lookup; waiting belongs in `Fun`.
- A resumed task has no request: its ctx carries empty configuration,
  metadata and extensions, the server tenant, and the owner as principal.
- A task whose process fails to start stays unfinished in the store and
  is offered again on the next start.
