-module(barrel_a2a_canonical_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, barrel_a2a_canonical).

%%--------------------------------------------------------------------
%% Numbers (RFC 8785 appendix B and 3.2.2.3)
%%--------------------------------------------------------------------

number_vectors_test_() ->
    Vectors = [
        {1.0, <<"1">>},
        {0.000001, <<"0.000001">>},
        {1.0e-7, <<"1e-7">>},
        {1.0e21, <<"1e+21">>},
        {1.0e20, <<"100000000000000000000">>},
        {333333333.33333329, <<"333333333.3333333">>},
        {9007199254740993.0, <<"9007199254740992">>},
        {4.35, <<"4.35">>},
        {5.0e-324, <<"5e-324">>},
        {1.7976931348623157e308, <<"1.7976931348623157e+308">>},
        {0.5, <<"0.5">>},
        {-1.5e-10, <<"-1.5e-10">>},
        {0.0, <<"0">>},
        {-0.0, <<"0">>},
        {0.001, <<"0.001">>},
        {123456789012345680000.0, <<"123456789012345680000">>},
        {1.0e30, <<"1e+30">>},
        {2.0e-3, <<"0.002">>},
        {1.0e-27, <<"1e-27">>},
        {-1.0, <<"-1">>},
        {100.0, <<"100">>},
        {12.5, <<"12.5">>},
        {1.5e300, <<"1.5e+300">>}
    ],
    [?_assertEqual(Out, ?M:encode(In)) || {In, Out} <- Vectors].

integers_test_() ->
    [
        ?_assertEqual(<<"0">>, ?M:encode(0)),
        ?_assertEqual(<<"-42">>, ?M:encode(-42)),
        ?_assertEqual(<<"12345678901234567890">>, ?M:encode(12345678901234567890)),
        ?_assertEqual(<<"[1,1,2]">>, ?M:encode([1, 1.0, 2]))
    ].

