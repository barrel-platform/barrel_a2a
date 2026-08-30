-module(barrel_a2a_jsonrpc_rest_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BASE, <<"/a2a/v1">>).

ops() ->
    [
        send_message,
        send_streaming_message,
        get_task,
        list_tasks,
        cancel_task,
        subscribe_to_task,
        create_push_config,
        get_push_config,
        list_push_configs,
        delete_push_config,
        get_extended_agent_card
    ].

%%--------------------------------------------------------------------
%% jsonrpc
%%--------------------------------------------------------------------

jsonrpc_shapes_test_() ->
    Err = barrel_a2a_error:new(task_not_found),
    [
        ?_assertEqual(
            #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => 1,
                <<"method">> => <<"GetTask">>,
                <<"params">> => #{<<"id">> => <<"t">>}
            },
            barrel_a2a_jsonrpc:request(1, <<"GetTask">>, #{<<"id">> => <<"t">>})
        ),
        ?_assertEqual(
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => <<"abc">>, <<"method">> => <<"ListTasks">>},
            barrel_a2a_jsonrpc:request(<<"abc">>, <<"ListTasks">>, undefined)
        ),
        ?_assertEqual(
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 7, <<"result">> => #{<<"ok">> => true}},
            barrel_a2a_jsonrpc:response(7, #{<<"ok">> => true})
        ),
        ?_assertEqual(
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => null, <<"result">> => null},
            barrel_a2a_jsonrpc:response(null, null)
        ),
        ?_test(begin
            Resp = barrel_a2a_jsonrpc:error_response(3, Err),
            ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Resp)),
            ?assertEqual(3, maps:get(<<"id">>, Resp)),
            ?assertEqual(barrel_a2a_error:to_jsonrpc(Err), maps:get(<<"error">>, Resp)),
            ?assertMatch(
                #{<<"code">> := -32001, <<"message">> := <<"Task not found">>},
                maps:get(<<"error">>, Resp)
            ),
            ?assertNot(maps:is_key(<<"result">>, Resp))
        end),
        %% envelopes survive a JSON round trip
        ?_test(begin
            Req = barrel_a2a_jsonrpc:request(<<"x">>, <<"SendMessage">>, #{<<"message">> => #{}}),
            {ok, Decoded} = barrel_a2a_json:decode(barrel_a2a_json:encode(Req)),
            ?assertEqual(Req, Decoded)
        end)
    ].

