# Multi-tenancy

This guide shows how to run a server for one tenant so that every
request must name it, and how the client follows the tenant declared
in the card. You need it when one deployment serves several isolated
customers, each behind its own interface entry.

## Configure a tenant

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    tenant => <<"acme">>,
    url => <<"https://agent.example">>
}).
```

The generated `supportedInterfaces` carry `"tenant": "acme"`:

```json
{"url": "https://agent.example/a2a/jsonrpc", "protocolBinding": "JSONRPC",
 "protocolVersion": "1.0", "tenant": "acme"}
```

To serve several tenants, start one server per tenant (each with its
own port, or embedded under distinct base paths, see
[Embedding](embedding.md)), and publish a card whose interfaces list
them all.

## What the server checks

Every request must carry the tenant, either as the `tenant` field of
the request object (both bindings) or as the REST path prefix:

```
POST /a2a/v1/acme/message:send
GET  /a2a/v1/acme/tasks/{id}
```

A request naming another tenant, or none at all, is rejected with
`invalid_params` (HTTP 400) on the `tenant` field. A server without
`tenant` ignores the field.

## Client side

Nothing to configure: `barrel_a2a_client:connect/2` copies the
`tenant` of the selected interface into every request.

```erlang
{ok, Agent} = barrel_a2a_client:connect(<<"https://agent.example">>),
<<"acme">> = maps:get(<<"tenant">>, barrel_a2a_client:interface(Agent)),
{ok, {task, T}} = barrel_a2a_client:send(Agent, <<"hello">>).
```

To pick a specific tenant from a card with several, select the
interface yourself and connect from it:

```erlang
Card = ...,
[I | _] = [X || #{<<"tenant">> := <<"acme">>} = X <- barrel_a2a_agent_card:interfaces(Card)],
{ok, Agent} = barrel_a2a_client:from_card(
    barrel_a2a_agent_card:with_interfaces([I], Card), #{}).
```

## In the handler

```erlang
handle_message(Ctx, Message) ->
    Tenant = barrel_a2a_ctx:tenant(Ctx),   %% <<"acme">> or undefined
    {ok, my_store:answer(Tenant, barrel_a2a_message:text(Message))}.
```

## Notes

- `barrel_a2a_http_engine:routes/1` lists the tenant-prefixed REST
  routes next to the plain ones when `tenant` is set.
- Tasks are scoped by principal, not by tenant; two servers never
  share a registry, so tenant isolation follows from one server per
  tenant.
