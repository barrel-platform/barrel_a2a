-module(barrel_a2a_core_tests).

-include_lib("eunit/include/eunit.hrl").

%% Used as a `{Module, State}' auth hook in the auth tests.
-export([authenticate/2]).

authenticate(#{headers := Headers}, State) ->
    case barrel_a2a_auth:header(<<"x-user">>, Headers) of
        undefined -> {error, unauthenticated};
        User -> {ok, {State, User}}
    end.

%%--------------------------------------------------------------------
%% json
%%--------------------------------------------------------------------

nested(N) ->
    iolist_to_binary([lists:duplicate(N, $[), "1", lists:duplicate(N, $])]).

json_test_() ->
    [
        ?_assertEqual(<<"{\"a\":1}">>, barrel_a2a_json:encode(#{<<"a">> => 1})),
        ?_assertEqual(<<"[1,\"x\",null,true]">>, barrel_a2a_json:encode([1, <<"x">>, null, true])),
        ?_assertEqual({ok, #{<<"a">> => [1, 2]}}, barrel_a2a_json:decode(<<"{\"a\":[1,2]}">>)),
        %% ProtoJSON: a repeated key keeps the last occurrence
        ?_assertEqual({ok, #{<<"a">> => 2}}, barrel_a2a_json:decode(<<"{\"a\":1,\"a\":2}">>)),
        ?_assertEqual({ok, #{}}, barrel_a2a_json:decode(<<"{} \n">>)),
        ?_assertEqual({error, parse_error}, barrel_a2a_json:decode(<<"{} x">>)),
        ?_assertEqual({error, parse_error}, barrel_a2a_json:decode(<<"{\"a\":">>)),
        ?_assertEqual({error, parse_error}, barrel_a2a_json:decode(<<>>)),
        ?_assertEqual({error, parse_error}, barrel_a2a_json:decode(not_a_binary)),
        ?_assertMatch({ok, _}, barrel_a2a_json:decode(nested(64))),
        ?_assertEqual({error, too_deep}, barrel_a2a_json:decode(nested(65))),
        ?_assertEqual({ok, [[1]]}, barrel_a2a_json:decode(<<"[[1]]">>, #{max_depth => 2})),
        ?_assertEqual({error, too_deep}, barrel_a2a_json:decode(<<"[[[1]]]">>, #{max_depth => 2})),
        ?_assertEqual(
            {error, too_deep},
            barrel_a2a_json:decode(<<"{\"a\":{\"b\":{\"c\":1}}}">>, #{max_depth => 2})
        ),
        ?_assert(barrel_a2a_json:is_json_media_type(<<"application/json">>)),
        ?_assert(barrel_a2a_json:is_json_media_type(<<"application/json; charset=utf-8">>)),
        ?_assert(barrel_a2a_json:is_json_media_type(<<"Application/A2A+JSON">>)),
        ?_assert(barrel_a2a_json:is_json_media_type(<<" application/vnd.x+json ">>)),
        ?_assertNot(barrel_a2a_json:is_json_media_type(<<"text/plain">>)),
        ?_assertNot(barrel_a2a_json:is_json_media_type(<<"application/jsonx">>)),
        ?_assertNot(barrel_a2a_json:is_json_media_type(undefined)),
        ?_assert(barrel_a2a_json:is_a2a_media_type(<<"application/a2a+json">>)),
        ?_assert(barrel_a2a_json:is_a2a_media_type(<<"APPLICATION/A2A+JSON;charset=utf-8">>)),
        ?_assertNot(barrel_a2a_json:is_a2a_media_type(<<"application/json">>)),
        ?_assertNot(barrel_a2a_json:is_a2a_media_type(undefined))
    ].

%%--------------------------------------------------------------------
%% id
%%--------------------------------------------------------------------

id_test_() ->
    [
        ?_test(begin
            Uuid = barrel_a2a_id:uuid(),
            ?assertEqual(36, byte_size(Uuid)),
            ?assert(barrel_a2a_id:is_uuid(Uuid)),
            %% version 4 nibble and RFC 4122 variant
            ?assertEqual($4, binary:at(Uuid, 14)),
            ?assert(lists:member(binary:at(Uuid, 19), "89ab")),
            ?assertNotEqual(Uuid, barrel_a2a_id:uuid())
        end),
        ?_assert(barrel_a2a_id:is_uuid(<<"123e4567-e89b-12d3-a456-426614174000">>)),
        ?_assert(barrel_a2a_id:is_uuid(<<"123E4567-E89B-12D3-A456-426614174000">>)),
        ?_assertNot(barrel_a2a_id:is_uuid(<<"123e4567-e89b-12d3-a456-42661417400g">>)),
        ?_assertNot(barrel_a2a_id:is_uuid(<<"123e4567e89b12d3a456426614174000">>)),
        ?_assertNot(barrel_a2a_id:is_uuid(<<"short">>)),
        ?_assertNot(barrel_a2a_id:is_uuid(not_a_binary)),
        ?_test(begin
            Term = {1700000000000, <<"task-1">>},
            Cursor = barrel_a2a_id:cursor_encode(Term),
            ?assert(is_binary(Cursor)),
            ?assertNot(barrel_a2a_id:is_uuid(Cursor)),
            %% urlsafe, no padding
            ?assertEqual(nomatch, binary:match(Cursor, [<<"=">>, <<"+">>, <<"/">>])),
            ?assertEqual({ok, Term}, barrel_a2a_id:cursor_decode(Cursor))
        end),
        ?_assertEqual(error, barrel_a2a_id:cursor_decode(<<"!!!not base64">>)),
        ?_assertEqual(error, barrel_a2a_id:cursor_decode(base64:encode(<<"not a term">>))),
        ?_assertEqual(error, barrel_a2a_id:cursor_decode(<<>>)),
        ?_assertEqual(error, barrel_a2a_id:cursor_decode(123))
    ].

%%--------------------------------------------------------------------
%% time
%%--------------------------------------------------------------------

time_test_() ->
    [
        ?_assertEqual(<<"1970-01-01T00:00:00.000Z">>, barrel_a2a_time:to_iso(0)),
        ?_assertEqual(<<"2023-11-14T22:13:20.123Z">>, barrel_a2a_time:to_iso(1700000000123)),
        ?_assertEqual(
            {ok, 1700000000123}, barrel_a2a_time:from_iso(<<"2023-11-14T22:13:20.123Z">>)
        ),
        ?_test(begin
            Ms = 1700000000123,
            ?assertEqual({ok, Ms}, barrel_a2a_time:from_iso(barrel_a2a_time:to_iso(Ms)))
        end),
        ?_test(begin
            Now = barrel_a2a_time:now_ms(),
            ?assertEqual({ok, Now}, barrel_a2a_time:from_iso(barrel_a2a_time:to_iso(Now)))
        end),
        ?_test(begin
            {ok, Ms} = barrel_a2a_time:from_iso(barrel_a2a_time:now_iso()),
            ?assert(abs(Ms - barrel_a2a_time:now_ms()) < 5000)
        end),
        %% offsets are normalized to UTC
        ?_assertEqual(
            barrel_a2a_time:from_iso(<<"2024-01-01T00:00:00Z">>),
            barrel_a2a_time:from_iso(<<"2024-01-01T01:00:00+01:00">>)
        ),
        ?_assertEqual(
            barrel_a2a_time:from_iso(<<"2024-01-01T05:30:00Z">>),
            barrel_a2a_time:from_iso(<<"2024-01-01T00:00:00-05:30">>)
        ),
        ?_test(begin
            {ok, Ms} = barrel_a2a_time:from_iso(<<"2024-01-01T01:00:00+01:00">>),
            ?assertEqual(<<"2024-01-01T00:00:00.000Z">>, barrel_a2a_time:to_iso(Ms))
        end),
        %% fractional seconds of any length truncate to milliseconds
        ?_test(begin
            {ok, A} = barrel_a2a_time:from_iso(<<"2024-01-01T00:00:00.123Z">>),
            {ok, B} = barrel_a2a_time:from_iso(<<"2024-01-01T00:00:00.123456Z">>),
            {ok, C} = barrel_a2a_time:from_iso(<<"2024-01-01T00:00:00Z">>),
            ?assertEqual(A, B),
            ?assertEqual(123, A - C)
        end),
        ?_assertEqual(error, barrel_a2a_time:from_iso(<<"junk">>)),
        ?_assertEqual(error, barrel_a2a_time:from_iso(<<"2024-01-01 00:00:00">>)),
        ?_assertEqual(error, barrel_a2a_time:from_iso(<<>>)),
        ?_assertEqual(error, barrel_a2a_time:from_iso(1700000000)),
        ?_assert(barrel_a2a_time:is_iso(<<"2024-01-01T00:00:00Z">>)),
        ?_assertNot(barrel_a2a_time:is_iso(<<"junk">>)),
        ?_assertNot(barrel_a2a_time:is_iso(<<"2024-01-01">>)),
        ?_assertNot(barrel_a2a_time:is_iso(123)),
        ?_assertNot(barrel_a2a_time:is_iso(undefined))
    ].

%%--------------------------------------------------------------------
%% task_state
%%--------------------------------------------------------------------

%% The table from the module doc.
allowed_to(submitted) ->
    [working, input_required, auth_required, completed, failed, canceled, rejected];
allowed_to(working) ->
    [working, input_required, auth_required, completed, failed, canceled];
allowed_to(input_required) ->
    [working, canceled, failed];
allowed_to(auth_required) ->
    [working, canceled, failed];
allowed_to(_) ->
    [].

all_states() -> [unspecified | barrel_a2a_task_state:states()].

transition_test_() ->
    [
        {
            lists:flatten(io_lib:format("~p -> ~p", [From, To])),
            case lists:member(To, allowed_to(From)) of
                true ->
                    ?_assertEqual(ok, barrel_a2a_task_state:transition(From, To));
                false ->
                    ?_assertEqual(
                        {error, {invalid_transition, From, To}},
                        barrel_a2a_task_state:transition(From, To)
                    )
            end
        }
     || From <- all_states(), To <- all_states()
    ].

task_state_test_() ->
    Terminal = [completed, failed, canceled, rejected],
    Interrupted = [input_required, auth_required],
    [
        ?_assertEqual(
            [
                submitted,
                working,
                completed,
                failed,
                canceled,
                input_required,
                rejected,
                auth_required
            ],
            barrel_a2a_task_state:states()
        ),
        [
            ?_assertEqual(
                {S, lists:member(S, Terminal)},
                {S, barrel_a2a_task_state:is_terminal(S)}
            )
         || S <- all_states()
        ],
        [
            ?_assertEqual(
                {S, lists:member(S, Interrupted)},
                {S, barrel_a2a_task_state:is_interrupted(S)}
            )
         || S <- all_states()
        ],
        [
            ?_assertEqual(
                {S, not lists:member(S, Terminal)},
                {S, barrel_a2a_task_state:cancelable(S)}
            )
         || S <- all_states()
        ],
        [
            ?_assertEqual(
                {S, not lists:member(S, Terminal)},
                {S, barrel_a2a_task_state:accepts_messages(S)}
            )
         || S <- all_states()
        ],
        %% wire round trip for every state including unspecified
        [
            ?_test(begin
                Wire = barrel_a2a_task_state:to_wire(S),
                ?assertMatch(<<"TASK_STATE_", _/binary>>, Wire),
                ?assertEqual({ok, S}, barrel_a2a_task_state:from_wire(Wire)),
                ?assertEqual({ok, S}, barrel_a2a_task_state:from_wire(S))
            end)
         || S <- all_states()
        ],
        ?_assertEqual(
            <<"TASK_STATE_INPUT_REQUIRED">>, barrel_a2a_task_state:to_wire(input_required)
        ),
        ?_assertEqual(<<"TASK_STATE_AUTH_REQUIRED">>, barrel_a2a_task_state:to_wire(auth_required)),
        ?_assertEqual(<<"TASK_STATE_CANCELED">>, barrel_a2a_task_state:to_wire(canceled)),
        %% proto integers
        [
            ?_assertEqual({ok, S}, barrel_a2a_task_state:from_wire(I))
         || {I, S} <- [
                {0, unspecified},
                {1, submitted},
                {2, working},
                {3, completed},
                {4, failed},
                {5, canceled},
                {6, input_required},
                {7, rejected},
                {8, auth_required}
            ]
        ],
        ?_assertEqual(error, barrel_a2a_task_state:from_wire(9)),
        ?_assertEqual(error, barrel_a2a_task_state:from_wire(-1)),
        ?_assertEqual(error, barrel_a2a_task_state:from_wire(<<"TASK_STATE_NOPE">>)),
        ?_assertEqual(error, barrel_a2a_task_state:from_wire(<<"working">>)),
        ?_assertEqual(error, barrel_a2a_task_state:from_wire(bogus)),
        ?_assertEqual(error, barrel_a2a_task_state:from_wire(#{}))
    ].

%%--------------------------------------------------------------------
%% version
%%--------------------------------------------------------------------

version_test_() ->
    [
        ?_assertEqual(<<"1.0">>, barrel_a2a:protocol_version()),
        ?_assertEqual(<<"0.3">>, barrel_a2a:legacy_version()),
        ?_assertEqual({ok, {1, 0}}, barrel_a2a_version:parse(<<"1.0">>)),
        ?_assertEqual({ok, {1, 0}}, barrel_a2a_version:parse(<<"1.0.3">>)),
        ?_assertEqual({ok, {12, 34}}, barrel_a2a_version:parse(<<" 12.34 ">>)),
        ?_assertEqual({ok, {0, 3}}, barrel_a2a_version:parse(undefined)),
        ?_assertEqual({ok, {0, 3}}, barrel_a2a_version:parse(<<>>)),
        ?_assertEqual(error, barrel_a2a_version:parse(<<"1">>)),
        ?_assertEqual(error, barrel_a2a_version:parse(<<"x.y">>)),
        ?_assertEqual(error, barrel_a2a_version:parse(<<"1.">>)),
        ?_assertEqual(error, barrel_a2a_version:parse(10)),
        ?_assertEqual(<<"1.0">>, barrel_a2a_version:normalize({1, 0})),
        ?_assertEqual(<<"1.0">>, barrel_a2a_version:normalize(<<"1.0.3">>)),
        ?_assertEqual(<<"0.3">>, barrel_a2a_version:normalize(undefined)),
        ?_assertEqual(<<"0.3">>, barrel_a2a_version:normalize(<<>>)),
        ?_assertEqual(undefined, barrel_a2a_version:normalize(<<"bad">>)),
        ?_assertEqual(<<"1.0">>, barrel_a2a_version:requested(<<"1.0.1">>)),
        ?_assertEqual(undefined, barrel_a2a_version:requested(<<"nope">>)),
        ?_assertEqual({ok, <<"1.0">>}, barrel_a2a_version:negotiate(<<"1.0">>, [<<"1.0">>])),
        ?_assertEqual({ok, <<"1.0">>}, barrel_a2a_version:negotiate(<<"1.0.9">>, [<<"1.0">>])),
        ?_assertEqual(
            {ok, <<"1.0">>},
            barrel_a2a_version:negotiate(<<"1.0">>, barrel_a2a:supported_versions())
        ),
        ?_assertEqual(
            {ok, <<"1.0">>}, barrel_a2a_version:negotiate(<<"1.0">>, [<<"0.3">>, <<"1.0.0">>])
        ),
        ?_assertEqual({error, unsupported}, barrel_a2a_version:negotiate(<<"2.0">>, [<<"1.0">>])),
        ?_assertEqual({error, unsupported}, barrel_a2a_version:negotiate(<<"bad">>, [<<"1.0">>])),
        %% empty or absent means 0.3
        ?_assertEqual({error, unsupported}, barrel_a2a_version:negotiate(undefined, [<<"1.0">>])),
        ?_assertEqual({error, unsupported}, barrel_a2a_version:negotiate(<<>>, [<<"1.0">>])),
        ?_assertEqual(
            {ok, <<"0.3">>}, barrel_a2a_version:negotiate(undefined, [<<"0.3">>, <<"1.0">>])
        ),
        ?_assertEqual({ok, <<"0.3">>}, barrel_a2a_version:negotiate(<<>>, [<<"0.3">>])),
        ?_assertEqual({error, unsupported}, barrel_a2a_version:negotiate(<<"1.0">>, []))
    ].

%%--------------------------------------------------------------------
%% error
%%--------------------------------------------------------------------

-define(ERROR_INFO, <<"type.googleapis.com/google.rpc.ErrorInfo">>).
-define(BAD_REQUEST, <<"type.googleapis.com/google.rpc.BadRequest">>).

code_table() ->
    [
        {task_not_found, -32001, 404, not_found},
        {task_not_cancelable, -32002, 400, failed_precondition},
        {push_notification_not_supported, -32003, 400, failed_precondition},
        {unsupported_operation, -32004, 400, failed_precondition},
        {content_type_not_supported, -32005, 400, invalid_argument},
        {invalid_agent_response, -32006, 500, internal},
        {extended_agent_card_not_configured, -32007, 400, failed_precondition},
        {extension_support_required, -32008, 400, failed_precondition},
        {version_not_supported, -32009, 400, failed_precondition},
        {parse_error, -32700, 400, invalid_argument},
        {invalid_request, -32600, 400, invalid_argument},
        {method_not_found, -32601, 404, unimplemented},
        {invalid_params, -32602, 400, invalid_argument},
        {internal_error, -32603, 500, internal},
        {unauthenticated, -32010, 401, unauthenticated},
        {permission_denied, -32011, 403, permission_denied},
        {rate_limited, -32012, 429, resource_exhausted},
        {unavailable, -32013, 503, unavailable},
        {timeout, -32014, 504, deadline_exceeded},
        {transport, -32603, 500, internal},
        {something_custom, -32603, 500, internal}
    ].

error_table_test_() ->
    [
        {atom_to_list(Type), [
            ?_assertEqual(Code, barrel_a2a_error:jsonrpc_code(Type)),
            ?_assertEqual(Http, barrel_a2a_error:http_status(Type)),
            ?_assertEqual(Grpc, barrel_a2a_error:grpc_status(Type))
        ]}
     || {Type, Code, Http, Grpc} <- code_table()
    ].

error_test_() ->
    [
        ?_test(begin
            E = barrel_a2a_error:new(task_not_found),
            ?assert(barrel_a2a_error:is_error(E)),
            ?assertEqual(task_not_found, barrel_a2a_error:type(E)),
            ?assertEqual(<<"Task not found">>, barrel_a2a_error:message(E)),
            ?assertEqual([], barrel_a2a_error:details(E))
        end),
        ?_assertEqual(
            #{type => custom, message => <<"custom">>, details => []},
            barrel_a2a_error:new(custom)
        ),
        ?_assertEqual(
            <<"a b">>, barrel_a2a_error:message(barrel_a2a_error:new(timeout, ["a", <<" b">>]))
        ),
        ?_assertNot(barrel_a2a_error:is_error(#{type => x})),
        ?_assertNot(barrel_a2a_error:is_error(#{type => x, message => "list", details => []})),
        ?_assertNot(barrel_a2a_error:is_error(oops)),
        ?_assertEqual(<<"TASK_NOT_FOUND">>, barrel_a2a_error:reason(task_not_found)),
        ?_assertEqual(<<"RATE_LIMITED">>, barrel_a2a_error:reason(rate_limited)),
        ?_assertEqual(
            #{
                <<"@type">> => ?ERROR_INFO,
                <<"reason">> => <<"TASK_NOT_FOUND">>,
                <<"domain">> => <<"a2a-protocol.org">>
            },
            barrel_a2a_error:error_info(task_not_found, #{})
        ),
        ?_assertMatch(
            #{<<"domain">> := <<"example.com">>, <<"metadata">> := #{<<"k">> := <<"v">>}},
            barrel_a2a_error:error_info(timeout, <<"example.com">>, #{<<"k">> => <<"v">>})
        ),
        ?_assertEqual(
            #{
                <<"@type">> => ?BAD_REQUEST,
                <<"fieldViolations">> => [
                    #{<<"field">> => <<"message.parts">>, <<"description">> => <<"is required">>}
                ]
            },
            barrel_a2a_error:bad_request([
                barrel_a2a_error:field_violation("message.parts", <<"is required">>)
            ])
        ),
        ?_test(begin
            E = barrel_a2a_error:invalid(<<"tenant">>, <<"unknown tenant">>),
            ?assertEqual(invalid_params, barrel_a2a_error:type(E)),
            ?assertEqual(<<"Invalid parameters: unknown tenant">>, barrel_a2a_error:message(E)),
            ?assertMatch(
                [
                    #{
                        <<"@type">> := ?BAD_REQUEST,
                        <<"fieldViolations">> := [#{<<"field">> := <<"tenant">>}]
                    }
                ],
                barrel_a2a_error:details(E)
            )
        end),
        ?_test(begin
            E = barrel_a2a_error:internal({badmatch, 1}),
            ?assertEqual(internal_error, barrel_a2a_error:type(E)),
            ?assertEqual(<<"Internal error: {badmatch,1}">>, barrel_a2a_error:message(E))
        end),
        ?_test(begin
            E = barrel_a2a_error:transport(econnrefused),
            ?assertEqual(transport, barrel_a2a_error:type(E)),
            ?assertEqual(<<"Transport error: econnrefused">>, barrel_a2a_error:message(E))
        end)
    ].

to_jsonrpc_test_() ->
    [
        ?_test(begin
            Obj = barrel_a2a_error:to_jsonrpc(barrel_a2a_error:new(task_not_found)),
            ?assertEqual(-32001, maps:get(<<"code">>, Obj)),
            ?assertEqual(<<"Task not found">>, maps:get(<<"message">>, Obj)),
            ?assertMatch(
                [
                    #{
                        <<"@type">> := ?ERROR_INFO,
                        <<"reason">> := <<"TASK_NOT_FOUND">>,
                        <<"domain">> := <<"a2a-protocol.org">>
                    }
                ],
                maps:get(<<"data">>, Obj)
            )
        end),
        %% an existing ErrorInfo detail is kept and not duplicated
        ?_test(begin
            Info = barrel_a2a_error:error_info(task_not_found, #{<<"taskId">> => <<"t1">>}),
            E = barrel_a2a_error:new(task_not_found, <<"gone">>, [Info]),
            Obj = barrel_a2a_error:to_jsonrpc(E),
            ?assertEqual([Info], maps:get(<<"data">>, Obj))
        end),
        %% other details are kept after the injected ErrorInfo
        ?_test(begin
            Bad = barrel_a2a_error:bad_request([]),
            Obj = barrel_a2a_error:to_jsonrpc(barrel_a2a_error:new(invalid_params, <<"x">>, [Bad])),
            ?assertMatch([#{<<"@type">> := ?ERROR_INFO}, Bad], maps:get(<<"data">>, Obj))
        end)
    ].

to_http_body_test_() ->
    [
        ?_test(begin
            Body = barrel_a2a_error:to_http_body(barrel_a2a_error:new(task_not_found)),
            ?assertMatch(
                #{
                    <<"error">> := #{
                        <<"code">> := 404,
                        <<"status">> := <<"NOT_FOUND">>,
                        <<"message">> := <<"Task not found">>,
                        <<"details">> := [
                            #{<<"@type">> := ?ERROR_INFO, <<"reason">> := <<"TASK_NOT_FOUND">>}
                        ]
                    }
                },
                Body
            ),
            ?assertEqual([<<"error">>], maps:keys(Body))
        end),
        [
            ?_assertMatch(
                #{<<"error">> := #{<<"code">> := Code, <<"status">> := Name}},
                barrel_a2a_error:to_http_body(barrel_a2a_error:new(Type))
            )
         || {Type, Code, Name} <- [
                {invalid_params, 400, <<"INVALID_ARGUMENT">>},
                {unauthenticated, 401, <<"UNAUTHENTICATED">>},
                {permission_denied, 403, <<"PERMISSION_DENIED">>},
                {method_not_found, 404, <<"NOT_FOUND">>},
                {rate_limited, 429, <<"RESOURCE_EXHAUSTED">>},
                {internal_error, 500, <<"INTERNAL">>},
                {unavailable, 503, <<"UNAVAILABLE">>},
                {timeout, 504, <<"DEADLINE_EXCEEDED">>}
            ]
        ]
    ].

from_jsonrpc_test_() ->
    [
        %% round trip for every mapped type
        [
            ?_test(begin
                E = barrel_a2a_error:new(Type, <<"m">>),
                Back = barrel_a2a_error:from_jsonrpc(barrel_a2a_error:to_jsonrpc(E)),
                ?assertEqual(Type, barrel_a2a_error:type(Back)),
                ?assertEqual(<<"m">>, barrel_a2a_error:message(Back)),
                ?assertEqual(barrel_a2a_error:jsonrpc_code(Type), maps:get(code, Back)),
                ?assertMatch([#{<<"@type">> := ?ERROR_INFO}], barrel_a2a_error:details(Back))
            end)
         || {Type, _, _, _} <- code_table(), Type =/= transport, Type =/= something_custom
        ],
        %% the reason wins over the numeric code
        ?_test(begin
            Obj = #{
                <<"code">> => -32603,
                <<"message">> => <<"slow down">>,
                <<"data">> => [barrel_a2a_error:error_info(rate_limited, #{})]
            },
            E = barrel_a2a_error:from_jsonrpc(Obj),
            ?assertEqual(rate_limited, barrel_a2a_error:type(E)),
            ?assertEqual(-32603, maps:get(code, E))
        end),
        %% unknown reason falls back to the code
        ?_test(begin
            Obj = #{
                <<"code">> => -32002,
                <<"data">> => [
                    #{<<"@type">> => ?ERROR_INFO, <<"reason">> => <<"SOMETHING_ELSE">>}
                ]
            },
            ?assertEqual(
                task_not_cancelable, barrel_a2a_error:type(barrel_a2a_error:from_jsonrpc(Obj))
            )
        end),
        %% bare code, no data
        ?_test(begin
            E = barrel_a2a_error:from_jsonrpc(#{<<"code">> => -32601}),
            ?assertEqual(method_not_found, barrel_a2a_error:type(E)),
            ?assertEqual(<<>>, barrel_a2a_error:message(E)),
            ?assertEqual([], barrel_a2a_error:details(E))
        end),
        ?_assertEqual(internal_error, barrel_a2a_error:type(barrel_a2a_error:from_jsonrpc(#{}))),
        ?_assertEqual(
            internal_error,
            barrel_a2a_error:type(barrel_a2a_error:from_jsonrpc(#{<<"code">> => 42}))
        ),
        %% non-list data and non-object entries are dropped, non-binary message stringified
        ?_test(begin
            E = barrel_a2a_error:from_jsonrpc(#{
                <<"code">> => -32001, <<"message">> => 12, <<"data">> => #{<<"x">> => 1}
            }),
            ?assertEqual([], barrel_a2a_error:details(E)),
            ?assertEqual(<<"12">>, barrel_a2a_error:message(E))
        end),
        ?_assertEqual(
            [#{<<"a">> => 1}],
            barrel_a2a_error:details(
                barrel_a2a_error:from_jsonrpc(#{<<"data">> => [1, <<"x">>, #{<<"a">> => 1}]})
            )
        )
    ].

from_http_test_() ->
    [
        [
            ?_test(begin
                E = barrel_a2a_error:new(Type, <<"m">>),
                Status = barrel_a2a_error:http_status(Type),
                Back = barrel_a2a_error:from_http(Status, barrel_a2a_error:to_http_body(E)),
                ?assertEqual(Type, barrel_a2a_error:type(Back)),
                ?assertEqual(<<"m">>, barrel_a2a_error:message(Back)),
                ?assertEqual(Status, maps:get(http_status, Back))
            end)
         || {Type, _, _, _} <- code_table(), Type =/= transport, Type =/= something_custom
        ],
        %% reason recovers a type the status alone could not
        ?_test(begin
            Body = barrel_a2a_error:to_http_body(barrel_a2a_error:new(task_not_cancelable)),
            E = barrel_a2a_error:from_http(400, Body),
            ?assertEqual(task_not_cancelable, barrel_a2a_error:type(E))
        end),
        %% no body: status only
        ?_test(begin
            E = barrel_a2a_error:from_http(404, undefined),
            ?assertEqual(task_not_found, barrel_a2a_error:type(E)),
            ?assertEqual(<<"HTTP 404">>, barrel_a2a_error:message(E)),
            ?assertEqual(404, maps:get(http_status, E))
        end),
        [
            ?_assertEqual(Type, barrel_a2a_error:type(barrel_a2a_error:from_http(Status, #{})))
         || {Status, Type} <- [
                {400, invalid_params},
                {401, unauthenticated},
                {403, permission_denied},
                {404, task_not_found},
                {429, rate_limited},
                {500, internal_error},
                {503, unavailable},
                {504, timeout},
                {418, internal_error}
            ]
        ],
        %% error object without reason: status decides
        ?_test(begin
            E = barrel_a2a_error:from_http(403, #{<<"error">> => #{<<"message">> => <<"no">>}}),
            ?assertEqual(permission_denied, barrel_a2a_error:type(E)),
            ?assertEqual(<<"no">>, barrel_a2a_error:message(E))
        end),
        ?_assertEqual(
            unauthenticated,
            barrel_a2a_error:type(barrel_a2a_error:from_http(401, #{<<"error">> => <<"str">>}))
        )
    ].

%%--------------------------------------------------------------------
%% extensions
%%--------------------------------------------------------------------

-define(EXT1, <<"https://example.com/ext/one">>).
-define(EXT2, <<"https://example.com/ext/two">>).
-define(EXT3, <<"https://example.com/ext/three">>).

ext_card() ->
    barrel_a2a_agent_card:new(#{
        name => <<"ext">>,
        capabilities => #{
            extensions => [
                #{<<"uri">> => ?EXT1, <<"required">> => true},
                #{<<"uri">> => ?EXT2},
                #{<<"description">> => <<"no uri">>}
            ]
        }
    }).

extensions_test_() ->
    [
        ?_assertEqual([], barrel_a2a_extensions:parse_header(undefined)),
        ?_assertEqual([], barrel_a2a_extensions:parse_header(<<>>)),
        ?_assertEqual([], barrel_a2a_extensions:parse_header(<<" , ,">>)),
        ?_assertEqual([?EXT1], barrel_a2a_extensions:parse_header(?EXT1)),
        ?_assertEqual(
            [?EXT1, ?EXT2, ?EXT3],
            barrel_a2a_extensions:parse_header(
                <<?EXT1/binary, " , ", ?EXT2/binary, ",,", ?EXT3/binary, " ">>
            )
        ),
        ?_assertEqual(undefined, barrel_a2a_extensions:format_header([])),
        ?_assertEqual(?EXT1, barrel_a2a_extensions:format_header([?EXT1])),
        ?_assertEqual(
            <<?EXT1/binary, ",", ?EXT2/binary>>, barrel_a2a_extensions:format_header([?EXT1, ?EXT2])
        ),
        ?_test(begin
            H = barrel_a2a_extensions:format_header([?EXT1, ?EXT2]),
            ?assertEqual([?EXT1, ?EXT2], barrel_a2a_extensions:parse_header(H))
        end),
        ?_assertEqual([?EXT1, ?EXT2], barrel_a2a_extensions:declared(ext_card())),
        ?_assertEqual(
            [], barrel_a2a_extensions:declared(barrel_a2a_agent_card:new(#{name => <<"x">>}))
        ),
        ?_assertEqual(
            {ok, [?EXT1, ?EXT2]}, barrel_a2a_extensions:negotiate([?EXT1, ?EXT2, ?EXT3], ext_card())
        ),
        %% unknown requested extensions are dropped
        ?_assertEqual({ok, [?EXT1]}, barrel_a2a_extensions:negotiate([?EXT3, ?EXT1], ext_card())),
        ?_assertEqual(
            {error, {required, ?EXT1}}, barrel_a2a_extensions:negotiate([?EXT2], ext_card())
        ),
        ?_assertEqual({error, {required, ?EXT1}}, barrel_a2a_extensions:negotiate([], ext_card())),
        ?_assertEqual(
            {ok, []},
            barrel_a2a_extensions:negotiate([?EXT1], barrel_a2a_agent_card:new(#{name => <<"x">>}))
        )
    ].

%%--------------------------------------------------------------------
%% tenant
%%--------------------------------------------------------------------

field_of(#{details := [#{<<"fieldViolations">> := [#{<<"field">> := F, <<"description">> := D}]}]}) ->
    {F, D}.

tenant_test_() ->
    [
        ?_assertEqual(ok, barrel_a2a_tenant:check(undefined, undefined)),
        ?_assertEqual(ok, barrel_a2a_tenant:check(undefined, <<"anything">>)),
        ?_assertEqual(ok, barrel_a2a_tenant:check(<<"acme">>, <<"acme">>)),
        ?_test(begin
            {error, E} = barrel_a2a_tenant:check(<<"acme">>, undefined),
            ?assertEqual(invalid_params, barrel_a2a_error:type(E)),
            ?assertEqual({<<"tenant">>, <<"tenant is required">>}, field_of(E))
        end),
        ?_test(begin
            {error, E} = barrel_a2a_tenant:check(<<"acme">>, <<"other">>),
            ?assertEqual(invalid_params, barrel_a2a_error:type(E)),
            ?assertEqual({<<"tenant">>, <<"unknown tenant">>}, field_of(E))
        end),
        ?_assertEqual(<<"acme">>, barrel_a2a_tenant:request_tenant(#{<<"tenant">> => <<"acme">>})),
        ?_assertEqual(undefined, barrel_a2a_tenant:request_tenant(#{<<"tenant">> => <<>>})),
        ?_assertEqual(undefined, barrel_a2a_tenant:request_tenant(#{<<"tenant">> => 1})),
        ?_assertEqual(undefined, barrel_a2a_tenant:request_tenant(#{})),
        ?_assertEqual(
            {undefined, <<"/a2a/v1/acme/tasks">>},
            barrel_a2a_tenant:strip_prefix(undefined, {<<"/a2a/v1">>, <<"/a2a/v1/acme/tasks">>})
        ),
        ?_assertEqual(
            {<<"acme">>, <<"/a2a/v1/tasks">>},
            barrel_a2a_tenant:strip_prefix(<<"acme">>, {<<"/a2a/v1">>, <<"/a2a/v1/acme/tasks">>})
        ),
        ?_assertEqual(
            {<<"acme">>, <<"/a2a/v1/tasks/1:cancel">>},
            barrel_a2a_tenant:strip_prefix(
                <<"acme">>, {<<"/a2a/v1">>, <<"/a2a/v1/acme/tasks/1:cancel">>}
            )
        ),
        ?_assertEqual(
            {<<"acme">>, <<"/a2a/v1">>},
            barrel_a2a_tenant:strip_prefix(<<"acme">>, {<<"/a2a/v1">>, <<"/a2a/v1/acme">>})
        ),
        ?_assertEqual(
            {undefined, <<"/a2a/v1/other/tasks">>},
            barrel_a2a_tenant:strip_prefix(<<"acme">>, {<<"/a2a/v1">>, <<"/a2a/v1/other/tasks">>})
        ),
        %% a segment that merely starts with the tenant is not the tenant
        ?_assertEqual(
            {undefined, <<"/a2a/v1/acmeco/tasks">>},
            barrel_a2a_tenant:strip_prefix(<<"acme">>, {<<"/a2a/v1">>, <<"/a2a/v1/acmeco/tasks">>})
        ),
        ?_assertEqual(
            {undefined, <<"/a2a/v1/tasks">>},
            barrel_a2a_tenant:strip_prefix(<<"acme">>, {<<"/a2a/v1">>, <<"/a2a/v1/tasks">>})
        )
    ].

%%--------------------------------------------------------------------
%% auth
%%--------------------------------------------------------------------

req(Headers) ->
    #{headers => Headers, op => send_message, binding => jsonrpc}.

bearer_hook(<<"good">>) -> {ok, {user, <<"alice">>}};
bearer_hook(<<"forbidden">>) -> {error, forbidden};
bearer_hook(<<"weird">>) -> {error, {expired, 12}};
bearer_hook(<<"garbage">>) -> not_a_result;
bearer_hook(<<"crash">>) -> error(boom);
bearer_hook(_) -> {error, unauthenticated}.

auth_normalize_test_() ->
    Fun1 = fun(_) -> {ok, x} end,
    Fun2 = fun(_, _) -> {ok, x} end,
    [
        ?_assertEqual({ok, none}, barrel_a2a_auth:normalize(none)),
        ?_assertEqual({ok, none}, barrel_a2a_auth:normalize(undefined)),
        ?_assertEqual({ok, {bearer, Fun1}}, barrel_a2a_auth:normalize({bearer, Fun1})),
        ?_assertEqual(
            {ok, {api_key, <<"X-Key">>, Fun1}},
            barrel_a2a_auth:normalize({api_key, <<"X-Key">>, Fun1})
        ),
        ?_assertEqual({ok, {basic, Fun2}}, barrel_a2a_auth:normalize({basic, Fun2})),
        ?_assertEqual({ok, Fun1}, barrel_a2a_auth:normalize(Fun1)),
        ?_assertEqual({ok, {?MODULE, s}}, barrel_a2a_auth:normalize({?MODULE, s})),
        %% a wrong-arity fun falls through to the `{Module, State}' clause
        ?_assertMatch(
            {error, {auth_not_loaded, bearer, _}}, barrel_a2a_auth:normalize({bearer, Fun2})
        ),
        ?_assertMatch(
            {error, {auth_not_loaded, basic, _}}, barrel_a2a_auth:normalize({basic, Fun1})
        ),
        ?_assertMatch({error, {invalid_auth, _}}, barrel_a2a_auth:normalize({api_key, "X", Fun1})),
        ?_assertMatch({error, {invalid_auth, _}}, barrel_a2a_auth:normalize(bogus)),
        ?_assertEqual(
            {error, {auth_missing_callback, lists}}, barrel_a2a_auth:normalize({lists, s})
        ),
        ?_assertMatch(
            {error, {auth_not_loaded, no_such_module_xyz, _}},
            barrel_a2a_auth:normalize({no_such_module_xyz, s})
        )
    ].