classify_test_() ->
    Rpc = #{<<"jsonrpc">> => <<"2.0">>},
    Err = barrel_a2a_error:to_jsonrpc(barrel_a2a_error:new(task_not_cancelable)),
    [
        ?_assertEqual(
            {request, 1, <<"GetTask">>, #{<<"id">> => <<"t">>}},
            barrel_a2a_jsonrpc:classify(Rpc#{
                <<"id">> => 1, <<"method">> => <<"GetTask">>, <<"params">> => #{<<"id">> => <<"t">>}
            })
        ),
        %% string and null ids are accepted, missing params become an empty object
        ?_assertEqual(
            {request, <<"r-1">>, <<"ListTasks">>, #{}},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => <<"r-1">>, <<"method">> => <<"ListTasks">>})
        ),
        ?_assertEqual(
            {request, null, <<"ListTasks">>, #{}},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => null, <<"method">> => <<"ListTasks">>})
        ),
        ?_assertEqual(
            {response, 2, #{<<"a">> => 1}},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => 2, <<"result">> => #{<<"a">> => 1}})
        ),
        ?_assertEqual(
            {response, null, null}, barrel_a2a_jsonrpc:classify(Rpc#{<<"result">> => null})
        ),
        ?_test(begin
            {error, Id, E} = barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => 5, <<"error">> => Err}),
            ?assertEqual(5, Id),
            ?assertEqual(task_not_cancelable, barrel_a2a_error:type(E)),
            ?assertEqual(-32002, maps:get(code, E))
        end),
        ?_assertMatch(
            {error, null, #{type := internal_error}},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"error">> => #{}})
        ),
        %% notification: request without id
        ?_assertEqual(
            {invalid, null, <<"notifications are not supported">>},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"method">> => <<"GetTask">>, <<"params">> => #{}})
        ),
        %% an id of the wrong type counts as absent
        ?_assertEqual(
            {invalid, null, <<"notifications are not supported">>},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => #{}, <<"method">> => <<"GetTask">>})
        ),
        ?_assertEqual(
            {invalid, null, <<"batch requests are not supported">>},
            barrel_a2a_jsonrpc:classify([Rpc#{<<"id">> => 1, <<"method">> => <<"GetTask">>}])
        ),
        ?_assertEqual(
            {invalid, null, <<"batch requests are not supported">>}, barrel_a2a_jsonrpc:classify([])
        ),
        ?_assertEqual(
            {invalid, 9, <<"params must be an object">>},
            barrel_a2a_jsonrpc:classify(Rpc#{
                <<"id">> => 9, <<"method">> => <<"GetTask">>, <<"params">> => [1]
            })
        ),
        ?_assertEqual(
            {invalid, null, <<"params must be an object">>},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"method">> => <<"GetTask">>, <<"params">> => <<"x">>})
        ),
        %% not a JSON-RPC 2.0 message
        ?_assertEqual(
            {invalid, 4, <<"not a JSON-RPC 2.0 message">>},
            barrel_a2a_jsonrpc:classify(#{<<"id">> => 4, <<"method">> => <<"GetTask">>})
        ),
        ?_assertEqual(
            {invalid, 4, <<"not a JSON-RPC 2.0 message">>},
            barrel_a2a_jsonrpc:classify(#{
                <<"jsonrpc">> => <<"1.0">>, <<"id">> => 4, <<"method">> => <<"GetTask">>
            })
        ),
        %% a non-string method is not a request; the id is still echoed
        ?_assertEqual(
            {invalid, 4, <<"not a JSON-RPC 2.0 message">>},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => 4, <<"method">> => 12})
        ),
        ?_assertEqual(
            {invalid, null, <<"not a JSON-RPC 2.0 message">>}, barrel_a2a_jsonrpc:classify(#{})
        ),
        ?_assertEqual(
            {invalid, null, <<"not a JSON-RPC 2.0 message">>}, barrel_a2a_jsonrpc:classify(<<"x">>)
        ),
        ?_assertEqual(
            {invalid, null, <<"not a JSON-RPC 2.0 message">>}, barrel_a2a_jsonrpc:classify(null)
        ),
        %% a request with an error object is an error envelope, not a request
        ?_assertMatch(
            {error, 1, _},
            barrel_a2a_jsonrpc:classify(Rpc#{<<"id">> => 1, <<"error">> => Err, <<"result">> => 1})
        )
    ].

method_table_test_() ->
    Names = [
        {send_message, <<"SendMessage">>},
        {send_streaming_message, <<"SendStreamingMessage">>},
        {get_task, <<"GetTask">>},
        {list_tasks, <<"ListTasks">>},
        {cancel_task, <<"CancelTask">>},
        {subscribe_to_task, <<"SubscribeToTask">>},
        {create_push_config, <<"CreateTaskPushNotificationConfig">>},
        {get_push_config, <<"GetTaskPushNotificationConfig">>},
        {list_push_configs, <<"ListTaskPushNotificationConfigs">>},
        {delete_push_config, <<"DeleteTaskPushNotificationConfig">>},
        {get_extended_agent_card, <<"GetExtendedAgentCard">>}
    ],
    [
        ?_assertEqual(ops(), barrel_a2a_jsonrpc:methods()),
        ?_assertEqual(11, length(barrel_a2a_jsonrpc:methods())),
        [
            {atom_to_list(Op), [
                ?_assertEqual(Name, barrel_a2a_jsonrpc:method_name(Op)),
                ?_assertEqual({ok, Op}, barrel_a2a_jsonrpc:op_for_method(Name))
            ]}
         || {Op, Name} <- Names
        ],
        ?_assertEqual(error, barrel_a2a_jsonrpc:op_for_method(<<"sendMessage">>)),
        ?_assertEqual(error, barrel_a2a_jsonrpc:op_for_method(<<"message/send">>)),
        ?_assertEqual(error, barrel_a2a_jsonrpc:op_for_method(<<>>)),
        [
            ?_assertEqual(
                {Op, lists:member(Op, [send_streaming_message, subscribe_to_task])},
                {Op, barrel_a2a_jsonrpc:is_streaming(Op)}
            )
         || Op <- ops()
        ]
    ].

%%--------------------------------------------------------------------
%% rest routes and matching
%%--------------------------------------------------------------------

routes() -> barrel_a2a_rest:routes(?BASE).

match(Method, Path) -> barrel_a2a_rest:match(Method, Path, routes()).

routes_test_() ->
    [
        ?_assertEqual(11, length(routes())),
        ?_assertEqual(ops(), [Op || {_, _, Op} <- routes()]),
        ?_assert(
            lists:all(fun({_, P, _}) -> binary:part(P, 0, byte_size(?BASE)) =:= ?BASE end, routes())
        ),
        ?_assertEqual(11, length(barrel_a2a_rest:routes(<<>>))),
        ?_assertMatch(
            {<<"POST">>, <<"/message:send">>, send_message}, hd(barrel_a2a_rest:routes(<<>>))
        )
    ].

match_test_() ->
    [
        ?_assertEqual({ok, send_message, #{}}, match(<<"POST">>, <<"/a2a/v1/message:send">>)),
        ?_assertEqual(
            {ok, send_streaming_message, #{}}, match(<<"POST">>, <<"/a2a/v1/message:stream">>)
        ),
        ?_assertEqual(
            {ok, get_task, #{<<"id">> => <<"t1">>}}, match(<<"GET">>, <<"/a2a/v1/tasks/t1">>)
        ),
        ?_assertEqual({ok, list_tasks, #{}}, match(<<"GET">>, <<"/a2a/v1/tasks">>)),
        ?_assertEqual({ok, list_tasks, #{}}, match(<<"GET">>, <<"/a2a/v1/tasks/">>)),
        ?_assertEqual(
            {ok, cancel_task, #{<<"id">> => <<"t1">>}},
            match(<<"POST">>, <<"/a2a/v1/tasks/t1:cancel">>)
        ),
        ?_assertEqual(
            {ok, subscribe_to_task, #{<<"id">> => <<"t1">>}},
            match(<<"POST">>, <<"/a2a/v1/tasks/t1:subscribe">>)
        ),
        ?_assertEqual(
            {ok, create_push_config, #{<<"id">> => <<"t1">>}},
            match(<<"POST">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs">>)
        ),
        ?_assertEqual(
            {ok, get_push_config, #{<<"id">> => <<"t1">>, <<"configId">> => <<"c1">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs/c1">>)
        ),
        ?_assertEqual(
            {ok, list_push_configs, #{<<"id">> => <<"t1">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs">>)
        ),
        ?_assertEqual(
            {ok, delete_push_config, #{<<"id">> => <<"t1">>, <<"configId">> => <<"c1">>}},
            match(<<"DELETE">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs/c1">>)
        ),
        ?_assertEqual(
            {ok, get_extended_agent_card, #{}}, match(<<"GET">>, <<"/a2a/v1/extendedAgentCard">>)
        ),
        %% a uuid-looking id
        ?_assertEqual(
            {ok, get_task, #{<<"id">> => <<"123e4567-e89b-12d3-a456-426614174000">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/123e4567-e89b-12d3-a456-426614174000">>)
        ),
        %% percent-decoding of path bindings
        ?_assertEqual(
            {ok, get_task, #{<<"id">> => <<"a b/c">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/a%20b%2Fc">>)
        ),
        ?_assertEqual(
            {ok, cancel_task, #{<<"id">> => <<"a b">>}},
            match(<<"POST">>, <<"/a2a/v1/tasks/a%20b:cancel">>)
        ),
        ?_assertEqual(
            {ok, get_push_config, #{<<"id">> => <<"t 1">>, <<"configId">> => <<"c:1">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/t%201/pushNotificationConfigs/c%3A1">>)
        ),
        %% BUG: src/barrel_a2a_rest.erl uri_decode/1 matches on a
        %% `{error, _, _}' return, but uri_string:percent_decode/1 (OTP 27+)
        %% throws `{error, invalid_percent_encoding, _}' for a bad escape, so
        %% the throw escapes match/3 and a crafted path crashes the request.
        %% The doc comment says invalid escapes are left as is.
        ?_assertEqual(
            {ok, get_task, #{<<"id">> => <<"a%ZZ">>}}, match(<<"GET">>, <<"/a2a/v1/tasks/a%ZZ">>)
        ),
        %% 404
        ?_assertEqual({error, not_found}, match(<<"GET">>, <<"/a2a/v1/nope">>)),
        ?_assertEqual({error, not_found}, match(<<"GET">>, <<"/other/tasks">>)),
        ?_assertEqual({error, not_found}, match(<<"GET">>, <<"/a2a/v1/tasks/t1/extra/segments">>)),
        %% a colon inside the id segment is just part of the id for GET, so an
        %% unknown verb is a 405 against get_task rather than a 404
        ?_assertEqual(
            {error, {method_not_allowed, [<<"GET">>]}},
            match(<<"POST">>, <<"/a2a/v1/tasks/:cancel">>)
        ),
        ?_assertEqual(
            {error, {method_not_allowed, [<<"GET">>]}},
            match(<<"POST">>, <<"/a2a/v1/tasks/t1:reboot">>)
        ),
        ?_assertEqual(
            {ok, get_task, #{<<"id">> => <<"t1:reboot">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/t1:reboot">>)
        ),
        ?_assertEqual({error, not_found}, match(<<"GET">>, <<"/">>)),
        ?_assertEqual({error, not_found}, match(<<"GET">>, <<>>)),
        %% 405 with the allowed methods
        ?_assertEqual(
            {error, {method_not_allowed, [<<"POST">>]}},
            match(<<"GET">>, <<"/a2a/v1/message:send">>)
        ),
        ?_assertEqual(
            {error, {method_not_allowed, [<<"GET">>]}}, match(<<"DELETE">>, <<"/a2a/v1/tasks/t1">>)
        ),
        ?_assertEqual(
            {error, {method_not_allowed, [<<"GET">>]}}, match(<<"POST">>, <<"/a2a/v1/tasks">>)
        ),
        ?_assertEqual(
            {error, {method_not_allowed, [<<"DELETE">>, <<"GET">>]}},
            match(<<"PUT">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs/c1">>)
        ),
        ?_assertEqual(
            {error, {method_not_allowed, [<<"GET">>, <<"POST">>]}},
            match(<<"PATCH">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs">>)
        ),
        ?_assertEqual(
            %% GET on a verb path reads as get_task with the verb in the id
            {ok, get_task, #{<<"id">> => <<"t1:subscribe">>}},
            match(<<"GET">>, <<"/a2a/v1/tasks/t1:subscribe">>)
        ),
        %% methods are case sensitive
        ?_assertEqual(
            {error, {method_not_allowed, [<<"POST">>]}},
            match(<<"post">>, <<"/a2a/v1/message:send">>)
        )
    ].

%%--------------------------------------------------------------------
%% build_request
%%--------------------------------------------------------------------

build_request_test_() ->
    Body = #{<<"message">> => #{<<"messageId">> => <<"m">>}},
    [
        ?_assertEqual(Body, barrel_a2a_rest:build_request(send_message, #{}, [], Body)),
        ?_assertEqual(
            Body,
            barrel_a2a_rest:build_request(send_streaming_message, #{}, [{<<"x">>, <<"1">>}], Body)
        ),
        ?_assertEqual(#{}, barrel_a2a_rest:build_request(send_message, #{}, [], undefined)),
        ?_assertEqual(#{}, barrel_a2a_rest:build_request(send_message, #{}, [], [1, 2])),
        %% get_task: id from the path, historyLength typed from the query
        ?_assertEqual(
            #{<<"id">> => <<"t1">>},
            barrel_a2a_rest:build_request(get_task, #{<<"id">> => <<"t1">>}, [], undefined)
        ),
        ?_assertEqual(
            #{<<"id">> => <<"t1">>, <<"historyLength">> => 5},
            barrel_a2a_rest:build_request(
                get_task, #{<<"id">> => <<"t1">>}, [{<<"historyLength">>, <<"5">>}], undefined
            )
        ),
        %% a non-integer value is kept raw so validation reports it
        ?_assertEqual(
            #{<<"id">> => <<"t1">>, <<"historyLength">> => <<"five">>},
            barrel_a2a_rest:build_request(
                get_task, #{<<"id">> => <<"t1">>}, [{<<"historyLength">>, <<"five">>}], undefined
            )
        ),
        %% unknown query keys and the body are ignored
        ?_assertEqual(
            #{<<"id">> => <<"t1">>},
            barrel_a2a_rest:build_request(
                get_task, #{<<"id">> => <<"t1">>}, [{<<"foo">>, <<"bar">>}], Body
            )
        ),
        %% list_tasks: every query parameter with its type
        ?_assertEqual(#{}, barrel_a2a_rest:build_request(list_tasks, #{}, [], undefined)),
        ?_assertEqual(
            #{
                <<"contextId">> => <<"c1">>,
                <<"status">> => <<"TASK_STATE_WORKING">>,
                <<"pageSize">> => 20,
                <<"pageToken">> => <<"tok">>,
                <<"historyLength">> => 0,
                <<"statusTimestampAfter">> => <<"2024-01-01T00:00:00Z">>,
                <<"includeArtifacts">> => true
            },
            barrel_a2a_rest:build_request(
                list_tasks,
                #{},
                [
                    {<<"contextId">>, <<"c1">>},
                    {<<"status">>, <<"TASK_STATE_WORKING">>},
                    {<<"pageSize">>, <<"20">>},
                    {<<"pageToken">>, <<"tok">>},
                    {<<"historyLength">>, <<"0">>},
                    {<<"statusTimestampAfter">>, <<"2024-01-01T00:00:00Z">>},
                    {<<"includeArtifacts">>, <<"true">>},
                    {<<"ignored">>, <<"x">>}
                ],
                undefined
            )
        ),
        ?_assertEqual(
            #{<<"includeArtifacts">> => false},
            barrel_a2a_rest:build_request(
                list_tasks, #{}, [{<<"includeArtifacts">>, <<"false">>}], undefined
            )
        ),
        ?_assertEqual(
            #{<<"includeArtifacts">> => <<"yes">>},
            barrel_a2a_rest:build_request(
                list_tasks, #{}, [{<<"includeArtifacts">>, <<"yes">>}], undefined
            )
        ),
        ?_assertEqual(
            #{<<"pageSize">> => -1},
            barrel_a2a_rest:build_request(list_tasks, #{}, [{<<"pageSize">>, <<"-1">>}], undefined)
        ),
        %% first occurrence of a repeated parameter wins
        ?_assertEqual(
            #{<<"pageSize">> => 1},
            barrel_a2a_rest:build_request(
                list_tasks, #{}, [{<<"pageSize">>, <<"1">>}, {<<"pageSize">>, <<"2">>}], undefined
            )
        ),
        %% cancel_task: body merged with the path id, the path wins
        ?_assertEqual(
            #{<<"id">> => <<"t1">>},
            barrel_a2a_rest:build_request(cancel_task, #{<<"id">> => <<"t1">>}, [], undefined)
        ),
        ?_assertEqual(
            #{<<"id">> => <<"t1">>, <<"metadata">> => #{<<"why">> => <<"x">>}},
            barrel_a2a_rest:build_request(
                cancel_task, #{<<"id">> => <<"t1">>}, [], #{
                    <<"id">> => <<"other">>, <<"metadata">> => #{<<"why">> => <<"x">>}
                }
            )
        ),
        ?_assertEqual(
            #{<<"id">> => <<"t1">>},
            barrel_a2a_rest:build_request(
                subscribe_to_task, #{<<"id">> => <<"t1">>}, [{<<"x">>, <<"1">>}], Body
            )
        ),
        %% push configs
        ?_assertEqual(
            #{<<"taskId">> => <<"t1">>, <<"url">> => <<"https://hook">>},
            barrel_a2a_rest:build_request(create_push_config, #{<<"id">> => <<"t1">>}, [], #{
                <<"url">> => <<"https://hook">>
            })
        ),
        ?_assertEqual(
            #{<<"taskId">> => <<"t1">>},
            barrel_a2a_rest:build_request(
                create_push_config, #{<<"id">> => <<"t1">>}, [], undefined
            )
        ),
        ?_assertEqual(
            #{<<"taskId">> => <<"t1">>, <<"id">> => <<"c1">>},
            barrel_a2a_rest:build_request(
                get_push_config, #{<<"id">> => <<"t1">>, <<"configId">> => <<"c1">>}, [], undefined
            )
        ),
        ?_assertEqual(
            #{<<"taskId">> => <<"t1">>, <<"id">> => <<"c1">>},
            barrel_a2a_rest:build_request(
                delete_push_config, #{<<"id">> => <<"t1">>, <<"configId">> => <<"c1">>}, [], Body
            )
        ),
        ?_assertEqual(
            #{<<"taskId">> => <<"t1">>},
            barrel_a2a_rest:build_request(list_push_configs, #{<<"id">> => <<"t1">>}, [], undefined)
        ),
        ?_assertEqual(
            #{<<"taskId">> => <<"t1">>, <<"pageSize">> => 3, <<"pageToken">> => <<"p">>},
            barrel_a2a_rest:build_request(
                list_push_configs,
                #{<<"id">> => <<"t1">>},
                [{<<"pageSize">>, <<"3">>}, {<<"pageToken">>, <<"p">>}],
                undefined
            )
        ),
        ?_assertEqual(
            #{},
            barrel_a2a_rest:build_request(get_extended_agent_card, #{}, [{<<"a">>, <<"b">>}], Body)
        ),
        %% match then build, end to end
        ?_test(begin
            {ok, Op, Bindings} = match(<<"GET">>, <<"/a2a/v1/tasks/t%201?ignored">>),
            ?assertEqual(get_task, Op),
            %% the query string is not part of the path; the caller strips it
            ?assertEqual(#{<<"id">> => <<"t 1?ignored">>}, Bindings)
        end)
    ].

%%--------------------------------------------------------------------
%% path_for and query_for
%%--------------------------------------------------------------------

path_for_test_() ->
    Ref = #{<<"taskId">> => <<"t1">>, <<"id">> => <<"c1">>},
    [
        ?_assertEqual(
            {<<"POST">>, <<"/a2a/v1/message:send">>},
            barrel_a2a_rest:path_for(send_message, ?BASE, #{})
        ),
        ?_assertEqual(
            {<<"POST">>, <<"/a2a/v1/message:stream">>},
            barrel_a2a_rest:path_for(send_streaming_message, ?BASE, #{})
        ),
        ?_assertEqual(
            {<<"GET">>, <<"/a2a/v1/tasks/t1">>},
            barrel_a2a_rest:path_for(get_task, ?BASE, #{<<"id">> => <<"t1">>})
        ),
        ?_assertEqual(
            {<<"GET">>, <<"/a2a/v1/tasks">>}, barrel_a2a_rest:path_for(list_tasks, ?BASE, #{})
        ),
        ?_assertEqual(
            {<<"POST">>, <<"/a2a/v1/tasks/t1:cancel">>},
            barrel_a2a_rest:path_for(cancel_task, ?BASE, #{<<"id">> => <<"t1">>})
        ),
        ?_assertEqual(
            {<<"POST">>, <<"/a2a/v1/tasks/t1:subscribe">>},
            barrel_a2a_rest:path_for(subscribe_to_task, ?BASE, #{<<"id">> => <<"t1">>})
        ),
        ?_assertEqual(
            {<<"POST">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs">>},
            barrel_a2a_rest:path_for(create_push_config, ?BASE, #{<<"taskId">> => <<"t1">>})
        ),
        ?_assertEqual(
            {<<"GET">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs/c1">>},
            barrel_a2a_rest:path_for(get_push_config, ?BASE, Ref)
        ),
        ?_assertEqual(
            {<<"DELETE">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs/c1">>},
            barrel_a2a_rest:path_for(delete_push_config, ?BASE, Ref)
        ),
        ?_assertEqual(
            {<<"GET">>, <<"/a2a/v1/tasks/t1/pushNotificationConfigs">>},
            barrel_a2a_rest:path_for(list_push_configs, ?BASE, #{<<"taskId">> => <<"t1">>})
        ),
        ?_assertEqual(
            {<<"GET">>, <<"/a2a/v1/extendedAgentCard">>},
            barrel_a2a_rest:path_for(get_extended_agent_card, ?BASE, #{})
        ),
        ?_assertEqual(
            {<<"GET">>, <<"/tasks/t1">>},
            barrel_a2a_rest:path_for(get_task, <<>>, #{<<"id">> => <<"t1">>})
        ),
        %% ids are percent-encoded on the way out and decode back on match
        ?_test(begin
            {Method, Path} = barrel_a2a_rest:path_for(get_task, ?BASE, #{<<"id">> => <<"a b/c">>}),
            ?assertEqual(<<"GET">>, Method),
            ?assertEqual(<<"/a2a/v1/tasks/a%20b%2Fc">>, Path),
            ?assertEqual({ok, get_task, #{<<"id">> => <<"a b/c">>}}, match(Method, Path))
        end),
        %% every route round trips through path_for and match
        [
            {
                atom_to_list(Op),
                ?_test(begin
                    Req = #{<<"id">> => <<"t1">>, <<"taskId">> => <<"t1">>},
                    Req1 =
                        case Op of
                            get_push_config -> Req#{<<"id">> => <<"c1">>};
                            delete_push_config -> Req#{<<"id">> => <<"c1">>};
                            _ -> Req
                        end,
                    {Method, Path} = barrel_a2a_rest:path_for(Op, ?BASE, Req1),
                    ?assertMatch({ok, Op, _}, match(Method, Path))
                end)
            }
         || Op <- ops()
        ]
    ].

query_for_test_() ->
    [
        ?_assertEqual(<<>>, barrel_a2a_rest:query_for(get_task, #{<<"id">> => <<"t1">>})),
        ?_assertEqual(
            <<"historyLength=5">>,
            barrel_a2a_rest:query_for(get_task, #{<<"id">> => <<"t1">>, <<"historyLength">> => 5})
        ),
        ?_assertEqual(<<>>, barrel_a2a_rest:query_for(list_tasks, #{})),
        %% keys sorted, booleans as true/false, integers as text
        ?_assertEqual(
            <<"contextId=c1&historyLength=0&includeArtifacts=true&pageSize=2&status=TASK_STATE_WORKING">>,
            barrel_a2a_rest:query_for(list_tasks, #{
                <<"status">> => <<"TASK_STATE_WORKING">>,
                <<"pageSize">> => 2,
                <<"includeArtifacts">> => true,
                <<"contextId">> => <<"c1">>,
                <<"historyLength">> => 0
            })
        ),
        ?_assertEqual(
            <<"includeArtifacts=false">>,
            barrel_a2a_rest:query_for(list_tasks, #{<<"includeArtifacts">> => false})
        ),
        %% undefined, objects and lists are skipped
        ?_assertEqual(
            <<"pageSize=1">>,
            barrel_a2a_rest:query_for(list_tasks, #{
                <<"pageSize">> => 1,
                <<"pageToken">> => undefined,
                <<"metadata">> => #{<<"a">> => 1},
                <<"tags">> => [1]
            })
        ),
        ?_assertEqual(
            <<>>, barrel_a2a_rest:query_for(list_push_configs, #{<<"taskId">> => <<"t1">>})
        ),
        ?_assertEqual(
            <<"pageSize=3&pageToken=abc">>,
            barrel_a2a_rest:query_for(list_push_configs, #{
                <<"taskId">> => <<"t1">>, <<"pageSize">> => 3, <<"pageToken">> => <<"abc">>
            })
        ),
        ?_assertEqual(<<>>, barrel_a2a_rest:query_for(get_extended_agent_card, #{})),
        %% values are form-encoded
        ?_assertEqual(
            <<"statusTimestampAfter=2024-01-01T00%3A00%3A00Z">>,
            barrel_a2a_rest:query_for(list_tasks, #{
                <<"statusTimestampAfter">> => <<"2024-01-01T00:00:00Z">>
            })
        ),
        %% the query parses back with the typed spec
        ?_test(begin
            Q = barrel_a2a_rest:query_for(list_tasks, #{
                <<"pageSize">> => 7, <<"includeArtifacts">> => true, <<"contextId">> => <<"c">>
            }),
            Pairs = uri_string:dissect_query(Q),
            ?assertEqual(
                #{<<"pageSize">> => 7, <<"includeArtifacts">> => true, <<"contextId">> => <<"c">>},
                barrel_a2a_rest:build_request(list_tasks, #{}, Pairs, undefined)
            )
        end),
        %% for ops without path fields nothing is skipped
        ?_assertEqual(<<"id=t1">>, barrel_a2a_rest:query_for(cancel_task, #{<<"id">> => <<"t1">>}))
    ].