not_json_test_() ->
    [
        ?_assertError({not_json, foo}, ?M:encode(foo)),
        ?_assertError({not_json, _}, ?M:encode(#{key => 1})),
        ?_assertError({not_json, _}, ?M:encode({tuple}))
    ].

%%--------------------------------------------------------------------
%% Strings
%%--------------------------------------------------------------------

control_char_escaping_test_() ->
    [
        ?_assertEqual(<<"\"\\b\\f\\n\\r\\t\"">>, ?M:encode(<<"\b\f\n\r\t">>)),
        ?_assertEqual(<<"\"\\u0000\\u0001\\u001f\"">>, ?M:encode(<<0, 1, 31>>)),
        ?_assertEqual(<<"\"\\u000f\"">>, ?M:encode(<<16#0F>>)),
        ?_assertEqual(<<"\"\\\"\\\\\"">>, ?M:encode(<<"\"\\">>)),
        %% Solidus, DEL and non-ASCII are literal.
        ?_assertEqual(<<"\"/\"">>, ?M:encode(<<"/">>)),
        ?_assertEqual(<<"\"", 16#7F, "\"">>, ?M:encode(<<16#7F>>)),
        ?_assertEqual(<<"\"€\x{1F600}\""/utf8>>, ?M:encode(<<"€\x{1F600}"/utf8>>)),
        ?_assertEqual(<<"\"\"">>, ?M:encode(<<>>))
    ].

literals_test_() ->
    [
        ?_assertEqual(<<"null">>, ?M:encode(null)),
        ?_assertEqual(<<"true">>, ?M:encode(true)),
        ?_assertEqual(<<"false">>, ?M:encode(false)),
        ?_assertEqual(<<"[]">>, ?M:encode([])),
        ?_assertEqual(<<"{}">>, ?M:encode(#{}))
    ].

%%--------------------------------------------------------------------
%% Objects and key ordering
%%--------------------------------------------------------------------

rfc_example_object_test() ->
    Input = <<
        "{\"numbers\": [333333333.33333329, 1E30, 4.50, 2e-3, "
        "0.000000000000000000000000001],\n"
        "\"string\": \"\\u20ac$\\u000F\\u000aA'\\u0042\\u0022\\u005c\\\\\\\"\\/\",\n"
        "\"literals\": [null, true, false]}"
    >>,
    Expected = <<
        "{\"literals\":[null,true,false],"
        "\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27],"
        "\"string\":\"€$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"}"/utf8
    >>,
    ?assertEqual(Expected, ?M:encode(json:decode(Input))).

rfc_key_ordering_test() ->
    Input = <<
        "{\"\\u20ac\": \"Euro Sign\",\n"
        "\"\\r\": \"Carriage Return\",\n"
        "\"\\ufb33\": \"Hebrew Letter Dalet With Dagesh\",\n"
        "\"1\": \"One\",\n"
        "\"\\ud83d\\ude00\": \"Emoji: Grinning Face\",\n"
        "\"\\u0080\": \"Control\",\n"
        "\"\\u00f6\": \"Latin Small Letter O With Diaeresis\"}"
    >>,
    Expected = <<
        "{\"\\r\":\"Carriage Return\","
        "\"1\":\"One\","
        "\"\x{80}\":\"Control\","
        "\"ö\":\"Latin Small Letter O With Diaeresis\","
        "\"€\":\"Euro Sign\","
        "\"\x{1F600}\":\"Emoji: Grinning Face\","
        "\"\x{FB33}\":\"Hebrew Letter Dalet With Dagesh\"}"/utf8
    >>,
    ?assertEqual(Expected, ?M:encode(json:decode(Input))).

%% Byte order would put U+FB33 (EF AC B3) before U+1F600 (F0 9F 98 80);
%% UTF-16 code units put the surrogate pair (D83D) first.
utf16_vs_byte_order_test() ->
    Obj = #{<<"\x{1F600}"/utf8>> => 1, <<"\x{FB33}"/utf8>> => 2},
    ?assertEqual(<<"{\"\x{1F600}\":1,\"\x{FB33}\":2}"/utf8>>, ?M:encode(Obj)).

nested_sorting_test() ->
    Obj = #{
        <<"b">> => #{<<"z">> => [#{<<"y">> => 1, <<"x">> => 2}], <<"a">> => null},
        <<"a">> => [3, #{<<"c">> => true, <<"B">> => false}],
        <<"A">> => <<"upper first">>
    },
    ?assertEqual(
        <<
            "{\"A\":\"upper first\",\"a\":[3,{\"B\":false,\"c\":true}],"
            "\"b\":{\"a\":null,\"z\":[{\"x\":2,\"y\":1}]}}"
        >>,
        ?M:encode(Obj)
    ).

shorter_prefix_key_sorts_first_test() ->
    ?assertEqual(
        <<"{\"a\":1,\"aa\":2,\"ab\":3}">>,
        ?M:encode(#{<<"ab">> => 3, <<"a">> => 1, <<"aa">> => 2})
    ).

idempotent_test() ->
    Obj = #{
        <<"€"/utf8>> => [1.5e-10, 1.0e21, 0.000001, <<"\n\"\\/">>],
        <<"\x{1F600}"/utf8>> => #{<<"k">> => null, <<"j">> => 12345678901234567890},
        <<"\r">> => -0.0
    },
    Once = ?M:encode(Obj),
    ?assertEqual(Once, ?M:encode(json:decode(Once))).

%%--------------------------------------------------------------------
%% Agent Card presence rules (8.4.1)
%%--------------------------------------------------------------------

spec_example_test() ->
    Card = #{
        <<"name">> => <<"Example Agent">>,
        <<"description">> => <<>>,
        <<"capabilities">> => #{
            <<"streaming">> => false,
            <<"pushNotifications">> => false,
            <<"extensions">> => []
        },
        <<"skills">> => []
    },
    ?assertEqual(
        <<
            "{\"capabilities\":{\"pushNotifications\":false,\"streaming\":false},"
            "\"description\":\"\",\"name\":\"Example Agent\",\"skills\":[]}"
        >>,
        ?M:encode(?M:agent_card_payload(Card))
    ).

signatures_removed_test() ->
    Card = #{
        <<"name">> => <<"a">>,
        <<"signatures">> => [#{<<"protected">> => <<"x">>, <<"signature">> => <<"y">>}]
    },
    ?assertEqual(#{<<"name">> => <<"a">>}, ?M:agent_card_payload(Card)).

nested_defaults_test() ->
    Card = #{
        <<"name">> => <<"a">>,
        <<"version">> => <<"1">>,
        <<"iconUrl">> => <<>>,
        <<"documentationUrl">> => null,
        <<"preferredTransport">> => <<>>,
        <<"supportedInterfaces">> => [
            #{
                <<"url">> => <<"https://x">>,
                <<"protocolBinding">> => <<>>,
                <<"protocolVersion">> => <<>>,
                <<"tenant">> => <<>>
            }
        ],
        <<"provider">> => #{<<"url">> => <<>>, <<"organization">> => <<>>, <<"extra">> => 0},
        <<"skills">> => [
            #{
                <<"id">> => <<"s">>,
                <<"name">> => <<"s">>,
                <<"description">> => <<>>,
                <<"tags">> => [],
                <<"examples">> => [],
                <<"inputModes">> => [<<>>],
                <<"security">> => [#{<<"oauth">> => #{<<"list">> => []}}]
            }
        ],
        <<"capabilities">> => #{
            <<"extendedAgentCard">> => false,
            <<"extensions">> => [
                #{
                    <<"uri">> => <<"urn:x">>,
                    <<"description">> => <<>>,
                    <<"required">> => false,
                    <<"params">> => #{<<"n">> => 0}
                }
            ]
        },
        <<"securityRequirements">> => [],
        <<"unknownObject">> => #{<<"empty">> => #{}, <<"zero">> => 0.0, <<"kept">> => 1}
    },
    Expected = #{
        <<"name">> => <<"a">>,
        <<"version">> => <<"1">>,
        <<"iconUrl">> => <<>>,
        <<"documentationUrl">> => null,
        <<"supportedInterfaces">> => [
            #{
                <<"url">> => <<"https://x">>,
                <<"protocolBinding">> => <<>>,
                <<"protocolVersion">> => <<>>
            }
        ],
        <<"provider">> => #{<<"url">> => <<>>, <<"organization">> => <<>>},
        <<"skills">> => [
            #{
                <<"id">> => <<"s">>,
                <<"name">> => <<"s">>,
                <<"description">> => <<>>,
                <<"tags">> => [],
                <<"inputModes">> => [<<>>],
                <<"security">> => [#{<<"oauth">> => #{<<"list">> => []}}]
            }
        ],
        <<"capabilities">> => #{
            <<"extendedAgentCard">> => false,
            <<"extensions">> => [#{<<"uri">> => <<"urn:x">>, <<"params">> => #{<<"n">> => 0}}]
        },
        <<"unknownObject">> => #{<<"kept">> => 1}
    },
    ?assertEqual(Expected, ?M:agent_card_payload(Card)).

