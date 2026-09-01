-module(barrel_a2a_validate_tests).

-include_lib("eunit/include/eunit.hrl").

-define(invalid(Path), {error, {invalid, Path, _}}).

valid_message() ->
    #{
        <<"messageId">> => <<"m1">>,
        <<"role">> => <<"ROLE_USER">>,
        <<"parts">> => [#{<<"text">> => <<"hi">>}]
    }.

valid_artifact() ->
    #{<<"artifactId">> => <<"a1">>, <<"parts">> => [#{<<"data">> => #{<<"k">> => 1}}]}.

valid_status() ->
    #{<<"state">> => <<"TASK_STATE_WORKING">>, <<"timestamp">> => <<"2024-01-01T00:00:00.000Z">>}.

valid_task() ->
    #{
        <<"id">> => <<"t1">>,
        <<"contextId">> => <<"c1">>,
        <<"status">> => valid_status(),
        <<"artifacts">> => [valid_artifact()],
        <<"history">> => [valid_message()]
    }.

valid_interface() ->
    #{
        <<"url">> => <<"https://x">>,
        <<"protocolBinding">> => <<"JSONRPC">>,
        <<"protocolVersion">> => <<"1.0">>
    }.

valid_skill() ->
    #{<<"id">> => <<"s">>, <<"name">> => <<"S">>, <<"description">> => <<>>, <<"tags">> => []}.

valid_card() ->
    #{
        <<"name">> => <<"Bot">>,
        <<"description">> => <<>>,
        <<"version">> => <<"1.0.0">>,
        <<"supportedInterfaces">> => [valid_interface()],
        <<"capabilities">> => #{},
        <<"defaultInputModes">> => [<<"text/plain">>],
        <<"defaultOutputModes">> => [<<"text/plain">>],
        <<"skills">> => [valid_skill()]
    }.

valid_push_config() ->
    #{<<"url">> => <<"https://hook">>, <<"authentication">> => #{<<"scheme">> => <<"Bearer">>}}.

%% Each case is {Name, Input, ExpectedPath}.
failures(Fun, Cases) ->
    [
        {Name, ?_assertMatch(?invalid(Path), Fun(Input))}
     || {Name, Input, Path} <- Cases
    ].

%%--------------------------------------------------------------------
%% message and part
%%--------------------------------------------------------------------

