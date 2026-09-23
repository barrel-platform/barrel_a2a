# 0008. Push configs persist through the task store behaviour

## Context

Push notification configs lived in the server's ETS table only. With a
persistent task store a task could now outlive a restart (a resumed one,
0007, or a terminal snapshot), but its webhook configs did not:
`GetTaskPushNotificationConfig` answered not found for a config the
client created, and the webhook was never told how the task ended,
although delivery is at least once (4.3).

## Decision

A server option `push_config_store => {Module, Opts}` takes any
`barrel_a2a_task_store`. The stores already treated rows as opaque maps
keyed by `id`, so push configs are stored as `#{id, task_id, config}`
rows without a second behaviour; the callback types were widened to
say so.

The ETS table stays the working copy: delivery workers, the recorded
options and overflow counters never leave it. Only `create/4` and
`delete/3` write through, and the table is filled from the backing store
on open. The options are now recorded at open, so a worker started
after a restart uses the configured ones rather than the defaults.

On open, a config whose task is gone is dropped. A config whose task is
terminal was never cleared by its worker, which removes it only after
delivering the final event, so that event was not delivered: the server
sends the task's final status again.

## Consequences

- No option, no change: configs stay in memory.
- A process-backed push store is linked like the task store's writer
  (0006), and its death stops the server.
- The final status may reach a webhook twice if the node stopped between
  the delivery and the delete. At-least-once allows it; receivers are
  told to be idempotent.
- The configs are a second file next to the tasks, not columns of the
  task row: the task process is the only writer of its row (T9), and
  configs are written by request processes.
