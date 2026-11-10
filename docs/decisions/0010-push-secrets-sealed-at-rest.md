# 0010. Push secrets are sealed at rest

## Context

Since 0008 a push config is written through to `push_config_store` as
the client sent it, so the webhook `token` and
`authentication.credentials` sat in clear in the DETS file, or in any
store the application plugs in, possibly replicated. Those are
credentials for a third-party endpoint; a copy of the file was enough
to call it.

## Decision

The secrets never reach the store in clear. `barrel_a2a_push` splits
them off before every write. With the `secret_key` push option they
are sealed with AES-256-GCM under the first key, with the task and
config ids as authenticated data, and opened on load with any key of
the list. Without a key they are not written at all; the row records
that, and on the next start such a config is dropped with a warning,
since it could no longer authenticate.

Secure by default wins over survival by default: forgetting the key
costs a re-registration, not a credential leak. Stores are unchanged;
they see an extra opaque `secrets` field.

## Consequences

- Upgrading with a persistent push store and no `secret_key` drops the
  configs that carry secrets on the first restart after the one that
  rewrote them.
- Rows written in clear by 0.2.x are rewritten on load, sealed or
  without secrets. Old bytes may remain in a DETS file.
- Keys are the application's to keep and rotate; the library only
  takes a list.
- In memory the secrets stay in clear, as delivery needs them.
