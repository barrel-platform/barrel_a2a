-module(barrel_a2a_card_sign_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_a2a_card_sign).

card() ->
    #{
        <<"name">> => <<"Echo">>,
        <<"description">> => <<"Echoes what you say">>,
        <<"version">> => <<"1.0.0">>,
        <<"protocolVersion">> => <<"1.0">>,
        <<"capabilities">> => #{<<"streaming">> => true},
        <<"skills">> => [
            #{
                <<"id">> => <<"echo">>,
                <<"name">> => <<"Echo">>,
                <<"description">> => <<"Echo">>,
                <<"tags">> => [<<"echo">>]
            }
        ],
        <<"supportedInterfaces">> => [
            #{
                <<"url">> => <<"https://example.com/a2a">>,
                <<"protocolBinding">> => <<"JSONRPC">>,
                <<"protocolVersion">> => <<"1.0">>
            }
        ],
        <<"defaultInputModes">> => [<<"text/plain">>],
        <<"defaultOutputModes">> => [<<"text/plain">>]
    }.

sign_verify_test_() ->
    [
        {atom_to_list(Alg), fun() -> sign_verify(Alg) end}
     || Alg <- ['ES256', 'RS256', 'PS256']
    ].

sign_verify(Alg) ->
    Key = ?M:generate_key(Alg),
    Jwk = ?M:jwk(Key),
    Kid = maps:get(<<"kid">>, Jwk),
    Signed = ?M:sign(card(), Key, #{alg => Alg, kid => Kid}),
    [Sig] = maps:get(<<"signatures">>, Signed),
    ?assertNot(maps:is_key(<<"header">>, Sig)),
    ?assertEqual(ok, ?M:verify(Signed, #{keys => [Jwk]})),
    ?assertEqual(ok, ?M:verify(Signed, #{keys => #{Kid => Jwk}})),
    Tampered = Signed#{<<"description">> => <<"Something else">>},
    ?assertEqual({error, {invalid_signature, Kid}}, ?M:verify(Tampered, #{keys => [Jwk]})).

es256_raw_signature_test() ->
    Key = ?M:generate_key('ES256'),
    Signed = ?M:sign(card(), Key, #{alg => 'ES256', kid => <<"k1">>}),
    [#{<<"signature">> := SigB64}] = maps:get(<<"signatures">>, Signed),
    Sig = base64:decode(SigB64, #{mode => urlsafe, padding => false}),
    ?assertEqual(64, byte_size(Sig)).

protected_header_test() ->
    Key = ?M:generate_key('ES256'),
    Signed = ?M:sign(card(), Key, #{alg => 'ES256', kid => <<"k1">>}),
    [#{<<"protected">> := P}] = maps:get(<<"signatures">>, Signed),
    Json = base64:decode(P, #{mode => urlsafe, padding => false}),
    {ok, Header} = barrel_a2a_json:decode(Json),
    ?assertEqual(
        #{<<"alg">> => <<"ES256">>, <<"typ">> => <<"JOSE">>, <<"kid">> => <<"k1">>},
        Header
    ).

jku_and_unprotected_header_test() ->
    Key = ?M:generate_key('ES256'),
    Signed = ?M:sign(card(), Key, #{
        alg => 'ES256',
        kid => <<"k1">>,
        jku => <<"https://example.com/jwks.json">>,
        header => #{<<"x-note">> => <<"hi">>}
    }),
    [#{<<"protected">> := P, <<"header">> := H}] = maps:get(<<"signatures">>, Signed),
    {ok, Header} = barrel_a2a_json:decode(base64:decode(P, #{mode => urlsafe, padding => false})),
    ?assertEqual(<<"https://example.com/jwks.json">>, maps:get(<<"jku">>, Header)),
    ?assertEqual(#{<<"x-note">> => <<"hi">>}, H).

signing_input_test() ->
    Payload = ?M:canonical_payload(card()),
    ?assertEqual(
        Payload, barrel_a2a_canonical:encode(barrel_a2a_canonical:agent_card_payload(card()))
    ),
    Input = ?M:signing_input(<<"abc">>, Payload),
    B64 = base64:encode(Payload, #{mode => urlsafe, padding => false}),
    ?assertEqual(<<"abc.", B64/binary>>, Input),
    ?assertEqual(nomatch, binary:match(Input, <<"=">>)).

unknown_kid_test() ->
    Key = ?M:generate_key('ES256'),
    Signed = ?M:sign(card(), Key, #{alg => 'ES256', kid => <<"nope">>}),
    ?assertEqual({error, {unknown_key, <<"nope">>}}, ?M:verify(Signed, #{keys => []})),
    ?assertEqual({error, {unknown_key, <<"nope">>}}, ?M:verify(Signed, #{})).

expired_key_test() ->
    Key = ?M:generate_key('ES256'),
    Jwk = ?M:jwk(Key, <<"k1">>),
    Signed = ?M:sign(card(), Key, #{alg => 'ES256', kid => <<"k1">>}),
    Expired = Jwk#{<<"exp">> => 1000},
    ?assertEqual(
        {error, {key_expired, <<"k1">>}},
        ?M:verify(Signed, #{keys => [Expired], now => 2000})
    ),
    ?assertEqual(ok, ?M:verify(Signed, #{keys => [Expired], now => 500})).

unsigned_test() ->
    ?assertEqual(ok, ?M:verify(card(), #{})),
    ?assertEqual(ok, ?M:verify((card())#{<<"signatures">> => []}, #{})),
    ?assertEqual({error, unsigned}, ?M:verify(card(), #{required => true})).

allowed_algs_test() ->
    Key = ?M:generate_key('ES256'),
    Jwk = ?M:jwk(Key, <<"k1">>),
    Signed = ?M:sign(card(), Key, #{alg => 'ES256', kid => <<"k1">>}),
    ?assertEqual(
        {error, {unsupported_alg, 'ES256'}},
        ?M:verify(Signed, #{keys => [Jwk], allowed_algs => ['RS256']})
    ),
    ?assertEqual(ok, ?M:verify(Signed, #{keys => [Jwk], allowed_algs => ['ES256']})).

jku_fetch_test() ->
    Key = ?M:generate_key('RS256'),
    Jwk = ?M:jwk(Key, <<"remote">>),
    Fetch = fun
        (<<"https://keys.example.com/jwks.json">>) -> {ok, [Jwk]};
        (_) -> {error, not_found}
    end,
    Https = ?M:sign(card(), Key, #{
        alg => 'RS256', kid => <<"remote">>, jku => <<"https://keys.example.com/jwks.json">>
    }),
    ?assertEqual(ok, ?M:verify(Https, #{jwks_fetch => Fetch})),
    ?assertEqual({error, {unknown_key, <<"remote">>}}, ?M:verify(Https, #{})),
    Http = ?M:sign(card(), Key, #{
        alg => 'RS256', kid => <<"remote">>, jku => <<"http://keys.example.com/jwks.json">>
    }),
    Fetch2 = fun(_) -> {ok, [Jwk]} end,
    ?assertEqual({error, {unknown_key, <<"remote">>}}, ?M:verify(Http, #{jwks_fetch => Fetch2})).

two_signatures_first_bad_test() ->
    Key1 = ?M:generate_key('ES256'),
    Key2 = ?M:generate_key('PS256'),
    Jwk2 = ?M:jwk(Key2, <<"good">>),
    Once = ?M:sign(card(), Key1, #{alg => 'ES256', kid => <<"bad">>}),
    Twice = ?M:sign(Once, Key2, #{alg => 'PS256', kid => <<"good">>}),
    ?assertEqual(2, length(maps:get(<<"signatures">>, Twice))),
    ?assertEqual(ok, ?M:verify(Twice, #{keys => [Jwk2]})),
    %% First failure reported when nothing verifies.
    ?assertEqual({error, {unknown_key, <<"bad">>}}, ?M:verify(Twice, #{keys => []})).

malformed_signature_test() ->
    Card = (card())#{<<"signatures">> => [#{<<"protected">> => <<"!!">>, <<"signature">> => <<>>}]},
    ?assertEqual({error, malformed_signature}, ?M:verify(Card, #{})),
    Card2 = (card())#{<<"signatures">> => [#{<<"signature">> => <<"abc">>}]},
    ?assertEqual({error, malformed_signature}, ?M:verify(Card2, #{})).

pem_roundtrip_test() ->
    Key = ?M:generate_key('ES256'),
    Pem = public_key:pem_encode([public_key:pem_entry_encode('ECPrivateKey', Key)]),
    ?assertEqual(Key, ?M:decode_pem(Pem)),
    Jwk = ?M:jwk(Pem),
    Signed = ?M:sign(card(), Pem, #{alg => 'ES256', kid => maps:get(<<"kid">>, Jwk)}),
    ?assertEqual(ok, ?M:verify(Signed, #{keys => [Jwk]})),
    Rsa = ?M:generate_key('RS256'),
    RsaPem = public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', Rsa)]),
    ?assertEqual(Rsa, ?M:decode_pem(RsaPem)).

thumbprint_kid_test() ->
    Key = ?M:generate_key('ES256'),
    #{<<"kid">> := Kid, <<"x">> := X, <<"y">> := Y} = ?M:jwk(Key),
    Canonical =
        <<"{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"", X/binary, "\",\"y\":\"", Y/binary, "\"}">>,
    Expected = base64:encode(crypto:hash(sha256, Canonical), #{mode => urlsafe, padding => false}),
    ?assertEqual(Expected, Kid).
