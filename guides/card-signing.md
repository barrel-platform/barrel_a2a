# Agent Card Signing

This guide shows how to sign the Agent Card your server publishes and
how a client verifies it. You need it when clients must trust that a
card was issued by you and not altered in transit or by a registry
(spec 8.4).

## Generate a key

```erlang
Key = barrel_a2a_card_sign:generate_key('ES256'),   %% P-256; 'RS256' and 'PS256' give RSA 2048
Jwk = barrel_a2a_card_sign:jwk(Key),                %% public JWK, kid = key thumbprint
Jwk2 = barrel_a2a_card_sign:jwk(Key, <<"2026-01">>), %% explicit kid
Key2 = barrel_a2a_card_sign:decode_pem(PemBinary).  %% EC, RSA or PKCS#8 private key
```

Publish `Jwk` to your clients, or serve a JWKS document over https
and point to it with `jku`.

## Sign on the server

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    signing => #{key => Key, alg => 'ES256', kid => maps:get(<<"kid">>, Jwk),
                 jku => <<"https://agent.example/.well-known/jwks.json">>}
}).
```

The published card (`barrel_a2a_server:card/1`) carries a
`signatures` entry with `protected` (`alg`, `typ`, `kid`, `jku`) and
`signature`; it is recomputed on `update_card/2`. To sign a card by
hand:

```erlang
Signed = barrel_a2a_card_sign:sign(Card, Key, #{alg => 'ES256', kid => <<"k1">>}).
```

The payload is the RFC 8785 canonical form of the card without
`signatures` and without default-valued optional members
(`barrel_a2a_card_sign:canonical_payload/1`).

## Verify on the client

```erlang
{ok, Agent} = barrel_a2a_client:connect(Url, #{
    verify_signatures => #{keys => [Jwk], required => true}
}).
```

Or with JWKS fetching:

```erlang
Fetch = fun(Jku) ->
    case hackney:request(get, Jku, [], <<>>, [with_body]) of
        {ok, 200, _, Body} -> barrel_a2a_json:decode(Body);   %% {ok, #{<<"keys">> => [...]}}
        _ -> {error, fetch_failed}
    end
end,
{ok, Agent} = barrel_a2a_client:connect(Url, #{
    verify_signatures => #{jwks_fetch => Fetch, required => true, allowed_algs => ['ES256']}
}).
```

A failed verification makes `connect/2` return
`{error, #{type := unauthenticated}}`. Verify any card directly:

```erlang
ok = barrel_a2a_card_sign:verify(Card, #{keys => #{<<"k1">> => Jwk}}).
```

Verify options: `keys` (list or map by kid), `jwks_fetch`
(`fun((Jku) -> {ok, Keys} | {ok, #{<<"keys">> => Keys}} | {error, _})`,
https `jku` only), `required` (refuse unsigned cards, default
`false`), `allowed_algs`, `now` (for `exp` checks). Errors:
`unsigned`, `malformed_signature`, `{unsupported_alg, A}`,
`{unknown_key, Kid}`, `{key_expired, Kid}`,
`{invalid_signature, Kid}`.

## Notes

- Without `required => true` an unsigned card passes; set it once all
  your agents sign.
- Keys are looked up by `kid` locally first, then through `jwks_fetch`.
  Cache inside your fetch fun if you verify often.
- A JWK with a numeric `exp` in the past is refused.
