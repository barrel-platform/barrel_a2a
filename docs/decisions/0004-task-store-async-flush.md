# 0004. The persistent task store is ETS with an async flush

## Context

Tasks lived only in an ETS table owned by the server process, so a
restart lost every snapshot. Persistence was needed for deployments
where a client polls `GetTask` after the server has been restarted. The
first implementation wrote straight to DETS on every update.

## Consequences of that first attempt

Every task transition became a synchronous disk write on the path that
also fans events out to open streams. That is the wrong place for the
disk: the task process is the single writer for its row and the single
publisher for its events, so a slow write delays both.

## Decision

`barrel_a2a_task_store_dets` keeps an ETS table as the working copy and
a writer process that batches dirty rows to a DETS file, in the spirit
of mnesia disc copies. Reads and writes hit ETS; the writer flushes
every `flush_interval` (default 1000 ms) or once `flush_max` rows are
dirty (default 500). `sync => true` makes each write wait for its
flush, `flush/1` forces one, `open/1` loads the file, `close/1`
flushes.

## Consequences

The request path never waits on the disk, and durability is a tunable
rather than a fixed cost. A crash between flushes loses at most the
last interval of updates, which is acceptable for task snapshots and is
stated in `guides/server.md`.

Rows left by a previous run are repaired on open: terminal tasks keep
their snapshot, tasks that were still running become `failed` with a
status message saying so, since their workers are gone and cannot be
resumed.

Everything above is behind `barrel_a2a_task_store`, so a deployment
that wants synchronous durability or a shared database implements the
behaviour instead. The registry keeps filtering, ordering and
pagination, so a store only has to persist rows by id.
