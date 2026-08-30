# Authentication

This guide covers verifying callers on the server, scoping what they
can see, declaring schemes in the card, and attaching credentials on
the client. You need it as soon as an agent is reachable beyond
localhost.

## Server hook

The `auth` option runs on every request except the public card and
returns a principal that tasks are then owned by:

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    auth => {bearer, fun(Token) ->
        case my_tokens:verify(Token) of
            {ok, Subject} -> {ok, Subject};
            {error, revoked} -> {error, forbidden};
            {error, _} -> {error, unauthenticated}
        end
    end}
}).
```

Shapes:

| Config | Callback |
|---|---|
| `none` | every request is `anonymous` (default) |
| `{bearer, Fun}` | `Fun(Token)` on `Authorization: Bearer` |
| `{api_key, HeaderName, Fun}` | `Fun(Key)` on that header |
| `{basic, Fun}` | `Fun(User, Password)` |
| `{Module, State}` | `Module:authenticate(Request, State)` |
| `fun((Request) -> ...)` | `Request = #{headers, op, binding, peer}` |

Return `{ok, Principal}`, `{error, unauthenticated}` (401 with a
`WWW-Authenticate` challenge built from the card's security schemes)
or `{error, forbidden}` (403). Any other reason or a crash is logged
without credentials and answered as 401. On JSON-RPC these travel
as codes -32010 and -32011 with the same HTTP status.

A module hook:

```erlang
-module(my_auth).
-behaviour(barrel_a2a_auth).
-export([authenticate/2]).

authenticate(#{headers := Headers, op := Op}, State) ->
    case barrel_a2a_auth:header(<<"x-api-key">>, Headers) of
        undefined -> {error, unauthenticated};
        Key -> my_keys:lookup(Key, Op, State)
    end.
```

Read the principal in the handler with `barrel_a2a_ctx:principal/1`.

## Authorization scoping

Every task records the principal that created it. With
`authorize => owner` (default) `GetTask`, `ListTasks`, `CancelTask`,
`SubscribeToTask`, follow-ups and push config operations only see
the caller's own tasks; another principal's task answers
`task_not_found`, never 403. `authorize => any` disables scoping;
a `fun((Principal, TaskEntry) -> boolean())` implements your own
rule (`TaskEntry` is a map with `owner` and `task` keys).

## Declaring schemes in the card

```erlang
Card = barrel_a2a_agent_card:new(#{
    name => <<"Agent">>,
    security_schemes => #{
        <<"bearer">> => barrel_a2a_agent_card:security_scheme(http, #{
            scheme => <<"bearer">>, bearer_format => <<"JWT">>
        }),
        <<"key">> => barrel_a2a_agent_card:security_scheme(api_key, #{
            location => header, name => <<"X-API-Key">>
        }),
        <<"google">> => barrel_a2a_agent_card:security_scheme(openid_connect, #{
            open_id_connect_url => <<"https://accounts.google.com/.well-known/openid-configuration">>
        })
    },
    security_requirements => [#{<<"schemes">> => #{<<"bearer">> => #{<<"list">> => []}}}]
}).
```

`security_scheme/2` also builds `oauth2` (`flows`,
`oauth2_metadata_url`) and `mtls`. The declared schemes drive the
`WWW-Authenticate` challenge on 401.

## Extended card

`extended_card => Card | fun((Principal) -> Card | undefined)` serves
an authenticated card on `GetExtendedAgentCard`; clients fetch it
with `barrel_a2a_client:extended_card/1`. Without the option the
operation answers `unsupported_operation`; a fun returning
`undefined` answers `extended_agent_card_not_configured`.

The operation needs a caller to identify. A server running with
`auth => none` has none, so it answers `unauthenticated` whatever
`extended_card` is set to. Configure an authentication scheme, or pass
a `principal` in the request context if your embedding authenticates
the peer itself.

## Client credentials

```erlang
{ok, Agent} = barrel_a2a_client:connect(Url, #{auth => {bearer, <<"eyJ...">>}}),
{ok, Agent} = barrel_a2a_client:connect(Url, #{auth => {bearer, fun my_tokens:current/0}}),
{ok, Agent} = barrel_a2a_client:connect(Url, #{auth => {api_key, <<"x-api-key">>, Key}}),
{ok, Agent} = barrel_a2a_client:connect(Url, #{auth => {basic, User, Password}}),
{ok, Agent} = barrel_a2a_client:connect(Url, #{auth => fun(Op) -> [{<<"authorization">>, sign(Op)}] end}).
```

Or let the card decide, with credentials keyed by scheme name:

```erlang
{ok, Agent} = barrel_a2a_client:connect(Url, #{
    credentials => #{<<"bearer">> => {bearer, Jwt}, <<"key">> => {api_key, <<"X-API-Key">>, Key}}
}).
```

`barrel_a2a_client_auth:select/2` picks the first scheme named by
the card's `securityRequirements` (then `securitySchemes`) for which
you supplied credentials. Tokens themselves are obtained out of band.

## TLS

```erlang
http => #{port => 8443, tls => #{certfile => "cert.pem", keyfile => "key.pem",
                                 cacertfile => "ca.pem", versions => ['tlsv1.3']}}
```

The listener negotiates HTTP/2 or HTTP/1.1 by ALPN and sends
`Strict-Transport-Security` unless `hsts => false`. The client
passes `transport_opts => #{ssl_options => [{cacertfile, "ca.pem"}]}`.

## Notes

- The Agent Card at the well-known path is always public; put
  sensitive details in the extended card.
- `rate_limit => fun((ReqCtx) -> ok | {error, Seconds})` runs before
  authentication and answers 429 with `Retry-After`.