message_test_() ->
    M = valid_message(),
    [
        ?_assertEqual(ok, barrel_a2a_validate:message(M)),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:message(M#{
                <<"contextId">> => <<"c">>,
                <<"taskId">> => <<"t">>,
                <<"metadata">> => #{},
                <<"extensions">> => [<<"e">>],
                <<"referenceTaskIds">> => []
            })
        ),
        ?_assertEqual(ok, barrel_a2a_validate:message(M#{<<"role">> => <<"ROLE_AGENT">>})),
        ?_assertEqual(ok, barrel_a2a_validate:message(M#{<<"role">> => 1})),
        failures(fun barrel_a2a_validate:message/1, [
            {"not object", <<"x">>, <<"message">>},
            {"not object list", [], <<"message">>},
            {"messageId missing", maps:remove(<<"messageId">>, M), <<"message.messageId">>},
            {"messageId empty", M#{<<"messageId">> => <<>>}, <<"message.messageId">>},
            {"messageId type", M#{<<"messageId">> => 7}, <<"message.messageId">>},
            {"role missing", maps:remove(<<"role">>, M), <<"message.role">>},
            {"role unknown", M#{<<"role">> => <<"ROLE_ADMIN">>}, <<"message.role">>},
            {"role type", M#{<<"role">> => null}, <<"message.role">>},
            {"parts missing", maps:remove(<<"parts">>, M), <<"message.parts">>},
            {"parts empty", M#{<<"parts">> => []}, <<"message.parts">>},
            {"parts type", M#{<<"parts">> => <<"x">>}, <<"message.parts">>},
            {"part none", M#{<<"parts">> => [#{}]}, <<"message.parts[0]">>},
            {"part two", M#{<<"parts">> => [#{<<"text">> => <<"a">>, <<"data">> => 1}]},
                <<"message.parts[0]">>},
            {"part not object", M#{<<"parts">> => [<<"text">>]}, <<"message.parts[0]">>},
            {"second part", M#{<<"parts">> => [#{<<"text">> => <<"a">>}, #{}]},
                <<"message.parts[1]">>},
            {"part text type", M#{<<"parts">> => [#{<<"text">> => 1}]},
                <<"message.parts[0].text">>},
            {"contextId type", M#{<<"contextId">> => 1}, <<"message.contextId">>},
            {"taskId type", M#{<<"taskId">> => true}, <<"message.taskId">>},
            {"metadata type", M#{<<"metadata">> => []}, <<"message.metadata">>},
            {"extensions type", M#{<<"extensions">> => <<"e">>}, <<"message.extensions">>},
            {"extensions items", M#{<<"extensions">> => [<<"e">>, 1]}, <<"message.extensions">>},
            {"referenceTaskIds items", M#{<<"referenceTaskIds">> => [1]},
                <<"message.referenceTaskIds">>}
        ])
    ].

part_test_() ->
    [
        ?_assertEqual(ok, barrel_a2a_validate:part(#{<<"text">> => <<"t">>})),
        ?_assertEqual(ok, barrel_a2a_validate:part(#{<<"text">> => <<>>})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:part(#{
                <<"raw">> => base64:encode(<<1, 2, 3>>), <<"mediaType">> => <<"x/y">>
            })
        ),
        ?_assertEqual(ok, barrel_a2a_validate:part(#{<<"url">> => <<"https://x">>})),
        ?_assertEqual(ok, barrel_a2a_validate:part(#{<<"data">> => null})),
        ?_assertEqual(ok, barrel_a2a_validate:part(#{<<"data">> => [1, 2]})),
        failures(fun barrel_a2a_validate:part/1, [
            {"not object", 1, <<"part">>},
            {"none", #{<<"mediaType">> => <<"x">>}, <<"part">>},
            {"two", #{<<"text">> => <<"a">>, <<"url">> => <<"u">>}, <<"part">>},
            {"three", #{<<"text">> => <<"a">>, <<"url">> => <<"u">>, <<"data">> => 1}, <<"part">>},
            {"text type", #{<<"text">> => 1}, <<"part.text">>},
            {"url type", #{<<"url">> => 1}, <<"part.url">>},
            {"raw type", #{<<"raw">> => 1}, <<"part.raw">>},
            {"raw not base64", #{<<"raw">> => <<"!!!">>}, <<"part.raw">>}
        ])
    ].

%%--------------------------------------------------------------------
%% artifact, status, task
%%--------------------------------------------------------------------

artifact_test_() ->
    A = valid_artifact(),
    [
        ?_assertEqual(ok, barrel_a2a_validate:artifact(A)),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:artifact(A#{
                <<"name">> => <<"n">>,
                <<"description">> => <<"d">>,
                <<"metadata">> => #{},
                <<"extensions">> => []
            })
        ),
        failures(fun barrel_a2a_validate:artifact/1, [
            {"not object", null, <<"artifact">>},
            {"artifactId missing", maps:remove(<<"artifactId">>, A), <<"artifact.artifactId">>},
            {"artifactId empty", A#{<<"artifactId">> => <<>>}, <<"artifact.artifactId">>},
            {"artifactId type", A#{<<"artifactId">> => 1}, <<"artifact.artifactId">>},
            {"parts missing", maps:remove(<<"parts">>, A), <<"artifact.parts">>},
            {"parts empty", A#{<<"parts">> => []}, <<"artifact.parts">>},
            {"parts type", A#{<<"parts">> => #{}}, <<"artifact.parts">>},
            {"part invalid", A#{<<"parts">> => [#{<<"x">> => 1}]}, <<"artifact.parts[0]">>},
            {"part raw", A#{<<"parts">> => [#{<<"raw">> => <<"@@">>}]},
                <<"artifact.parts[0].raw">>},
            {"name type", A#{<<"name">> => 1}, <<"artifact.name">>},
            {"description type", A#{<<"description">> => []}, <<"artifact.description">>},
            {"metadata type", A#{<<"metadata">> => 1}, <<"artifact.metadata">>},
            {"extensions type", A#{<<"extensions">> => [1]}, <<"artifact.extensions">>}
        ])
    ].

task_status_test_() ->
    S = valid_status(),
    [
        ?_assertEqual(ok, barrel_a2a_validate:task_status(S)),
        ?_assertEqual(
            ok, barrel_a2a_validate:task_status(#{<<"state">> => <<"TASK_STATE_COMPLETED">>})
        ),
        ?_assertEqual(ok, barrel_a2a_validate:task_status(#{<<"state">> => 3})),
        ?_assertEqual(ok, barrel_a2a_validate:task_status(S#{<<"message">> => valid_message()})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:task_status(S#{<<"timestamp">> => <<"2024-01-01T01:00:00+01:00">>})
        ),
        failures(fun barrel_a2a_validate:task_status/1, [
            {"not object", <<"s">>, <<"status">>},
            {"state missing", maps:remove(<<"state">>, S), <<"status.state">>},
            {"state unknown", S#{<<"state">> => <<"TASK_STATE_DONE">>}, <<"status.state">>},
            {"state int", S#{<<"state">> => 42}, <<"status.state">>},
            {"message invalid", S#{<<"message">> => #{}}, <<"status.message.messageId">>},
            {"message not object", S#{<<"message">> => <<"m">>}, <<"status.message">>},
            {"timestamp format", S#{<<"timestamp">> => <<"yesterday">>}, <<"status.timestamp">>},
            {"timestamp type", S#{<<"timestamp">> => 1700000000}, <<"status.timestamp">>}
        ])
    ].

task_test_() ->
    T = valid_task(),
    [
        ?_assertEqual(ok, barrel_a2a_validate:task(T)),
        ?_assertEqual(
            ok, barrel_a2a_validate:task(#{<<"id">> => <<"t">>, <<"status">> => valid_status()})
        ),
        ?_assertEqual(ok, barrel_a2a_validate:task(T#{<<"metadata">> => #{<<"k">> => 1}})),
        ?_assertEqual(ok, barrel_a2a_validate:task(barrel_a2a_task:new(<<"t">>, <<"c">>))),
        failures(fun barrel_a2a_validate:task/1, [
            {"not object", [], <<"task">>},
            {"id missing", maps:remove(<<"id">>, T), <<"task.id">>},
            {"id empty", T#{<<"id">> => <<>>}, <<"task.id">>},
            {"id type", T#{<<"id">> => 1}, <<"task.id">>},
            {"status missing", maps:remove(<<"status">>, T), <<"task.status">>},
            {"status type", T#{<<"status">> => <<"working">>}, <<"task.status">>},
            {"status state", T#{<<"status">> => #{}}, <<"task.status.state">>},
            {"status timestamp",
                T#{<<"status">> => #{<<"state">> => 1, <<"timestamp">> => <<"x">>}},
                <<"task.status.timestamp">>},
            {"artifacts type", T#{<<"artifacts">> => #{}}, <<"task.artifacts">>},
            {"artifact invalid", T#{<<"artifacts">> => [#{<<"parts">> => []}]},
                <<"task.artifacts[0].artifactId">>},
            {"artifact part",
                T#{
                    <<"artifacts">> => [
                        valid_artifact(), #{<<"artifactId">> => <<"b">>, <<"parts">> => [#{}]}
                    ]
                },
                <<"task.artifacts[1].parts[0]">>},
            {"history type", T#{<<"history">> => 1}, <<"task.history">>},
            {"history invalid", T#{<<"history">> => [maps:remove(<<"role">>, valid_message())]},
                <<"task.history[0].role">>},
            {"metadata type", T#{<<"metadata">> => <<"m">>}, <<"task.metadata">>}
        ])
    ].

%%--------------------------------------------------------------------
%% agent card
%%--------------------------------------------------------------------

agent_card_test_() ->
    C = valid_card(),
    I = valid_interface(),
    S = valid_skill(),
    [
        ?_assertEqual(ok, barrel_a2a_validate:agent_card(C)),
        ?_assertEqual(ok, barrel_a2a_validate:agent_card(C#{<<"skills">> => []})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:agent_card(C#{
                <<"provider">> => #{<<"url">> => <<"u">>, <<"organization">> => <<"o">>}
            })
        ),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:agent_card(C#{
                <<"supportedInterfaces">> => [I#{<<"tenant">> => <<"t">>}]
            })
        ),
        failures(fun barrel_a2a_validate:agent_card/1, [
            {"not object", 1, <<"agentCard">>},
            {"name missing", maps:remove(<<"name">>, C), <<"agentCard.name">>},
            {"name empty", C#{<<"name">> => <<>>}, <<"agentCard.name">>},
            {"name type", C#{<<"name">> => 1}, <<"agentCard.name">>},
            {"description missing", maps:remove(<<"description">>, C), <<"agentCard.description">>},
            {"description type", C#{<<"description">> => 1}, <<"agentCard.description">>},
            {"version missing", maps:remove(<<"version">>, C), <<"agentCard.version">>},
            {"version type", C#{<<"version">> => 1.0}, <<"agentCard.version">>},
            {"interfaces missing", maps:remove(<<"supportedInterfaces">>, C),
                <<"agentCard.supportedInterfaces">>},
            {"interfaces empty", C#{<<"supportedInterfaces">> => []},
                <<"agentCard.supportedInterfaces">>},
            {"interfaces type", C#{<<"supportedInterfaces">> => #{}},
                <<"agentCard.supportedInterfaces">>},
            {"interface not object", C#{<<"supportedInterfaces">> => [1]},
                <<"agentCard.supportedInterfaces[0]">>},
            {"interface url", C#{<<"supportedInterfaces">> => [maps:remove(<<"url">>, I)]},
                <<"agentCard.supportedInterfaces[0].url">>},
            {"interface binding",
                C#{<<"supportedInterfaces">> => [I, maps:remove(<<"protocolBinding">>, I)]},
                <<"agentCard.supportedInterfaces[1].protocolBinding">>},
            {"interface version", C#{<<"supportedInterfaces">> => [I#{<<"protocolVersion">> => 1}]},
                <<"agentCard.supportedInterfaces[0].protocolVersion">>},
            {"interface tenant", C#{<<"supportedInterfaces">> => [I#{<<"tenant">> => 1}]},
                <<"agentCard.supportedInterfaces[0].tenant">>},
            {"capabilities missing", maps:remove(<<"capabilities">>, C),
                <<"agentCard.capabilities">>},
            {"capabilities type", C#{<<"capabilities">> => []}, <<"agentCard.capabilities">>},
            {"input modes missing", maps:remove(<<"defaultInputModes">>, C),
                <<"agentCard.defaultInputModes">>},
            {"input modes empty", C#{<<"defaultInputModes">> => []},
                <<"agentCard.defaultInputModes">>},
            {"output modes missing", maps:remove(<<"defaultOutputModes">>, C),
                <<"agentCard.defaultOutputModes">>},
            {"output modes type", C#{<<"defaultOutputModes">> => <<"text/plain">>},
                <<"agentCard.defaultOutputModes">>},
            {"skills missing", maps:remove(<<"skills">>, C), <<"agentCard.skills">>},
            {"skills type", C#{<<"skills">> => #{}}, <<"agentCard.skills">>},
            {"skill not object", C#{<<"skills">> => [<<"s">>]}, <<"agentCard.skills[0]">>},
            {"skill id", C#{<<"skills">> => [maps:remove(<<"id">>, S)]},
                <<"agentCard.skills[0].id">>},
            {"skill name", C#{<<"skills">> => [S#{<<"name">> => <<>>}]},
                <<"agentCard.skills[0].name">>},
            {"skill description", C#{<<"skills">> => [maps:remove(<<"description">>, S)]},
                <<"agentCard.skills[0].description">>},
            {"skill tags missing", C#{<<"skills">> => [maps:remove(<<"tags">>, S)]},
                <<"agentCard.skills[0].tags">>},
            {"skill tags type", C#{<<"skills">> => [S#{<<"tags">> => <<"t">>}]},
                <<"agentCard.skills[0].tags">>},
            {"provider not object", C#{<<"provider">> => <<"p">>}, <<"agentCard.provider">>},
            {"provider url", C#{<<"provider">> => #{<<"organization">> => <<"o">>}},
                <<"agentCard.provider.url">>},
            {"provider organization", C#{<<"provider">> => #{<<"url">> => <<"u">>}},
                <<"agentCard.provider.organization">>}
        ])
    ].

%%--------------------------------------------------------------------
%% requests
%%--------------------------------------------------------------------

send_message_request_test_() ->
    R = #{<<"message">> => valid_message()},
    Conf = #{
        <<"acceptedOutputModes">> => [<<"text/plain">>],
        <<"historyLength">> => 3,
        <<"returnImmediately">> => true,
        <<"taskPushNotificationConfig">> => valid_push_config()
    },
    [
        ?_assertEqual(ok, barrel_a2a_validate:send_message_request(R)),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:send_message_request(R#{
                <<"tenant">> => <<"t">>, <<"metadata">> => #{}, <<"configuration">> => Conf
            })
        ),
        ?_assertEqual(ok, barrel_a2a_validate:send_message_request(R#{<<"configuration">> => #{}})),
        failures(fun barrel_a2a_validate:send_message_request/1, [
            {"not object", [], <<>>},
            {"message missing", #{}, <<"message">>},
            {"message not object", #{<<"message">> => 1}, <<"message">>},
            {"message parts", R#{<<"message">> => maps:remove(<<"parts">>, valid_message())},
                <<"message.parts">>},
            {"message part", R#{<<"message">> => (valid_message())#{<<"parts">> => [#{}]}},
                <<"message.parts[0]">>},
            {"tenant type", R#{<<"tenant">> => 1}, <<"tenant">>},
            {"metadata type", R#{<<"metadata">> => 1}, <<"metadata">>},
            {"configuration type", R#{<<"configuration">> => 1}, <<"configuration">>},
            {"accepted modes", R#{<<"configuration">> => Conf#{<<"acceptedOutputModes">> => [1]}},
                <<"configuration.acceptedOutputModes">>},
            {"history length negative", R#{<<"configuration">> => Conf#{<<"historyLength">> => -1}},
                <<"configuration.historyLength">>},
            {"history length type",
                R#{<<"configuration">> => Conf#{<<"historyLength">> => <<"3">>}},
                <<"configuration.historyLength">>},
            {"return immediately",
                R#{<<"configuration">> => Conf#{<<"returnImmediately">> => <<"yes">>}},
                <<"configuration.returnImmediately">>},
            {"push config type",
                R#{<<"configuration">> => Conf#{<<"taskPushNotificationConfig">> => 1}},
                <<"configuration.taskPushNotificationConfig">>},
            {"push config url",
                R#{<<"configuration">> => Conf#{<<"taskPushNotificationConfig">> => #{}}},
                <<"configuration.taskPushNotificationConfig.url">>},
            {"push config auth scheme",
                R#{
                    <<"configuration">> => Conf#{
                        <<"taskPushNotificationConfig">> => #{
                            <<"url">> => <<"u">>, <<"authentication">> => #{}
                        }
                    }
                },
                <<"configuration.taskPushNotificationConfig.authentication.scheme">>}
        ])
    ].

get_task_request_test_() ->
    [
        ?_assertEqual(ok, barrel_a2a_validate:get_task_request(#{<<"id">> => <<"t">>})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:get_task_request(#{
                <<"id">> => <<"t">>, <<"historyLength">> => 0, <<"tenant">> => <<"x">>
            })
        ),
        failures(fun barrel_a2a_validate:get_task_request/1, [
            {"not object", 1, <<>>},
            {"id missing", #{}, <<"id">>},
            {"id empty", #{<<"id">> => <<>>}, <<"id">>},
            {"id type", #{<<"id">> => 1}, <<"id">>},
            {"history length", #{<<"id">> => <<"t">>, <<"historyLength">> => -1},
                <<"historyLength">>},
            {"history length type", #{<<"id">> => <<"t">>, <<"historyLength">> => <<"1">>},
                <<"historyLength">>},
            {"tenant", #{<<"id">> => <<"t">>, <<"tenant">> => 1}, <<"tenant">>}
        ])
    ].

list_tasks_request_test_() ->
    [
        ?_assertEqual(ok, barrel_a2a_validate:list_tasks_request(#{})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:list_tasks_request(#{
                <<"contextId">> => <<"c">>,
                <<"status">> => <<"TASK_STATE_WORKING">>,
                <<"pageSize">> => 10,
                <<"pageToken">> => <<"tok">>,
                <<"historyLength">> => 0,
                <<"statusTimestampAfter">> => <<"2024-01-01T00:00:00Z">>,
                <<"includeArtifacts">> => false,
                <<"tenant">> => <<"t">>
            })
        ),
        ?_assertEqual(ok, barrel_a2a_validate:list_tasks_request(#{<<"status">> => 2})),
        %% Both ends of the range are in, and an absent value is fine.
        ?_assertEqual(ok, barrel_a2a_validate:list_tasks_request(#{<<"pageSize">> => 1})),
        ?_assertEqual(ok, barrel_a2a_validate:list_tasks_request(#{<<"pageSize">> => 100})),
        failures(fun barrel_a2a_validate:list_tasks_request/1, [
            {"not object", <<"x">>, <<>>},
            {"contextId type", #{<<"contextId">> => 1}, <<"contextId">>},
            {"status enum", #{<<"status">> => <<"WORKING">>}, <<"status">>},
            {"status type", #{<<"status">> => true}, <<"status">>},
            {"pageSize", #{<<"pageSize">> => -5}, <<"pageSize">>},
            {"pageSize type", #{<<"pageSize">> => <<"5">>}, <<"pageSize">>},
            %% The specification fixes the range at 1 to 100, so an
            %% explicit value outside it is a bad request rather than
            %% something to clamp.
            {"pageSize zero", #{<<"pageSize">> => 0}, <<"pageSize">>},
            {"pageSize above max", #{<<"pageSize">> => 101}, <<"pageSize">>},
            {"pageToken", #{<<"pageToken">> => 1}, <<"pageToken">>},
            {"historyLength", #{<<"historyLength">> => 1.5}, <<"historyLength">>},
            {"statusTimestampAfter format", #{<<"statusTimestampAfter">> => <<"now">>},
                <<"statusTimestampAfter">>},
            {"statusTimestampAfter type", #{<<"statusTimestampAfter">> => 1},
                <<"statusTimestampAfter">>},
            {"includeArtifacts", #{<<"includeArtifacts">> => <<"true">>}, <<"includeArtifacts">>},
            {"tenant", #{<<"tenant">> => []}, <<"tenant">>}
        ])
    ].

cancel_task_request_test_() ->
    [
        ?_assertEqual(ok, barrel_a2a_validate:cancel_task_request(#{<<"id">> => <<"t">>})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:cancel_task_request(#{
                <<"id">> => <<"t">>, <<"metadata">> => #{}, <<"tenant">> => <<"x">>
            })
        ),
        failures(fun barrel_a2a_validate:cancel_task_request/1, [
            {"not object", 1, <<>>},
            {"id missing", #{<<"metadata">> => #{}}, <<"id">>},
            {"id type", #{<<"id">> => 1}, <<"id">>},
            {"metadata type", #{<<"id">> => <<"t">>, <<"metadata">> => 1}, <<"metadata">>},
            {"tenant type", #{<<"id">> => <<"t">>, <<"tenant">> => 1}, <<"tenant">>}
        ])
    ].

subscribe_request_test_() ->
    [
        ?_assertEqual(ok, barrel_a2a_validate:subscribe_request(#{<<"id">> => <<"t">>})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:subscribe_request(#{<<"id">> => <<"t">>, <<"tenant">> => <<"x">>})
        ),
        failures(fun barrel_a2a_validate:subscribe_request/1, [
            {"not object", null, <<>>},
            {"id missing", #{}, <<"id">>},
            {"id empty", #{<<"id">> => <<>>}, <<"id">>},
            {"tenant type", #{<<"id">> => <<"t">>, <<"tenant">> => 1}, <<"tenant">>}
        ])
    ].

push_config_test_() ->
    P = valid_push_config(),
    [
        ?_assertEqual(ok, barrel_a2a_validate:push_config(P)),
        ?_assertEqual(ok, barrel_a2a_validate:push_config(#{<<"url">> => <<"https://hook">>})),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:push_config(P#{
                <<"id">> => <<"i">>,
                <<"taskId">> => <<"t">>,
                <<"token">> => <<"tok">>,
                <<"tenant">> => <<"x">>,
                <<"authentication">> => #{
                    <<"scheme">> => <<"Bearer">>, <<"credentials">> => <<"c">>
                }
            })
        ),
        failures(fun barrel_a2a_validate:push_config/1, [
            {"not object", 1, <<>>},
            {"url missing", maps:remove(<<"url">>, P), <<"url">>},
            {"url empty", P#{<<"url">> => <<>>}, <<"url">>},
            {"url type", P#{<<"url">> => 1}, <<"url">>},
            {"id type", P#{<<"id">> => 1}, <<"id">>},
            {"taskId type", P#{<<"taskId">> => 1}, <<"taskId">>},
            {"token type", P#{<<"token">> => 1}, <<"token">>},
            {"tenant type", P#{<<"tenant">> => 1}, <<"tenant">>},
            {"authentication type", P#{<<"authentication">> => <<"Bearer">>}, <<"authentication">>},
            {"authentication scheme missing", P#{<<"authentication">> => #{}},
                <<"authentication.scheme">>},
            {"authentication scheme empty", P#{<<"authentication">> => #{<<"scheme">> => <<>>}},
                <<"authentication.scheme">>},
            {"authentication scheme type", P#{<<"authentication">> => #{<<"scheme">> => 1}},
                <<"authentication.scheme">>},
            {"authentication credentials",
                P#{<<"authentication">> => #{<<"scheme">> => <<"Bearer">>, <<"credentials">> => 1}},
                <<"authentication.credentials">>}
        ])
    ].

push_config_ref_test_() ->
    [
        ?_assertEqual(
            ok, barrel_a2a_validate:push_config_ref(#{<<"taskId">> => <<"t">>, <<"id">> => <<"c">>})
        ),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:push_config_ref(#{
                <<"taskId">> => <<"t">>, <<"id">> => <<"c">>, <<"tenant">> => <<"x">>
            })
        ),
        failures(fun barrel_a2a_validate:push_config_ref/1, [
            {"not object", 1, <<>>},
            {"taskId missing", #{<<"id">> => <<"c">>}, <<"taskId">>},
            {"taskId type", #{<<"taskId">> => 1, <<"id">> => <<"c">>}, <<"taskId">>},
            {"id missing", #{<<"taskId">> => <<"t">>}, <<"id">>},
            {"id empty", #{<<"taskId">> => <<"t">>, <<"id">> => <<>>}, <<"id">>},
            {"tenant type", #{<<"taskId">> => <<"t">>, <<"id">> => <<"c">>, <<"tenant">> => 1},
                <<"tenant">>}
        ])
    ].

list_push_configs_request_test_() ->
    [
        ?_assertEqual(
            ok, barrel_a2a_validate:list_push_configs_request(#{<<"taskId">> => <<"t">>})
        ),
        ?_assertEqual(
            ok,
            barrel_a2a_validate:list_push_configs_request(#{
                <<"taskId">> => <<"t">>,
                <<"pageSize">> => 5,
                <<"pageToken">> => <<"p">>,
                <<"tenant">> => <<"x">>
            })
        ),
        %% The 1..100 range belongs to ListTasks alone. The
        %% specification states no bounds for this operation, so a size
        %% ListTasks would refuse is fine here. These two validators
        %% look alike; they are not the same.
        ?_assertEqual(
            ok,
            barrel_a2a_validate:list_push_configs_request(#{
                <<"taskId">> => <<"t">>, <<"pageSize">> => 101
            })
        ),
        ?_assertMatch(
            {error, {invalid, <<"pageSize">>, _}},
            barrel_a2a_validate:list_tasks_request(#{<<"pageSize">> => 101})
        ),
        failures(fun barrel_a2a_validate:list_push_configs_request/1, [
            {"not object", 1, <<>>},
            {"taskId missing", #{}, <<"taskId">>},
            {"taskId type", #{<<"taskId">> => 1}, <<"taskId">>},
            {"pageSize", #{<<"taskId">> => <<"t">>, <<"pageSize">> => -1}, <<"pageSize">>},
            {"pageToken", #{<<"taskId">> => <<"t">>, <<"pageToken">> => 1}, <<"pageToken">>},
            {"tenant", #{<<"taskId">> => <<"t">>, <<"tenant">> => 1}, <<"tenant">>}
        ])
    ].

%%--------------------------------------------------------------------
%% to_error
%%--------------------------------------------------------------------

to_error_test_() ->
    [
        ?_test(begin
            {error, Reason} = barrel_a2a_validate:message(#{
                <<"messageId">> => <<"m">>, <<"role">> => 1
            }),
            ?assertEqual({invalid, <<"message.parts">>, <<"is required">>}, Reason),
            E = barrel_a2a_validate:to_error(Reason),
            ?assert(barrel_a2a_error:is_error(E)),
            ?assertEqual(invalid_params, barrel_a2a_error:type(E)),
            ?assertEqual(<<"Invalid parameters: is required">>, barrel_a2a_error:message(E)),
            ?assertMatch(
                [
                    #{
                        <<"@type">> := <<"type.googleapis.com/google.rpc.BadRequest">>,
                        <<"fieldViolations">> := [
                            #{
                                <<"field">> := <<"message.parts">>,
                                <<"description">> := <<"is required">>
                            }
                        ]
                    }
                ],
                barrel_a2a_error:details(E)
            ),
            ?assertEqual(-32602, barrel_a2a_error:jsonrpc_code(barrel_a2a_error:type(E))),
            ?assertEqual(400, barrel_a2a_error:http_status(barrel_a2a_error:type(E)))
        end),
        ?_test(begin
            {error, Reason} = barrel_a2a_validate:part(#{<<"text">> => 1}),
            E = barrel_a2a_validate:to_error(Reason),
            ?assertMatch(
                [
                    #{
                        <<"fieldViolations">> := [
                            #{
                                <<"field">> := <<"part.text">>,
                                <<"description">> := <<"must be a string">>
                            }
                        ]
                    }
                ],
                barrel_a2a_error:details(E)
            )
        end),
        %% the wire form of the error keeps the field
        ?_test(begin
            {error, Reason} = barrel_a2a_validate:get_task_request(#{}),
            Obj = barrel_a2a_error:to_jsonrpc(barrel_a2a_validate:to_error(Reason)),
            ?assertEqual(-32602, maps:get(<<"code">>, Obj)),
            ?assertMatch(
                [_ErrorInfo, #{<<"fieldViolations">> := [#{<<"field">> := <<"id">>}]}],
                maps:get(<<"data">>, Obj)
            )
        end)
    ].
