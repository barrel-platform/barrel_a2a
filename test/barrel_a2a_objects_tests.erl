-module(barrel_a2a_objects_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% part
%%--------------------------------------------------------------------

part_test_() ->
    Bytes = <<0, 1, 2, 255, 254, "binary">>,
    [
        ?_assertEqual(#{<<"text">> => <<"hi">>}, barrel_a2a_part:text(<<"hi">>)),
        ?_assertEqual(#{<<"text">> => <<"a b">>}, barrel_a2a_part:text(["a", <<" ">>, "b"])),
        ?_assertEqual(
            #{
                <<"text">> => <<"x">>,
                <<"mediaType">> => <<"text/markdown">>,
                <<"metadata">> => #{<<"k">> => 1}
            },
            barrel_a2a_part:text(<<"x">>, #{
                media_type => <<"text/markdown">>, metadata => #{<<"k">> => 1}
            })
        ),
        %% unknown option keys are ignored
        ?_assertEqual(#{<<"text">> => <<"x">>}, barrel_a2a_part:text(<<"x">>, #{bogus => 1})),
        ?_assertEqual(
            #{<<"data">> => #{<<"a">> => [1, 2]}}, barrel_a2a_part:data(#{<<"a">> => [1, 2]})
        ),
        ?_assertEqual(
            #{<<"data">> => null, <<"filename">> => <<"f.json">>},
            barrel_a2a_part:data(null, #{filename => <<"f.json">>})
        ),
        ?_assertEqual(
            #{<<"url">> => <<"https://x/y.png">>, <<"mediaType">> => <<"image/png">>},
            barrel_a2a_part:file_url(<<"https://x/y.png">>, <<"image/png">>)
        ),
        ?_assertEqual(
            #{
                <<"url">> => <<"https://x/y.png">>,
                <<"mediaType">> => <<"image/png">>,
                <<"filename">> => <<"y.png">>
            },
            barrel_a2a_part:file_url(<<"https://x/y.png">>, <<"image/png">>, #{
                filename => <<"y.png">>
            })
        ),
        ?_test(begin
            P = barrel_a2a_part:file_bytes(Bytes, <<"application/octet-stream">>),
            ?assertEqual(base64:encode(Bytes), maps:get(<<"raw">>, P)),
            ?assertEqual(<<"application/octet-stream">>, maps:get(<<"mediaType">>, P)),
            ?assertEqual(Bytes, barrel_a2a_part:bytes_of(P)),
            ?assertEqual(raw, barrel_a2a_part:kind(P)),
            %% survives a JSON round trip
            {ok, Decoded} = barrel_a2a_json:decode(barrel_a2a_json:encode(P)),
            ?assertEqual(Bytes, barrel_a2a_part:bytes_of(Decoded))
        end),
        ?_assertEqual(
            <<"b.bin">>,
            barrel_a2a_part:filename(
                barrel_a2a_part:file_bytes(<<1>>, <<"x/y">>, #{filename => <<"b.bin">>})
            )
        ),
        ?_assertEqual(text, barrel_a2a_part:kind(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(data, barrel_a2a_part:kind(barrel_a2a_part:data(1))),
        ?_assertEqual(url, barrel_a2a_part:kind(barrel_a2a_part:file_url(<<"u">>, <<"m">>))),
        ?_assertEqual(unknown, barrel_a2a_part:kind(#{<<"mediaType">> => <<"m">>})),
        ?_assertEqual(unknown, barrel_a2a_part:kind(#{})),
        ?_assertEqual(<<"t">>, barrel_a2a_part:text_of(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(undefined, barrel_a2a_part:text_of(barrel_a2a_part:data(1))),
        ?_assertEqual(undefined, barrel_a2a_part:text_of(#{<<"text">> => 1})),
        ?_assertEqual(
            #{<<"a">> => 1}, barrel_a2a_part:data_of(barrel_a2a_part:data(#{<<"a">> => 1}))
        ),
        ?_assertEqual(undefined, barrel_a2a_part:data_of(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(<<"u">>, barrel_a2a_part:url_of(barrel_a2a_part:file_url(<<"u">>, <<"m">>))),
        ?_assertEqual(undefined, barrel_a2a_part:url_of(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(undefined, barrel_a2a_part:bytes_of(#{<<"raw">> => <<"!!!not base64">>})),
        ?_assertEqual(undefined, barrel_a2a_part:bytes_of(barrel_a2a_part:text(<<"t">>))),
        %% media type defaults
        ?_assertEqual(<<"text/plain">>, barrel_a2a_part:media_type(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(<<"application/json">>, barrel_a2a_part:media_type(barrel_a2a_part:data(1))),
        ?_assertEqual(
            <<"text/markdown">>,
            barrel_a2a_part:media_type(
                barrel_a2a_part:text(<<"t">>, #{media_type => <<"text/markdown">>})
            )
        ),
        ?_assertEqual(
            <<"image/png">>,
            barrel_a2a_part:media_type(barrel_a2a_part:file_url(<<"u">>, <<"image/png">>))
        ),
        ?_assertEqual(undefined, barrel_a2a_part:media_type(#{<<"raw">> => <<"AA==">>})),
        ?_assertEqual(undefined, barrel_a2a_part:filename(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(#{}, barrel_a2a_part:metadata(barrel_a2a_part:text(<<"t">>))),
        ?_assertEqual(
            #{<<"k">> => 1},
            barrel_a2a_part:metadata(barrel_a2a_part:text(<<"t">>, #{metadata => #{<<"k">> => 1}}))
        ),
        ?_assert(barrel_a2a_part:is_part(barrel_a2a_part:text(<<"t">>))),
        ?_assert(barrel_a2a_part:is_part(barrel_a2a_part:data(null))),
        ?_assertNot(barrel_a2a_part:is_part(#{})),
        ?_assertNot(barrel_a2a_part:is_part(<<"text">>)),
        ?_assertNot(barrel_a2a_part:is_part([]))
    ].

%%--------------------------------------------------------------------
%% message
%%--------------------------------------------------------------------

message_test_() ->
    P1 = barrel_a2a_part:text(<<"one">>),
    P2 = barrel_a2a_part:data(#{<<"n">> => 2}),
    P3 = barrel_a2a_part:text(<<"three">>),
    [
        ?_test(begin
            M = barrel_a2a_message:new(<<"hello">>),
            ?assert(barrel_a2a_id:is_uuid(barrel_a2a_message:id(M))),
            ?assertEqual(<<"ROLE_USER">>, maps:get(<<"role">>, M)),
            ?assertEqual(user, barrel_a2a_message:role(M)),
            ?assertEqual([P1#{<<"text">> => <<"hello">>}], barrel_a2a_message:parts(M)),
            ?assertEqual(<<"hello">>, barrel_a2a_message:text(M)),
            ?assertEqual([<<"messageId">>, <<"parts">>, <<"role">>], lists:sort(maps:keys(M)))
        end),
        ?_assertEqual(
            [barrel_a2a_part:text(<<"io list">>)],
            barrel_a2a_message:parts(barrel_a2a_message:new(["io", " ", "list"]))
        ),
        ?_assertEqual([P2], barrel_a2a_message:parts(barrel_a2a_message:new(P2))),
        ?_assertEqual([P1, P2, P3], barrel_a2a_message:parts(barrel_a2a_message:new([P1, P2, P3]))),
        %% a list that is not all parts is text
        ?_assertEqual(
            [barrel_a2a_part:text(<<"ab">>)],
            barrel_a2a_message:parts(barrel_a2a_message:new([$a, $b]))
        ),
        ?_test(begin
            M = barrel_a2a_message:agent(<<"reply">>),
            ?assertEqual(<<"ROLE_AGENT">>, maps:get(<<"role">>, M)),
            ?assertEqual(agent, barrel_a2a_message:role(M))
        end),
        ?_assertEqual(
            agent, barrel_a2a_message:role(barrel_a2a_message:agent(<<"r">>, #{role => user}))
        ),
        ?_assertEqual(
            agent, barrel_a2a_message:role(barrel_a2a_message:new(<<"r">>, #{role => agent}))
        ),
        ?_test(begin
            M = barrel_a2a_message:new([P1, P2, P3], #{
                message_id => <<"m1">>,
                context_id => <<"c1">>,
                task_id => <<"t1">>,
                metadata => #{<<"k">> => <<"v">>},
                extensions => [<<"e1">>],
                reference_task_ids => [<<"t0">>],
                bogus => ignored
            }),
            ?assertEqual(<<"m1">>, barrel_a2a_message:id(M)),
            ?assertEqual(<<"c1">>, barrel_a2a_message:context_id(M)),
            ?assertEqual(<<"t1">>, barrel_a2a_message:task_id(M)),
            ?assertEqual(#{<<"k">> => <<"v">>}, barrel_a2a_message:metadata(M)),
            ?assertEqual([<<"e1">>], barrel_a2a_message:extensions(M)),
            ?assertEqual([<<"t0">>], barrel_a2a_message:reference_task_ids(M)),
            ?assertEqual(<<"one\nthree">>, barrel_a2a_message:text(M)),
            ?assertEqual(
                [
                    <<"contextId">>,
                    <<"extensions">>,
                    <<"messageId">>,
                    <<"metadata">>,
                    <<"parts">>,
                    <<"referenceTaskIds">>,
                    <<"role">>,
                    <<"taskId">>
                ],
                lists:sort(maps:keys(M))
            )
        end),
        ?_assertEqual(<<>>, barrel_a2a_message:text(barrel_a2a_message:new(P2))),
        ?_assertEqual(<<>>, barrel_a2a_message:text(#{})),
        %% accessors on missing or malformed fields
        ?_assertEqual(undefined, barrel_a2a_message:id(#{})),
        ?_assertEqual(undefined, barrel_a2a_message:id(#{<<"messageId">> => 1})),
        ?_assertEqual(unspecified, barrel_a2a_message:role(#{})),
        ?_assertEqual(unspecified, barrel_a2a_message:role(#{<<"role">> => <<"ROLE_NOPE">>})),
        ?_assertEqual([], barrel_a2a_message:parts(#{})),
        ?_assertEqual([], barrel_a2a_message:parts(#{<<"parts">> => <<"x">>})),
        ?_assertEqual(undefined, barrel_a2a_message:context_id(#{<<"contextId">> => <<>>})),
        ?_assertEqual(undefined, barrel_a2a_message:task_id(#{<<"taskId">> => <<>>})),
        ?_assertEqual(#{}, barrel_a2a_message:metadata(#{<<"metadata">> => [1]})),
        ?_assertEqual(
            [<<"a">>], barrel_a2a_message:extensions(#{<<"extensions">> => [<<"a">>, 1]})
        ),
        ?_assertEqual([], barrel_a2a_message:extensions(#{})),
        ?_assertEqual(
            [<<"a">>],
            barrel_a2a_message:reference_task_ids(#{<<"referenceTaskIds">> => [1, <<"a">>]})
        ),
        %% setters
        ?_test(begin
            M0 = barrel_a2a_message:new(<<"x">>),
            M1 = barrel_a2a_message:with_context(<<"c">>, M0),
            M2 = barrel_a2a_message:with_task(<<"t">>, M1),
            M3 = barrel_a2a_message:with_metadata(#{<<"m">> => 1}, M2),
            M4 = barrel_a2a_message:with_extensions([<<"e">>], M3),
            M5 = barrel_a2a_message:with_id(<<"id">>, M4),
            ?assertEqual(<<"c">>, barrel_a2a_message:context_id(M5)),
            ?assertEqual(<<"t">>, barrel_a2a_message:task_id(M5)),
            ?assertEqual(#{<<"m">> => 1}, barrel_a2a_message:metadata(M5)),
            ?assertEqual([<<"e">>], barrel_a2a_message:extensions(M5)),
            ?assertEqual(<<"id">>, barrel_a2a_message:id(M5)),
            ?assertEqual(barrel_a2a_message:parts(M0), barrel_a2a_message:parts(M5))
        end),
        %% role wire round trip
        [
            ?_test(begin
                W = barrel_a2a_message:role_to_wire(R),
                ?assertEqual({ok, R}, barrel_a2a_message:role_from_wire(W))
            end)
         || R <- [user, agent, unspecified]
        ],
        ?_assertEqual(<<"ROLE_USER">>, barrel_a2a_message:role_to_wire(user)),
        ?_assertEqual(<<"ROLE_AGENT">>, barrel_a2a_message:role_to_wire(agent)),
        ?_assertEqual(<<"ROLE_UNSPECIFIED">>, barrel_a2a_message:role_to_wire(unspecified)),
        ?_assertEqual({ok, unspecified}, barrel_a2a_message:role_from_wire(0)),
        ?_assertEqual({ok, user}, barrel_a2a_message:role_from_wire(1)),
        ?_assertEqual({ok, agent}, barrel_a2a_message:role_from_wire(2)),
        ?_assertEqual({ok, user}, barrel_a2a_message:role_from_wire(user)),
        ?_assertEqual({ok, agent}, barrel_a2a_message:role_from_wire(agent)),
        ?_assertEqual(error, barrel_a2a_message:role_from_wire(3)),
        ?_assertEqual(error, barrel_a2a_message:role_from_wire(<<"user">>)),
        ?_assertEqual(error, barrel_a2a_message:role_from_wire(unspecified)),
        ?_assertEqual(error, barrel_a2a_message:role_from_wire(null))
    ].

%%--------------------------------------------------------------------
%% artifact
%%--------------------------------------------------------------------

artifact_test_() ->
    P1 = barrel_a2a_part:text(<<"one">>),
    P2 = barrel_a2a_part:data(1),
    [
        ?_test(begin
            A = barrel_a2a_artifact:new(<<"out">>),
            ?assert(barrel_a2a_id:is_uuid(barrel_a2a_artifact:id(A))),
            ?assertEqual([barrel_a2a_part:text(<<"out">>)], barrel_a2a_artifact:parts(A)),
            ?assertEqual([<<"artifactId">>, <<"parts">>], lists:sort(maps:keys(A))),
            ?assertEqual(undefined, barrel_a2a_artifact:name(A)),
            ?assertEqual(undefined, barrel_a2a_artifact:description(A)),
            ?assertEqual(#{}, barrel_a2a_artifact:metadata(A)),
            ?assertEqual([], barrel_a2a_artifact:extensions(A))
        end),
        ?_test(begin
            A = barrel_a2a_artifact:new([P1, P2], #{
                artifact_id => <<"a1">>,
                name => <<"n">>,
                description => <<"d">>,
                metadata => #{<<"m">> => 1},
                extensions => [<<"e">>],
                bogus => 1
            }),
            ?assertEqual(<<"a1">>, barrel_a2a_artifact:id(A)),
            ?assertEqual(<<"n">>, barrel_a2a_artifact:name(A)),
            ?assertEqual(<<"d">>, barrel_a2a_artifact:description(A)),
            ?assertEqual(#{<<"m">> => 1}, barrel_a2a_artifact:metadata(A)),
            ?assertEqual([<<"e">>], barrel_a2a_artifact:extensions(A)),
            ?assertEqual([P1, P2], barrel_a2a_artifact:parts(A)),
            ?assertNot(maps:is_key(<<"bogus">>, A))
        end),
        ?_assertEqual([P2], barrel_a2a_artifact:parts(barrel_a2a_artifact:new(P2))),
        ?_assertEqual(
            [barrel_a2a_part:text(<<"ab">>)],
            barrel_a2a_artifact:parts(barrel_a2a_artifact:new("ab"))
        ),
        %% text/1 concatenates without separator
        ?_assertEqual(
            <<"onetwo">>,
            barrel_a2a_artifact:text(
                barrel_a2a_artifact:new([P1, P2, barrel_a2a_part:text(<<"two">>)])
            )
        ),
        ?_assertEqual(<<>>, barrel_a2a_artifact:text(barrel_a2a_artifact:new(P2))),
        ?_assertEqual(<<>>, barrel_a2a_artifact:text(#{})),
        ?_assertEqual(undefined, barrel_a2a_artifact:id(#{})),
        ?_assertEqual([], barrel_a2a_artifact:parts(#{<<"parts">> => 1})),
        ?_test(begin
            Existing = barrel_a2a_artifact:new([P1], #{artifact_id => <<"a">>, name => <<"old">>}),
            Chunk = barrel_a2a_artifact:new([P2], #{
                artifact_id => <<"a">>, description => <<"more">>
            }),
            Merged = barrel_a2a_artifact:append_parts(Existing, Chunk),
            ?assertEqual([P1, P2], barrel_a2a_artifact:parts(Merged)),
            ?assertEqual(<<"a">>, barrel_a2a_artifact:id(Merged)),
            ?assertEqual(<<"old">>, barrel_a2a_artifact:name(Merged)),
            ?assertEqual(<<"more">>, barrel_a2a_artifact:description(Merged))
        end),
        %% chunk fields override existing ones
        ?_assertEqual(
            <<"new">>,
            barrel_a2a_artifact:name(
                barrel_a2a_artifact:append_parts(
                    barrel_a2a_artifact:new(P1, #{artifact_id => <<"a">>, name => <<"old">>}),
                    barrel_a2a_artifact:new(P2, #{artifact_id => <<"a">>, name => <<"new">>})
                )
            )
        ),
        ?_assertEqual(
            [P1],
            barrel_a2a_artifact:parts(barrel_a2a_artifact:append_parts(#{<<"parts">> => [P1]}, #{}))
        )
    ].

%%--------------------------------------------------------------------
%% task
%%--------------------------------------------------------------------

msg(Text) -> barrel_a2a_message:new(Text, #{message_id => Text}).

task_test_() ->
    M1 = msg(<<"m1">>),
    M2 = msg(<<"m2">>),
    M3 = msg(<<"m3">>),
    A1 = barrel_a2a_artifact:new(<<"a1">>, #{artifact_id => <<"a">>}),
    A1b = barrel_a2a_artifact:new(<<"a1b">>, #{artifact_id => <<"a">>}),
    B1 = barrel_a2a_artifact:new(<<"b1">>, #{artifact_id => <<"b">>}),
    [
        ?_test(begin
            T = barrel_a2a_task:new(<<"t1">>, <<"c1">>),
            ?assertEqual(<<"t1">>, barrel_a2a_task:id(T)),
            ?assertEqual(<<"c1">>, barrel_a2a_task:context_id(T)),
            ?assertEqual(submitted, barrel_a2a_task:state(T)),
            ?assertEqual(
                <<"TASK_STATE_SUBMITTED">>, maps:get(<<"state">>, barrel_a2a_task:status(T))
            ),
            ?assert(barrel_a2a_time:is_iso(barrel_a2a_task:status_timestamp(T))),
            ?assertEqual(undefined, barrel_a2a_task:status_message(T)),
            ?assertEqual([], barrel_a2a_task:artifacts(T)),
            ?assertEqual([], barrel_a2a_task:history(T)),
            ?assertEqual(#{}, barrel_a2a_task:metadata(T)),
            ?assertNot(maps:is_key(<<"metadata">>, T)),
            ?assertNot(barrel_a2a_task:is_terminal(T)),
            ?assertNot(barrel_a2a_task:is_interrupted(T))
        end),
        ?_test(begin
            T = barrel_a2a_task:new(<<"t1">>, <<"c1">>, #{
                metadata => #{<<"k">> => 1}, history => [M1]
            }),
            ?assertEqual(#{<<"k">> => 1}, barrel_a2a_task:metadata(T)),
            ?assertEqual([M1], barrel_a2a_task:history(T))
        end),
        ?_assertNot(
            maps:is_key(
                <<"metadata">>, barrel_a2a_task:new(<<"t">>, <<"c">>, #{metadata => undefined})
            )
        ),
        ?_test(begin
            T0 = barrel_a2a_task:new(<<"t1">>, <<"c1">>),
            T1 = barrel_a2a_task:set_status(T0, working, undefined),
            ?assertEqual(working, barrel_a2a_task:state(T1)),
            ?assertEqual(undefined, barrel_a2a_task:status_message(T1)),
            ?assertNot(maps:is_key(<<"message">>, barrel_a2a_task:status(T1))),
            T2 = barrel_a2a_task:set_status(T1, completed, M1, <<"2024-01-01T00:00:00.000Z">>),
            ?assertEqual(completed, barrel_a2a_task:state(T2)),
            ?assertEqual(M1, barrel_a2a_task:status_message(T2)),
            ?assertEqual(<<"2024-01-01T00:00:00.000Z">>, barrel_a2a_task:status_timestamp(T2)),
            ?assert(barrel_a2a_task:is_terminal(T2)),
            ?assertNot(barrel_a2a_task:is_interrupted(T2)),
            T3 = barrel_a2a_task:set_status(T0, input_required, undefined),
            ?assert(barrel_a2a_task:is_interrupted(T3)),
            ?assertNot(barrel_a2a_task:is_terminal(T3))
        end),
        ?_assertEqual(
            #{<<"state">> => <<"TASK_STATE_FAILED">>, <<"timestamp">> => <<"ts">>},
            barrel_a2a_task:status_object(failed, undefined, <<"ts">>)
        ),
        ?_assertEqual(
            #{
                <<"state">> => <<"TASK_STATE_WORKING">>,
                <<"message">> => M1,
                <<"timestamp">> => <<"ts">>
            },
            barrel_a2a_task:status_object(working, M1, <<"ts">>)
        ),
        ?_test(begin
            T0 = barrel_a2a_task:new(<<"t1">>, <<"c1">>),
            T1 = barrel_a2a_task:add_history(barrel_a2a_task:add_history(T0, M1), M2),
            ?assertEqual([M1, M2], barrel_a2a_task:history(T1))
        end),
        ?_assertEqual([M1], barrel_a2a_task:history(barrel_a2a_task:add_history(#{}, M1))),
        %% put_artifact: new, replace, append
        ?_test(begin
            T0 = barrel_a2a_task:new(<<"t1">>, <<"c1">>),
            T1 = barrel_a2a_task:put_artifact(T0, A1, false),
            ?assertEqual([A1], barrel_a2a_task:artifacts(T1)),
            T2 = barrel_a2a_task:put_artifact(T1, B1, false),
            ?assertEqual([A1, B1], barrel_a2a_task:artifacts(T2)),
            %% replace keeps position
            T3 = barrel_a2a_task:put_artifact(T2, A1b, false),
            ?assertEqual([A1b, B1], barrel_a2a_task:artifacts(T3)),
            %% append merges parts, keeps position
            T4 = barrel_a2a_task:put_artifact(T2, A1b, true),
            [Merged, B1] = barrel_a2a_task:artifacts(T4),
            ?assertEqual(<<"a">>, barrel_a2a_artifact:id(Merged)),
            ?assertEqual(
                [barrel_a2a_part:text(<<"a1">>), barrel_a2a_part:text(<<"a1b">>)],
                barrel_a2a_artifact:parts(Merged)
            ),
            %% append with no existing artifact simply adds it
            T5 = barrel_a2a_task:put_artifact(T0, A1, true),
            ?assertEqual([A1], barrel_a2a_task:artifacts(T5))
        end),
        %% history length
        ?_test(begin
            T = barrel_a2a_task:new(<<"t1">>, <<"c1">>, #{history => [M1, M2, M3]}),
            ?assertEqual(T, barrel_a2a_task:with_history_length(T, undefined)),
            ?assertNot(maps:is_key(<<"history">>, barrel_a2a_task:with_history_length(T, 0))),
            ?assertEqual([M3], barrel_a2a_task:history(barrel_a2a_task:with_history_length(T, 1))),
            ?assertEqual(
                [M2, M3], barrel_a2a_task:history(barrel_a2a_task:with_history_length(T, 2))
            ),
            ?assertEqual(
                [M1, M2, M3], barrel_a2a_task:history(barrel_a2a_task:with_history_length(T, 3))
            ),
            ?assertEqual(
                [M1, M2, M3], barrel_a2a_task:history(barrel_a2a_task:with_history_length(T, 10))
            )
        end),
        ?_test(begin
            T = barrel_a2a_task:put_artifact(barrel_a2a_task:new(<<"t">>, <<"c">>), A1, false),
            T1 = barrel_a2a_task:without_artifacts(T),
            ?assertNot(maps:is_key(<<"artifacts">>, T1)),
            ?assertEqual([], barrel_a2a_task:artifacts(T1)),
            ?assertEqual(<<"t">>, barrel_a2a_task:id(T1))
        end),
        %% accessors on malformed input
        ?_assertEqual(undefined, barrel_a2a_task:id(#{})),
        ?_assertEqual(undefined, barrel_a2a_task:context_id(#{<<"contextId">> => <<>>})),
        ?_assertEqual(#{}, barrel_a2a_task:status(#{<<"status">> => 1})),
        ?_assertEqual(unspecified, barrel_a2a_task:state(#{})),
        ?_assertEqual(
            unspecified, barrel_a2a_task:state(#{<<"status">> => #{<<"state">> => <<"nope">>}})
        ),
        ?_assertEqual(working, barrel_a2a_task:state(#{<<"status">> => #{<<"state">> => 2}})),
        ?_assertEqual(undefined, barrel_a2a_task:status_timestamp(#{})),
        ?_assertEqual(
            undefined, barrel_a2a_task:status_message(#{<<"status">> => #{<<"message">> => 1}})
        ),
        ?_assertNot(barrel_a2a_task:is_terminal(#{}))
    ].

%%--------------------------------------------------------------------
%% event
%%--------------------------------------------------------------------

status(State) -> barrel_a2a_task:status_object(State, undefined, <<"ts">>).

event_test_() ->
    Task = barrel_a2a_task:new(<<"t1">>, <<"c1">>),
    Done = barrel_a2a_task:set_status(Task, completed, undefined),
    Msg = barrel_a2a_message:agent(<<"hi">>, #{task_id => <<"t1">>, context_id => <<"c1">>}),
    Art = barrel_a2a_artifact:new(<<"a">>, #{artifact_id => <<"a1">>}),
    [
        ?_assertEqual(#{<<"task">> => Task}, barrel_a2a_event:task(Task)),
        ?_assertEqual(#{<<"message">> => Msg}, barrel_a2a_event:message(Msg)),
        ?_assertEqual(
            #{
                <<"statusUpdate">> => #{
                    <<"taskId">> => <<"t1">>,
                    <<"contextId">> => <<"c1">>,
                    <<"status">> => status(working)
                }
            },
            barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working))
        ),
        ?_assertEqual(
            #{
                <<"statusUpdate">> => #{
                    <<"taskId">> => <<"t1">>,
                    <<"contextId">> => <<"c1">>,
                    <<"status">> => status(working),
                    <<"metadata">> => #{<<"m">> => 1}
                }
            },
            barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working), #{<<"m">> => 1})
        ),
        %% empty metadata is omitted
        ?_assertEqual(
            barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working)),
            barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working), #{})
        ),
        ?_assertEqual(
            #{
                <<"artifactUpdate">> => #{
                    <<"taskId">> => <<"t1">>,
                    <<"contextId">> => <<"c1">>,
                    <<"artifact">> => Art,
                    <<"append">> => false,
                    <<"lastChunk">> => false
                }
            },
            barrel_a2a_event:artifact_update(<<"t1">>, <<"c1">>, Art, #{})
        ),
        ?_assertMatch(
            #{
                <<"artifactUpdate">> := #{
                    <<"append">> := true, <<"lastChunk">> := true, <<"metadata">> := #{<<"m">> := 1}
                }
            },
            barrel_a2a_event:artifact_update(
                <<"t1">>, <<"c1">>, Art, #{append => true, last_chunk => true}, #{<<"m">> => 1}
            )
        ),
        ?_assertEqual(task, barrel_a2a_event:kind(barrel_a2a_event:task(Task))),
        ?_assertEqual(message, barrel_a2a_event:kind(barrel_a2a_event:message(Msg))),
        ?_assertEqual(
            status_update,
            barrel_a2a_event:kind(
                barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working))
            )
        ),
        ?_assertEqual(
            artifact_update,
            barrel_a2a_event:kind(barrel_a2a_event:artifact_update(<<"t1">>, <<"c1">>, Art, #{}))
        ),
        ?_assertEqual(unknown, barrel_a2a_event:kind(#{})),
        ?_assertEqual(Task, barrel_a2a_event:payload(barrel_a2a_event:task(Task))),
        ?_assertEqual(Msg, barrel_a2a_event:payload(barrel_a2a_event:message(Msg))),
        ?_assertMatch(
            #{<<"status">> := _},
            barrel_a2a_event:payload(
                barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working))
            )
        ),
        ?_assertMatch(
            #{<<"artifact">> := Art},
            barrel_a2a_event:payload(barrel_a2a_event:artifact_update(<<"t1">>, <<"c1">>, Art, #{}))
        ),
        ?_assertEqual(undefined, barrel_a2a_event:payload(#{})),
        [
            ?_assertEqual({<<"t1">>, <<"c1">>}, {
                barrel_a2a_event:task_id(Ev), barrel_a2a_event:context_id(Ev)
            })
         || Ev <- [
                barrel_a2a_event:task(Task),
                barrel_a2a_event:message(Msg),
                barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(working)),
                barrel_a2a_event:artifact_update(<<"t1">>, <<"c1">>, Art, #{})
            ]
        ],
        ?_assertEqual(undefined, barrel_a2a_event:task_id(#{})),
        ?_assertEqual(undefined, barrel_a2a_event:context_id(#{})),
        ?_assertEqual(
            undefined,
            barrel_a2a_event:task_id(barrel_a2a_event:message(barrel_a2a_message:new(<<"x">>)))
        ),
        %% is_final
        ?_assert(barrel_a2a_event:is_final(barrel_a2a_event:message(Msg))),
        ?_assertNot(barrel_a2a_event:is_final(barrel_a2a_event:task(Task))),
        ?_assert(barrel_a2a_event:is_final(barrel_a2a_event:task(Done))),
        [
            ?_assertEqual(
                {S, barrel_a2a_task_state:is_terminal(S)},
                {S,
                    barrel_a2a_event:is_final(
                        barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, status(S))
                    )}
            )
         || S <- barrel_a2a_task_state:states()
        ],
        ?_assertNot(
            barrel_a2a_event:is_final(
                barrel_a2a_event:status_update(<<"t1">>, <<"c1">>, #{<<"state">> => <<"nope">>})
            )
        ),
        ?_assertNot(
            barrel_a2a_event:is_final(
                barrel_a2a_event:artifact_update(<<"t1">>, <<"c1">>, Art, #{last_chunk => true})
            )
        ),
        ?_assertNot(barrel_a2a_event:is_final(#{}))
    ].

%%--------------------------------------------------------------------
%% agent card
%%--------------------------------------------------------------------

-define(JSONRPC, <<"JSONRPC">>).
-define(REST, <<"HTTP+JSON">>).
-define(GRPC, <<"GRPC">>).

iface(Url, Binding) -> barrel_a2a_agent_card:interface(Url, Binding, <<"1.0">>).

full_card() ->
    barrel_a2a_agent_card:new(#{
        name => <<"Bot">>,
        description => <<"desc">>,
        version => <<"2.0.0">>,
        supported_interfaces => [
            #{url => <<"grpc://x">>, protocol_binding => ?GRPC, protocol_version => <<"1.0">>},
            #{
                url => <<"https://x/rpc">>,
                protocol_binding => ?JSONRPC,
                protocol_version => <<"1.0">>,
                tenant => <<"acme">>
            },
            #{
                <<"url">> => <<"https://x/rest">>,
                <<"protocolBinding">> => ?REST,
                <<"protocolVersion">> => <<"1.0">>
            }
        ],
        capabilities => #{
            streaming => true,
            push_notifications => false,
            extended_agent_card => true,
            extensions => [
                #{<<"uri">> => <<"ext:a">>, <<"required">> => true},
                #{<<"uri">> => <<"ext:b">>, <<"required">> => false},
                #{<<"uri">> => <<"ext:c">>}
            ]
        },
        skills => [
            #{id => <<"s1">>, name => <<"Skill">>},
            #{
                <<"id">> => <<"s2">>,
                <<"name">> => <<"Two">>,
                <<"tags">> => [<<"t">>],
                <<"description">> => <<"d">>
            }
        ],
        default_input_modes => [<<"text/plain">>, <<"application/json">>],
        security_schemes => #{
            <<"bearer">> => barrel_a2a_agent_card:security_scheme(http, #{scheme => <<"bearer">>})
        },
        security_requirements => [#{<<"bearer">> => []}],
        signatures => [#{<<"protected">> => <<"x">>, <<"signature">> => <<"y">>}]
    }).

agent_card_new_test_() ->
    [
        ?_test(begin
            C = barrel_a2a_agent_card:new(#{name => <<"Min">>}),
            ?assertEqual(<<"Min">>, barrel_a2a_agent_card:name(C)),
            ?assertEqual(<<>>, barrel_a2a_agent_card:description(C)),
            ?assertEqual(<<"0.1.0">>, barrel_a2a_agent_card:version(C)),
            ?assertEqual([], barrel_a2a_agent_card:skills(C)),
            ?assertEqual([], barrel_a2a_agent_card:interfaces(C)),
            ?assertEqual(#{}, barrel_a2a_agent_card:capabilities(C)),
            ?assertEqual([<<"text/plain">>], barrel_a2a_agent_card:default_input_modes(C)),
            ?assertEqual([<<"text/plain">>], barrel_a2a_agent_card:default_output_modes(C)),
            ?assertEqual(
                [
                    <<"capabilities">>,
                    <<"defaultInputModes">>,
                    <<"defaultOutputModes">>,
                    <<"description">>,
                    <<"name">>,
                    <<"skills">>,
                    <<"supportedInterfaces">>,
                    <<"version">>
                ],
                lists:sort(maps:keys(C))
            ),
            ?assertEqual(
                ok,
                barrel_a2a_validate:agent_card(C#{
                    <<"supportedInterfaces">> => [iface(<<"u">>, ?JSONRPC)]
                })
            )
        end),
        ?_test(begin
            C = full_card(),
            ?assertEqual(ok, barrel_a2a_validate:agent_card(C)),
            ?assertEqual(<<"desc">>, barrel_a2a_agent_card:description(C)),
            ?assertEqual(<<"2.0.0">>, barrel_a2a_agent_card:version(C)),
            %% atom keys became camelCase wire keys, binary keys were kept
            ?assertEqual(
                [
                    #{
                        <<"url">> => <<"grpc://x">>,
                        <<"protocolBinding">> => ?GRPC,
                        <<"protocolVersion">> => <<"1.0">>
                    },
                    #{
                        <<"url">> => <<"https://x/rpc">>,
                        <<"protocolBinding">> => ?JSONRPC,
                        <<"protocolVersion">> => <<"1.0">>,
                        <<"tenant">> => <<"acme">>
                    },
                    #{
                        <<"url">> => <<"https://x/rest">>,
                        <<"protocolBinding">> => ?REST,
                        <<"protocolVersion">> => <<"1.0">>
                    }
                ],
                barrel_a2a_agent_card:interfaces(C)
            ),
            ?assertMatch(
                #{
                    <<"streaming">> := true,
                    <<"pushNotifications">> := false,
                    <<"extendedAgentCard">> := true
                },
                barrel_a2a_agent_card:capabilities(C)
            ),
            ?assertEqual(
                [<<"text/plain">>, <<"application/json">>],
                barrel_a2a_agent_card:default_input_modes(C)
            ),
            ?assertEqual([<<"text/plain">>], barrel_a2a_agent_card:default_output_modes(C)),
            ?assertMatch(
                #{<<"bearer">> := #{<<"httpAuthSecurityScheme">> := _}},
                barrel_a2a_agent_card:security_schemes(C)
            ),
            ?assertEqual([#{<<"bearer">> => []}], barrel_a2a_agent_card:security_requirements(C)),
            ?assertMatch([#{<<"protected">> := <<"x">>}], barrel_a2a_agent_card:signatures(C))
        end),
        %% skills get description and tags defaults, keys normalized
        ?_test(begin
            C = full_card(),
            ?assertEqual(
                [
                    #{
                        <<"id">> => <<"s1">>,
                        <<"name">> => <<"Skill">>,
                        <<"description">> => <<>>,
                        <<"tags">> => []
                    },
                    #{
                        <<"id">> => <<"s2">>,
                        <<"name">> => <<"Two">>,
                        <<"description">> => <<"d">>,
                        <<"tags">> => [<<"t">>]
                    }
                ],
                barrel_a2a_agent_card:skills(C)
            ),
            ?assertMatch(#{<<"name">> := <<"Two">>}, barrel_a2a_agent_card:skill(C, <<"s2">>)),
            ?assertEqual(undefined, barrel_a2a_agent_card:skill(C, <<"nope">>))
        end),
        ?_assertEqual(
            #{
                <<"id">> => <<"x">>,
                <<"inputModes">> => [<<"a">>],
                <<"description">> => <<>>,
                <<"tags">> => []
            },
            barrel_a2a_agent_card:skill(#{id => <<"x">>, input_modes => [<<"a">>]})
        ),
        %% wire-keyed input is accepted as is
        ?_test(begin
            C = barrel_a2a_agent_card:new(#{<<"name">> => <<"W">>, <<"version">> => <<"9">>}),
            ?assertEqual(<<"W">>, barrel_a2a_agent_card:name(C)),
            ?assertEqual(<<"9">>, barrel_a2a_agent_card:version(C))
        end),
        %% supports and extensions
        ?_assert(barrel_a2a_agent_card:supports(full_card(), streaming)),
        ?_assertNot(barrel_a2a_agent_card:supports(full_card(), push_notifications)),
        ?_assert(barrel_a2a_agent_card:supports(full_card(), extended_agent_card)),
        ?_assertNot(
            barrel_a2a_agent_card:supports(barrel_a2a_agent_card:new(#{name => <<"x">>}), streaming)
        ),
        ?_assertNot(
            barrel_a2a_agent_card:supports(
                #{<<"capabilities">> => #{<<"streaming">> => <<"true">>}}, streaming
            )
        ),
        ?_assertEqual(3, length(barrel_a2a_agent_card:extensions(full_card()))),
        ?_assertEqual(
            [],
            barrel_a2a_agent_card:extensions(#{<<"capabilities">> => #{<<"extensions">> => <<"x">>}})
        ),
        ?_assertEqual([<<"ext:a">>], barrel_a2a_agent_card:required_extensions(full_card())),
        ?_assertEqual([], barrel_a2a_agent_card:required_extensions(#{})),
        %% accessors on malformed cards
        ?_assertEqual(<<>>, barrel_a2a_agent_card:name(#{<<"name">> => 1})),
        ?_assertEqual([], barrel_a2a_agent_card:skills(#{<<"skills">> => 1})),
        ?_assertEqual([], barrel_a2a_agent_card:interfaces(#{})),
        ?_assertEqual(#{}, barrel_a2a_agent_card:security_schemes(#{})),
        ?_assertEqual([], barrel_a2a_agent_card:security_requirements(#{})),
        ?_assertEqual([], barrel_a2a_agent_card:signatures(#{})),
        ?_assertEqual([], barrel_a2a_agent_card:default_input_modes(#{})),
        ?_assertEqual([], barrel_a2a_agent_card:default_output_modes(#{}))
    ].

interface_test_() ->
    [
        ?_assertEqual(
            #{
                <<"url">> => <<"u">>,
                <<"protocolBinding">> => ?JSONRPC,
                <<"protocolVersion">> => <<"1.0">>
            },
            barrel_a2a_agent_card:interface(<<"u">>, ?JSONRPC, <<"1.0">>)
        ),
        ?_assertEqual(
            barrel_a2a_agent_card:interface(<<"u">>, ?JSONRPC, <<"1.0">>),
            barrel_a2a_agent_card:interface(<<"u">>, ?JSONRPC, <<"1.0">>, undefined)
        ),
        ?_assertEqual(
            #{
                <<"url">> => <<"u">>,
                <<"protocolBinding">> => ?REST,
                <<"protocolVersion">> => <<"1.0">>,
                <<"tenant">> => <<"t">>
            },
            barrel_a2a_agent_card:interface(<<"u">>, ?REST, <<"1.0">>, <<"t">>)
        ),
        ?_test(begin
            C = barrel_a2a_agent_card:with_interfaces([iface(<<"a">>, ?GRPC)], full_card()),
            ?assertEqual([iface(<<"a">>, ?GRPC)], barrel_a2a_agent_card:interfaces(C))
        end)
    ].

select_interface_test_() ->
    C = full_card(),
    Grpc = iface(<<"grpc://x">>, ?GRPC),
    Rpc = barrel_a2a_agent_card:interface(<<"https://x/rpc">>, ?JSONRPC, <<"1.0">>, <<"acme">>),
    Rest = iface(<<"https://x/rest">>, ?REST),
    [
        %% card order decides among supported bindings
        ?_assertEqual(
            {ok, Grpc}, barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?REST, ?GRPC])
        ),
        ?_assertEqual({ok, Rpc}, barrel_a2a_agent_card:select_interface(C, [?REST, ?JSONRPC])),
        ?_assertEqual({ok, Rest}, barrel_a2a_agent_card:select_interface(C, [?REST])),
        ?_assertEqual(error, barrel_a2a_agent_card:select_interface(C, [<<"custom://x">>])),
        ?_assertEqual(error, barrel_a2a_agent_card:select_interface(C, [])),
        ?_assertEqual(
            error,
            barrel_a2a_agent_card:select_interface(barrel_a2a_agent_card:new(#{name => <<"n">>}), [
                ?JSONRPC
            ])
        ),
        %% preference wins over card order
        ?_assertEqual(
            {ok, Rest}, barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?REST, ?GRPC], [?REST])
        ),
        ?_assertEqual(
            {ok, Rpc},
            barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?REST, ?GRPC], [?JSONRPC, ?REST])
        ),
        ?_assertEqual(
            {ok, Rest},
            barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?REST, ?GRPC], [?REST, ?JSONRPC])
        ),
        %% a preferred binding the caller does not support is ignored
        ?_assertEqual(
            {ok, Rpc}, barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?REST], [?GRPC])
        ),
        %% a preferred binding the card lacks falls back to card order
        ?_assertEqual(
            {ok, Grpc},
            barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?GRPC], [<<"custom://x">>])
        ),
        ?_assertEqual(
            {ok, Grpc}, barrel_a2a_agent_card:select_interface(C, [?JSONRPC, ?REST, ?GRPC], [])
        ),
        %% interfaces without a url are skipped
        ?_test(begin
            C2 = barrel_a2a_agent_card:with_interfaces(
                [#{<<"protocolBinding">> => ?JSONRPC, <<"protocolVersion">> => <<"1.0">>}, Rest], C
            ),
            ?assertEqual({ok, Rest}, barrel_a2a_agent_card:select_interface(C2, [?JSONRPC, ?REST])),
            ?assertEqual(error, barrel_a2a_agent_card:select_interface(C2, [?JSONRPC]))
        end)
    ].

security_scheme_test_() ->
    [
        ?_assertEqual(
            #{
                <<"apiKeySecurityScheme">> => #{
                    <<"location">> => <<"header">>, <<"name">> => <<"X-Key">>
                }
            },
            barrel_a2a_agent_card:security_scheme(api_key, #{
                location => header, name => <<"X-Key">>
            })
        ),
        ?_assertEqual(
            #{
                <<"apiKeySecurityScheme">> => #{
                    <<"location">> => <<"query">>,
                    <<"name">> => <<"k">>,
                    <<"description">> => <<"d">>
                }
            },
            barrel_a2a_agent_card:security_scheme(api_key, #{
                location => <<"query">>, name => <<"k">>, description => <<"d">>
            })
        ),
        ?_assertEqual(
            #{<<"httpAuthSecurityScheme">> => #{<<"scheme">> => <<"bearer">>}},
            barrel_a2a_agent_card:security_scheme(http, #{scheme => <<"bearer">>})
        ),
        ?_assertEqual(
            #{
                <<"httpAuthSecurityScheme">> => #{
                    <<"scheme">> => <<"bearer">>,
                    <<"bearerFormat">> => <<"JWT">>,
                    <<"description">> => <<"d">>
                }
            },
            barrel_a2a_agent_card:security_scheme(http, #{
                scheme => <<"bearer">>, bearer_format => <<"JWT">>, description => <<"d">>
            })
        ),
        ?_assertEqual(
            #{<<"oauth2SecurityScheme">> => #{<<"flows">> => #{<<"clientCredentials">> => #{}}}},
            barrel_a2a_agent_card:security_scheme(oauth2, #{
                flows => #{<<"clientCredentials">> => #{}}
            })
        ),
        ?_assertEqual(
            #{
                <<"oauth2SecurityScheme">> => #{
                    <<"flows">> => #{},
                    <<"oauth2MetadataUrl">> => <<"https://m">>,
                    <<"description">> => <<"d">>
                }
            },
            barrel_a2a_agent_card:security_scheme(oauth2, #{
                flows => #{}, oauth2_metadata_url => <<"https://m">>, description => <<"d">>
            })
        ),
        ?_assertEqual(
            #{<<"openIdConnectSecurityScheme">> => #{<<"openIdConnectUrl">> => <<"https://o">>}},
            barrel_a2a_agent_card:security_scheme(openid_connect, #{
                open_id_connect_url => <<"https://o">>
            })
        ),
        ?_assertEqual(
            #{<<"mtlsSecurityScheme">> => #{}}, barrel_a2a_agent_card:security_scheme(mtls, #{})
        ),
        ?_assertEqual(
            #{<<"mtlsSecurityScheme">> => #{<<"description">> => <<"d">>}},
            barrel_a2a_agent_card:security_scheme(mtls, #{description => <<"d">>})
        )
    ].

etag_test_() ->
    [
        ?_test(begin
            C = full_card(),
            E1 = barrel_a2a_agent_card:etag(C),
            E2 = barrel_a2a_agent_card:etag(C),
            ?assertEqual(E1, E2),
            ?assertEqual(34, byte_size(E1)),
            ?assertMatch(<<$", _:32/binary, $">>, E1),
            <<$", Hex:32/binary, $">> = E1,
            ?assert(
                lists:all(fun(Ch) -> lists:member(Ch, "0123456789abcdef") end, binary_to_list(Hex))
            )
        end),
        ?_test(begin
            C = full_card(),
            ?assertNotEqual(
                barrel_a2a_agent_card:etag(C),
                barrel_a2a_agent_card:etag(C#{<<"version">> => <<"2.0.1">>})
            )
        end),
        %% the same content built with different key orders hashes the same
        ?_assertEqual(
            barrel_a2a_agent_card:etag(
                barrel_a2a_agent_card:new(#{name => <<"a">>, version => <<"1">>})
            ),
            barrel_a2a_agent_card:etag(
                barrel_a2a_agent_card:new(#{version => <<"1">>, name => <<"a">>})
            )
        )
    ].

%% History is stored whole by default, as the reference implementation
%% does: `historyLength' truncates a reply, not the stored task. A
%% server that runs very long tasks can opt into a cap.
add_history_default_is_unbounded_test() ->
    T = lists:foldl(
        fun(N, Acc) -> barrel_a2a_task:add_history(Acc, hmsg(N)) end,
        barrel_a2a_task:new(<<"t">>, <<"c">>),
        lists:seq(1, 50)
    ),
    ?assertEqual(50, length(barrel_a2a_task:history(T))).

add_history_limit_keeps_the_newest_test() ->
    T = lists:foldl(
        fun(N, Acc) -> barrel_a2a_task:add_history(Acc, hmsg(N), 3) end,
        barrel_a2a_task:new(<<"t">>, <<"c">>),
        lists:seq(1, 10)
    ),
    Texts = [barrel_a2a_message:text(M) || M <- barrel_a2a_task:history(T)],
    ?assertEqual([<<"8">>, <<"9">>, <<"10">>], Texts).

%% Below the limit nothing is dropped, and the limit is inclusive.
add_history_limit_is_inclusive_test() ->
    T = lists:foldl(
        fun(N, Acc) -> barrel_a2a_task:add_history(Acc, hmsg(N), 3) end,
        barrel_a2a_task:new(<<"t">>, <<"c">>),
        lists:seq(1, 3)
    ),
    ?assertEqual(3, length(barrel_a2a_task:history(T))).

hmsg(N) -> barrel_a2a_message:new(integer_to_binary(N)).
