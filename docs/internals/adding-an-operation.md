# Adding a protocol operation

The eleven operations of A2A v1.0 are enumerated in several tables that
the compiler cannot keep in step: every one has a catch-all clause, so
a missing entry compiles and fails at runtime. This is the checklist.
Follow it in order; each step builds on the previous one.

Use it also when you change an existing operation's shape, since the
same tables are involved.

## 1. Name it

`src/barrel_a2a.erl`, the `op()` type. This is the canonical list; the
atom you add here is what every other table keys on. Use the
snake_case of the specification's method name.

## 2. Wire it into the JSON-RPC binding

`src/barrel_a2a_jsonrpc.erl`, three places:

- `method_name/1`: the PascalCase method name from the specification.
- `methods/0`: the list `op_for_method/1` scans.
- `is_streaming/1`: only if the operation answers with a stream.

## 3. Wire it into the REST binding

`src/barrel_a2a_rest.erl`, three places:

- `routes/1`: the method and path pattern from specification section
  11.3. A `:verb` suffix is a custom method, read strictly, see
  `guides/embedding.md`.
- `build_request_op/4`: how path bindings, query parameters and the
  body become the request object.
- `path_for/3`: the client side of the same route. Add a round trip to
  `path_for_round_trip_test_` in
  `test/barrel_a2a_jsonrpc_rest_tests.erl`, and to `query_for/2` if
  the operation is a GET with parameters.

## 4. Declare its schema types

`src/barrel_a2a_schema.erl`, `request_type/1` and `reply_type/1`: the
`$defs` names from `priv/schema/a2a.json`. These drive both inbound
validation and the optional outbound check, on the server and on the
client.

## 5. Validate the request

`src/barrel_a2a_validate.erl`: a validator for the request object,
covering what JSON Schema cannot express (required fields, oneof
exclusivity, enum membership, timestamp format). Then reference it from
`validate/1` in `src/barrel_a2a_server_core.erl`.

## 6. Implement it

`src/barrel_a2a_server_core.erl`:

- a `dispatch/2` clause returning `{ok, Reply}`, `{stream, Subscribe}`
  or `{error, Error}`;
- `capability/1` if the operation depends on a declared capability, so
  it is refused with the right error when the card does not advertise
  it;
- authorization: use `visible_task/2` for anything that names a task,
  so scoping and the not-found-instead-of-forbidden rule apply.

## 7. Expose it on the client

`src/barrel_a2a_client.erl`: a function that builds the request object
and calls `call/4` or `stream/4`, plus `idempotent/1` if it is safe to
retry.

## 8. Cover it

- `test/barrel_a2a_jsonrpc_rest_tests.erl`: routing, request building,
  path round trip.
- `test/barrel_a2a_e2e_SUITE.erl`: one case in the shared list, so it
  runs over both bindings.
- `test/barrel_a2a_embed_SUITE.erl` `core_call_every_operation/1`: a
  direct call, which is what a gRPC binding will do.
- `docs/features.md`: the coverage row.

## Check

Run the two suites that catch a half-wired operation:

```
rebar3 eunit --module=barrel_a2a_jsonrpc_rest_tests
rebar3 ct --suite=test/barrel_a2a_e2e_SUITE,test/barrel_a2a_embed_SUITE
```

A missing entry usually shows up as a 404 on one binding only, or as
`method_not_found` from `op_for_method/1`.