auth_authenticate_test_() ->
    Bearer = {bearer, fun bearer_hook/1},
    ApiKey =
        {api_key, <<"X-Api-Key">>, fun
            (<<"k1">>) -> {ok, key_user};
            (_) -> {error, unauthenticated}
        end},
    Basic =
        {basic, fun
            (<<"u">>, <<"p">>) -> {ok, basic_user};
            (_, _) -> {error, forbidden}
        end},
    Fun = fun(#{headers := H, op := Op, binding := B}) -> {ok, {Op, B, length(H)}} end,
    [
        ?_assertEqual({ok, anonymous}, barrel_a2a_auth:authenticate(none, req([]), #{})),
        %% bearer
        ?_assertEqual(
            {ok, {user, <<"alice">>}},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"Authorization">>, <<"Bearer good">>}]), #{}
            )
        ),
        ?_assertEqual(
            {ok, {user, <<"alice">>}},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<" bearer  good ">>}]), #{}
            )
        ),
        ?_assertEqual({error, unauthenticated}, barrel_a2a_auth:authenticate(Bearer, req([]), #{})),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<"Basic good">>}]), #{}
            )
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(Bearer, req([{<<"authorization">>, <<"good">>}]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<"Bearer nope">>}]), #{}
            )
        ),
        ?_assertEqual(
            {error, forbidden},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<"Bearer forbidden">>}]), #{}
            )
        ),
        %% other reasons, bad returns and crashes all collapse to unauthenticated
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<"Bearer weird">>}]), #{}
            )
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<"Bearer garbage">>}]), #{}
            )
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Bearer, req([{<<"authorization">>, <<"Bearer crash">>}]), #{}
            )
        ),
        %% api key, header name case-insensitive
        ?_assertEqual(
            {ok, key_user},
            barrel_a2a_auth:authenticate(ApiKey, req([{<<"x-api-key">>, <<"k1">>}]), #{})
        ),
        ?_assertEqual(
            {ok, key_user},
            barrel_a2a_auth:authenticate(ApiKey, req([{<<"X-API-KEY">>, <<"k1">>}]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(ApiKey, req([{<<"x-api-key">>, <<"k2">>}]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(ApiKey, req([{<<"authorization">>, <<"Bearer k1">>}]), #{})
        ),
        %% basic
        ?_assertEqual(
            {ok, basic_user},
            barrel_a2a_auth:authenticate(
                Basic,
                req([{<<"authorization">>, <<"Basic ", (base64:encode(<<"u:p">>))/binary>>}]),
                #{}
            )
        ),
        ?_assertEqual(
            {error, forbidden},
            barrel_a2a_auth:authenticate(
                Basic,
                req([{<<"authorization">>, <<"basic ", (base64:encode(<<"u:x">>))/binary>>}]),
                #{}
            )
        ),
        ?_assertEqual({error, unauthenticated}, barrel_a2a_auth:authenticate(Basic, req([]), #{})),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(Basic, req([{<<"authorization">>, <<"Basic !!!">>}]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Basic,
                req([{<<"authorization">>, <<"Basic ", (base64:encode(<<"nocolon">>))/binary>>}]),
                #{}
            )
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(
                Basic,
                req([{<<"authorization">>, <<"Bearer ", (base64:encode(<<"u:p">>))/binary>>}]),
                #{}
            )
        ),
        %% fun and module hooks see the whole request
        ?_assertEqual(
            {ok, {send_message, jsonrpc, 1}},
            barrel_a2a_auth:authenticate(Fun, req([{<<"h">>, <<"v">>}]), #{})
        ),
        ?_assertEqual(
            {ok, {state1, <<"bob">>}},
            barrel_a2a_auth:authenticate({?MODULE, state1}, req([{<<"X-User">>, <<"bob">>}]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate({?MODULE, state1}, req([]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(fun(_) -> throw(nope) end, req([]), #{})
        ),
        ?_assertEqual(
            {error, unauthenticated},
            barrel_a2a_auth:authenticate(fun(_) -> {error, some_reason} end, req([]), #{})
        )
    ].

auth_header_test_() ->
    Headers = [
        {<<"Content-Type">>, <<"a">>}, {<<"X-Thing">>, <<"first">>}, {<<"x-thing">>, <<"second">>}
    ],
    [
        ?_assertEqual(<<"a">>, barrel_a2a_auth:header(<<"content-type">>, Headers)),
        ?_assertEqual(<<"first">>, barrel_a2a_auth:header(<<"x-thing">>, Headers)),
        ?_assertEqual(undefined, barrel_a2a_auth:header(<<"missing">>, Headers)),
        ?_assertEqual(undefined, barrel_a2a_auth:header(<<"x">>, []))
    ].

card_with_schemes(Schemes) ->
    barrel_a2a_agent_card:new(#{name => <<"c">>, security_schemes => Schemes}).

challenge_test_() ->
    Http = barrel_a2a_agent_card:security_scheme(http, #{scheme => <<"bearer">>}),
    Oidc = barrel_a2a_agent_card:security_scheme(openid_connect, #{
        open_id_connect_url => <<"https://issuer/.well-known/openid-configuration">>
    }),
    OAuth = barrel_a2a_agent_card:security_scheme(oauth2, #{flows => #{}}),
    Key = barrel_a2a_agent_card:security_scheme(api_key, #{location => header, name => <<"X-Key">>}),
    Mtls = barrel_a2a_agent_card:security_scheme(mtls, #{}),
    Digest = barrel_a2a_agent_card:security_scheme(http, #{scheme => <<"digest">>}),
    NoCard = barrel_a2a_agent_card:new(#{name => <<"c">>}),
    [
        ?_assertEqual([], barrel_a2a_auth:challenge_headers(none, NoCard)),
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Bearer">>}],
            barrel_a2a_auth:challenge_headers({bearer, fun bearer_hook/1}, NoCard)
        ),
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Basic realm=\"a2a\"">>}],
            barrel_a2a_auth:challenge_headers({basic, fun(_, _) -> {ok, x} end}, NoCard)
        ),
        %% card schemes: http scheme capitalized, oauth2 and oidc are Bearer, api key and mtls none
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Bearer">>}],
            barrel_a2a_auth:challenge_headers(none, card_with_schemes(#{<<"b">> => Http}))
        ),
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Bearer">>}],
            barrel_a2a_auth:challenge_headers(
                none, card_with_schemes(#{<<"o">> => Oidc, <<"a">> => OAuth})
            )
        ),
        ?_assertEqual(
            [],
            barrel_a2a_auth:challenge_headers(
                none, card_with_schemes(#{<<"k">> => Key, <<"m">> => Mtls})
            )
        ),
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Digest">>}],
            barrel_a2a_auth:challenge_headers(none, card_with_schemes(#{<<"d">> => Digest}))
        ),
        %% deduplicated and sorted, config and card merged
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Basic realm=\"a2a\", Bearer, Digest">>}],
            barrel_a2a_auth:challenge_headers(
                {basic, fun(_, _) -> {ok, x} end},
                card_with_schemes(#{
                    <<"b">> => Http, <<"o">> => Oidc, <<"d">> => Digest, <<"k">> => Key
                })
            )
        ),
        ?_assertEqual(
            [{<<"www-authenticate">>, <<"Bearer">>}],
            barrel_a2a_auth:challenge_headers(
                {bearer, fun bearer_hook/1}, card_with_schemes(#{<<"b">> => Http})
            )
        )
    ].
