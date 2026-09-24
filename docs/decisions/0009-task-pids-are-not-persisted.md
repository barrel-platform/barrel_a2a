# 0009. Task pids are not persisted

## Context

A task row held the pid of its task process, because the registry row
was both the task record and the index from task id to process. With an
in-memory store that was harmless. With a persistent store every row
read back after a restart named a dead process, so the registry cleared
pids on open and checked each one with `is_process_alive/1` on read.

A store that replicates, or is shared between nodes, hands a node rows
written elsewhere, whose pids live on another node.
`is_process_alive/1` raises `badarg` on those, and the server start
failed as a whole.

## Decision

A pid only means something on the node and run that made it, so it
never reaches the store. `barrel_a2a_task_registry` keeps task pids in
an ETS table of its own, created next to the store on open, keyed by
task id, and merges them into the entries it returns. `insert/2` and
`update/2` write the row, then the pid, in the same call, so a reader
that sees the process also sees its row (T2).

## Consequences

- A store sees only task data, so persisting, replicating or sharing
  it is safe. Opening a store with rows from another node fails or
  resumes unfinished tasks, as after a restart.
- `repair` no longer rewrites rows to clear pids. A row written before
  0.2.2 still carries a `pid` key; it is dropped on open.
- `expire/2` keeps a finished row while its process lingers by asking
  the pid table, not the row.
- The registry handle is now opaque (a store handle plus the table).
  Stores are unchanged: they already treated rows as opaque maps.
