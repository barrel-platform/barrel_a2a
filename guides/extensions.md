# Extensions

This guide shows how a server declares protocol extensions, how a
client opts into them, and how both sides learn which ones are active
on a request. You need it to add behaviour beyond the core
specification without breaking clients that do not know it (spec 4.6).

## Declare on the server

Extensions live in the card capabilities:

```erlang
Card = barrel_a2a_agent_card:new(#{
    name => <<"Agent">>,
    capabilities => #{
        extensions => [
            #{uri => <<"https://example.com/ext/traces">>,
              description => <<"Trace ids in metadata">>},
            #{uri => <<"https://example.com/ext/signed-parts">>,
              description => <<"Parts carry signatures">>,
              required => true,
              params => #{<<"alg">> => <<"ES256">>}}
        ]
    }
}),
{ok, Server} = barrel_a2a_server:start(Card, #{handler => my_agent}).
```

A `required` extension that a client did not request fails every
operation with `extension_support_required` (code -32008, HTTP 400)
and an `ErrorInfo` detail naming the URI.

## Opt in on the client

```erlang
{ok, Agent} = barrel_a2a_client:connect(Url, #{
    extensions => [<<"https://example.com/ext/traces">>, <<"https://example.com/ext/signed-parts">>]
}).
```

The client sends `A2A-Extensions: uri1,uri2` on every request. The
server intersects it with what the card declares; unknown URIs are
ignored, never matched by version. The response carries
`A2A-Extensions` with the active set.

## Use the active set

Server side:

```erlang
handle_message(Ctx, Message) ->
    case lists:member(<<"https://example.com/ext/traces">>, barrel_a2a_ctx:extensions(Ctx)) of
        true -> Trace = maps:get(<<"trace">>, barrel_a2a_message:metadata(Message), undefined);
        false -> ok
    end,
    ...
```

Client side, when you need the response header, use the raw call and
transport, or read the card:

```erlang
Declared = barrel_a2a_extensions:declared(barrel_a2a_client:card(Agent)),
Required = barrel_a2a_agent_card:required_extensions(barrel_a2a_client:card(Agent)).
```

## Message and artifact extension points

Messages, parts and artifacts carry `extensions` (URIs) and
`metadata` for extension data:

```erlang
Msg = barrel_a2a_message:new(<<"hello">>, #{
    extensions => [<<"https://example.com/ext/traces">>],
    metadata => #{<<"trace">> => <<"abc123">>}
}),
Art = barrel_a2a_artifact:new(Parts, #{extensions => [Uri], metadata => #{...}}),
Part = barrel_a2a_part:text(<<"x">>, #{metadata => #{...}}).
```

## Notes

- `barrel_a2a_extensions:parse_header/1`, `format_header/1` and
  `negotiate/2` are the functions both sides use; reuse them in a
  custom binding.
- A client that passes the header as a query parameter
  (`?A2A-Extensions=...`) is accepted too (spec 3.2.6).