security_schemes_test() ->
    Card = #{
        <<"name">> => <<"a">>,
        <<"securitySchemes">> => #{
            <<"mtls">> => #{<<"mtlsSecurityScheme">> => #{}},
            <<"key">> => #{
                <<"apiKeySecurityScheme">> => #{
                    <<"location">> => <<"header">>,
                    <<"name">> => <<>>,
                    <<"description">> => <<>>
                }
            },
            <<"oauth">> => #{
                <<"oauth2SecurityScheme">> => #{
                    <<"oauth2MetadataUrl">> => <<>>,
                    <<"flows">> => #{
                        <<"clientCredentials">> => #{
                            <<"tokenUrl">> => <<"https://t">>,
                            <<"scopes">> => #{},
                            <<"refreshUrl">> => <<>>
                        }
                    }
                }
            }
        }
    },
    Expected = #{
        <<"name">> => <<"a">>,
        <<"securitySchemes">> => #{
            <<"mtls">> => #{<<"mtlsSecurityScheme">> => #{}},
            <<"key">> => #{
                <<"apiKeySecurityScheme">> => #{
                    <<"location">> => <<"header">>,
                    <<"name">> => <<>>
                }
            },
            <<"oauth">> => #{
                <<"oauth2SecurityScheme">> => #{
                    <<"flows">> => #{
                        <<"clientCredentials">> => #{
                            <<"tokenUrl">> => <<"https://t">>,
                            <<"scopes">> => #{}
                        }
                    }
                }
            }
        }
    },
    ?assertEqual(Expected, ?M:agent_card_payload(Card)).
