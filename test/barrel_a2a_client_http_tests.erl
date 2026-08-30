-module(barrel_a2a_client_http_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TASK, #{
    <<"id">> => <<"t1">>,
    <<"status">> => #{<<"state">> => <<"TASK_STATE_COMPLETED">>}
}).
-define(ETAG, <<"\"card-v1\"">>).

%%--------------------------------------------------------------------
%% Fixture
%%--------------------------------------------------------------------

client_http_test_() ->
    {setup, fun start/0, fun stop/1, fun(Srv) ->
        [
            {timeout, 30,
                {Name, fun() ->
                    attach(),
                    Fun(Srv)
                end}}
         || {Name, Fun} <- [
                {"connect validates url", fun connect_validates_url/1},
                {"jsonrpc call", fun jsonrpc_call/1},
                {"jsonrpc error", fun jsonrpc_error/1},
                {"jsonrpc stream", fun jsonrpc_stream/1},
                {"rest call", fun rest_call/1},
                {"rest error", fun rest_error/1},
                {"rest stream", fun rest_stream/1},
                {"rest direct reply", fun rest_direct_reply/1},
                {"stream error status", fun stream_error_status/1},
                {"stream owner down", fun stream_owner_down/1},
                {"cancel stream", fun cancel_stream/1},
                {"fetch card", fun fetch_card/1},
                {"fetch card etag", fun fetch_card_etag/1},
                {"fetch card error", fun fetch_card_error/1},
                {"call timeout", fun call_timeout/1},
                {"connection refused", fun connection_refused/1}
            ]
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(h1),
    Handler = fun(Conn, Sid, Method, Path, Headers) ->
        handle(test_pid(), Conn, Sid, Method, Path, Headers)
    end,
    {ok, Ref} = h1:start_server(0, #{transport => tcp, handler => Handler}),
    {Ref, h1:server_port(Ref)}.

stop({Ref, _}) ->
    _ = persistent_term:erase({?MODULE, test_pid}),
    h1:stop_server(Ref).

%% Each test runs in its own process; the server reports to the one
%% registered here.
attach() ->
    persistent_term:put({?MODULE, test_pid}, self()).

test_pid() ->
    persistent_term:get({?MODULE, test_pid}, self()).

base({_, Port}) ->
    <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>.

conn(Srv, jsonrpc) ->
    {ok, Conn} = barrel_a2a_client_http:connect(
        #{<<"url">> => <<(base(Srv))/binary, "/rpc">>, <<"protocolBinding">> => <<"JSONRPC">>},
        #{timeout => 5000}
    ),
    Conn;
conn(Srv, rest) ->
    {ok, Conn} = barrel_a2a_client_http:connect(
        #{<<"url">> => <<(base(Srv))/binary, "/rest/">>, <<"protocolBinding">> => <<"HTTP+JSON">>},
        #{timeout => 5000}
    ),
    Conn.

%%--------------------------------------------------------------------
%% Test server
%%--------------------------------------------------------------------

handle(Test, Conn, Sid, Method, Path, Headers) ->
    Lower = [{string:lowercase(K), V} || {K, V} <- Headers],
    Test ! {request, self(), Method, Path, Lower},
    route(Test, Conn, Sid, Method, Path, Lower).

route(_Test, Conn, Sid, <<"GET">>, <<"/card">>, Headers) ->
    case proplists:get_value(<<"if-none-match">>, Headers) of
        ?ETAG ->
            ok = h1:respond(Conn, Sid, 304, [{<<"etag">>, ?ETAG}], <<>>);
        _ ->
            Card = #{<<"name">> => <<"Test Agent">>, <<"protocolVersion">> => <<"1.0">>},
            ok = json_respond(Conn, Sid, 200, [{<<"etag">>, ?ETAG}], Card)
    end;
route(_Test, Conn, Sid, <<"GET">>, <<"/missing-card">>, _) ->
    ok = json_respond(Conn, Sid, 404, [], #{<<"error">> => #{<<"message">> => <<"no card">>}});
route(Test, Conn, Sid, <<"POST">>, <<"/rpc">>, _) ->
    Body = collect_body(Sid, <<>>),
    {ok, Req} = barrel_a2a_json:decode(Body),
    {request, Id, Method, Params} = barrel_a2a_jsonrpc:classify(Req),
    rpc(Test, Conn, Sid, Id, Method, Params);
route(_Test, Conn, Sid, <<"GET">>, <<"/rest/tasks/t1", _/binary>>, _) ->
    ok = json_respond(Conn, Sid, 200, [], ?TASK);
route(_Test, Conn, Sid, <<"GET">>, <<"/rest/tasks/nope">>, _) ->
    ok = json_respond(Conn, Sid, 404, [], rest_not_found());
route(_Test, Conn, Sid, <<"POST">>, <<"/rest/message:send">>, _) ->
    _ = collect_body(Sid, <<>>),
    ok = json_respond(Conn, Sid, 200, [], #{<<"task">> => ?TASK});
route(_Test, Conn, Sid, <<"POST">>, <<"/rest/message:stream">>, _) ->
    _ = collect_body(Sid, <<>>),
    Frames = [
        #{<<"task">> => ?TASK},
        #{<<"statusUpdate">> => status_update(<<"TASK_STATE_COMPLETED">>, true)}
    ],
    ok = sse_stream(Conn, Sid, Frames);
route(_Test, Conn, Sid, <<"POST">>, <<"/rest/tasks/direct:subscribe">>, _) ->
    _ = collect_body(Sid, <<>>),
    ok = json_respond(Conn, Sid, 200, [], #{<<"task">> => ?TASK});
route(_Test, Conn, Sid, <<"POST">>, <<"/rest/tasks/nope:subscribe">>, _) ->
    _ = collect_body(Sid, <<>>),
    ok = json_respond(Conn, Sid, 404, [], rest_not_found());
route(Test, Conn, Sid, <<"POST">>, <<"/rest/tasks/forever:subscribe">>, _) ->
    _ = collect_body(Sid, <<>>),
    ok = h1:send_response(Conn, Sid, 200, [{<<"content-type">>, <<"text/event-stream">>}]),
    ok = h1:send_data(Conn, Sid, sse(#{<<"task">> => ?TASK}), false),
    Test ! {streaming, self()},
    keepalive(Test, Conn, Sid);
route(_Test, Conn, Sid, <<"GET">>, <<"/slow", _/binary>>, _) ->
    timer:sleep(1500),
    ok = json_respond(Conn, Sid, 200, [], ?TASK);
route(_Test, Conn, Sid, _, _, _) ->
    ok = h1:respond(Conn, Sid, 404, [], <<>>).

rpc(_Test, Conn, Sid, Id, <<"GetTask">>, _) ->
    ok = json_respond(Conn, Sid, 200, [], barrel_a2a_jsonrpc:response(Id, #{<<"task">> => ?TASK}));
rpc(_Test, Conn, Sid, Id, <<"CancelTask">>, _) ->
    Err = #{<<"code">> => -32001, <<"message">> => <<"Task not found">>},
    Body = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"error">> => Err},
    ok = json_respond(Conn, Sid, 200, [], Body);
rpc(_Test, Conn, Sid, Id, <<"SendStreamingMessage">>, _) ->
    Frames = [
        barrel_a2a_jsonrpc:response(Id, #{<<"task">> => ?TASK}),
        barrel_a2a_jsonrpc:response(Id, #{
            <<"statusUpdate">> => status_update(<<"TASK_STATE_WORKING">>, false)
        }),
        barrel_a2a_jsonrpc:response(Id, #{
            <<"statusUpdate">> => status_update(<<"TASK_STATE_COMPLETED">>, true)
        })
    ],
    ok = sse_stream(Conn, Sid, Frames);
rpc(_Test, Conn, Sid, Id, <<"SubscribeToTask">>, #{<<"id">> := <<"nope">>}) ->
    Err = #{<<"code">> => -32001, <<"message">> => <<"Task not found">>},
    Body = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"error">> => Err},
    ok = json_respond(Conn, Sid, 200, [], Body);
rpc(_Test, Conn, Sid, Id, Method, _) ->
    Err = #{<<"code">> => -32601, <<"message">> => Method},
    Body = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"error">> => Err},
    ok = json_respond(Conn, Sid, 200, [], Body).

keepalive(Test, Conn, Sid) ->
    receive
        {h1_stream, Sid, {stream_reset, Reason}} ->
            Test ! {disconnected, Reason}
    after 100 ->
        Frame = iolist_to_binary(barrel_a2a_sse:comment(<<"ka">>)),
        try h1:send_data(Conn, Sid, Frame, false) of
            ok -> keepalive(Test, Conn, Sid);
            {error, Reason} -> Test ! {disconnected, Reason}
        catch
            exit:Reason -> Test ! {disconnected, Reason}
        end
    end.

rest_not_found() ->
    #{
        <<"error">> => #{
            <<"code">> => 404,
            <<"status">> => <<"NOT_FOUND">>,
            <<"message">> => <<"x">>,
            <<"details">> => [
                #{
                    <<"@type">> => <<"type.googleapis.com/google.rpc.ErrorInfo">>,
                    <<"reason">> => <<"TASK_NOT_FOUND">>,
                    <<"domain">> => <<"a2a-protocol.org">>
                }
            ]
        }
    }.

status_update(State, Final) ->
    #{
        <<"taskId">> => <<"t1">>,
        <<"contextId">> => <<"c1">>,
        <<"status">> => #{<<"state">> => State},
        <<"final">> => Final
    }.

json_respond(Conn, Sid, Status, Headers, Body) ->
    h1:respond(
        Conn,
        Sid,
        Status,
        [{<<"content-type">>, <<"application/json">>} | Headers],
        barrel_a2a_json:encode(Body)
    ).

sse(Obj) ->
    iolist_to_binary(barrel_a2a_sse:encode(barrel_a2a_json:encode(Obj))).

sse_stream(Conn, Sid, Frames) ->
    ok = h1:send_response(Conn, Sid, 200, [{<<"content-type">>, <<"text/event-stream">>}]),
    lists:foreach(fun(F) -> ok = h1:send_data(Conn, Sid, sse(F), false) end, Frames),
    h1:send_data(Conn, Sid, <<>>, true).

collect_body(Sid, Acc) ->
    receive
        {h1_stream, Sid, {data, Chunk, true}} -> <<Acc/binary, Chunk/binary>>;
        {h1_stream, Sid, {data, Chunk, false}} -> collect_body(Sid, <<Acc/binary, Chunk/binary>>);
        {h1_stream, Sid, {trailers, _}} -> Acc
    after 5000 -> Acc
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

next_request() ->
    receive
        {request, _, Method, Path, Headers} -> {Method, Path, Headers}
    after 5000 -> error(no_request)
    end.

flush_requests() ->
    receive
        {request, _, _, _, _} -> flush_requests()
    after 0 -> ok
    end.

collect_stream(Ref) ->
    receive
        {a2a_stream, Ref, done} -> [done];
        {a2a_stream, Ref, {error, _} = E} -> [E];
        {a2a_stream, Ref, Msg} -> [Msg | collect_stream(Ref)]
    after 5000 -> error(stream_timeout)
    end.

%% `normal' when the process exited normally, before or after the monitor.
wait_down(Pid) ->
    Mon = monitor(process, Pid),
    receive
        {'DOWN', Mon, process, Pid, noproc} -> normal;
        {'DOWN', Mon, process, Pid, Reason} -> Reason
    after 5000 -> error(still_alive)
    end.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

connect_validates_url(_) ->
    Bad = #{<<"url">> => <<"ftp://x">>, <<"protocolBinding">> => <<"JSONRPC">>},
    ?assertMatch({error, #{type := invalid_params}}, barrel_a2a_client_http:connect(Bad, #{})),
    NoHost = #{<<"url">> => <<"not a url">>, <<"protocolBinding">> => <<"JSONRPC">>},
    ?assertMatch({error, #{type := invalid_params}}, barrel_a2a_client_http:connect(NoHost, #{})),
    Good = #{<<"url">> => <<"https://a.example/a2a/">>, <<"protocolBinding">> => <<"HTTP+JSON">>},
    ?assertMatch(
        {ok, #{url := <<"https://a.example/a2a">>, binding := <<"HTTP+JSON">>, timeout := 7}},
        barrel_a2a_client_http:connect(Good, #{timeout => 7})
    ),
    ?assertEqual(ok, barrel_a2a_client_http:close(#{})).

jsonrpc_call(Srv) ->
    flush_requests(),
    Conn = conn(Srv, jsonrpc),
    Opts = #{headers => [{<<"a2a-version">>, <<"1.0">>}]},
    ?assertEqual(
        {ok, #{<<"task">> => ?TASK}},
        barrel_a2a_client_http:call(Conn, get_task, #{<<"id">> => <<"t1">>}, Opts)
    ),
    {Method, Path, Headers} = next_request(),
    ?assertEqual(<<"POST">>, Method),
    ?assertEqual(<<"/rpc">>, Path),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Headers)),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"accept">>, Headers)),
    ?assertEqual(<<"1.0">>, proplists:get_value(<<"a2a-version">>, Headers)).

jsonrpc_error(Srv) ->
    Conn = conn(Srv, jsonrpc),
    ?assertMatch(
        {error, #{type := task_not_found, code := -32001, http_status := 200}},
        barrel_a2a_client_http:call(Conn, cancel_task, #{<<"id">> => <<"t1">>}, #{})
    ).

jsonrpc_stream(Srv) ->
    flush_requests(),
    Conn = conn(Srv, jsonrpc),
    Req = #{<<"message">> => #{<<"role">> => <<"ROLE_USER">>, <<"parts">> => []}},
    {ok, Ref} = barrel_a2a_client_http:stream(Conn, send_streaming_message, Req, self(), #{}),
    ?assert(is_pid(Ref)),
    Msgs = collect_stream(Ref),
    ?assertMatch(
        [
            {event, #{<<"task">> := _}},
            {event, #{
                <<"statusUpdate">> := #{<<"status">> := #{<<"state">> := <<"TASK_STATE_WORKING">>}}
            }},
            {event, #{<<"statusUpdate">> := #{<<"final">> := true}}},
            done
        ],
        Msgs
    ),
    {_, _, Headers} = next_request(),
    ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"accept">>, Headers)),
    ?assertEqual(normal, wait_down(Ref)).

rest_call(Srv) ->
    flush_requests(),
    Conn = conn(Srv, rest),
    ?assertEqual(
        {ok, ?TASK},
        barrel_a2a_client_http:call(
            Conn, get_task, #{<<"id">> => <<"t1">>, <<"historyLength">> => 3}, #{}
        )
    ),
    {Method, Path, Headers} = next_request(),
    ?assertEqual(<<"GET">>, Method),
    ?assertEqual(<<"/rest/tasks/t1?historyLength=3">>, Path),
    ?assertEqual(undefined, proplists:get_value(<<"content-type">>, Headers)),
    ?assertEqual(
        <<"application/a2a+json, application/json">>, proplists:get_value(<<"accept">>, Headers)
    ),
    Req = #{<<"message">> => #{<<"role">> => <<"ROLE_USER">>, <<"parts">> => []}},
    ?assertEqual(
        {ok, #{<<"task">> => ?TASK}}, barrel_a2a_client_http:call(Conn, send_message, Req, #{})
    ),
    {<<"POST">>, <<"/rest/message:send">>, Headers2} = next_request(),
    ?assertEqual(<<"application/a2a+json">>, proplists:get_value(<<"content-type">>, Headers2)).

rest_error(Srv) ->
    Conn = conn(Srv, rest),
    ?assertMatch(
        {error, #{type := task_not_found, http_status := 404, message := <<"x">>}},
        barrel_a2a_client_http:call(Conn, get_task, #{<<"id">> => <<"nope">>}, #{})
    ),
    ?assertMatch(
        {error, #{type := task_not_found, http_status := 404}},
        barrel_a2a_client_http:call(Conn, cancel_task, #{<<"id">> => <<"zzz">>}, #{})
    ).

rest_stream(Srv) ->
    flush_requests(),
    Conn = conn(Srv, rest),
    Req = #{<<"message">> => #{<<"role">> => <<"ROLE_USER">>, <<"parts">> => []}},
    {ok, Ref} = barrel_a2a_client_http:stream(Conn, send_streaming_message, Req, self(), #{}),
    ?assertMatch(
        [{event, #{<<"task">> := _}}, {event, #{<<"statusUpdate">> := _}}, done],
        collect_stream(Ref)
    ),
    {<<"POST">>, <<"/rest/message:stream">>, Headers} = next_request(),
    ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"accept">>, Headers)),
    ?assertEqual(<<"application/a2a+json">>, proplists:get_value(<<"content-type">>, Headers)).

%% A server that answers a stream request with a plain JSON reply.
rest_direct_reply(Srv) ->
    Conn = conn(Srv, rest),
    Req = #{<<"id">> => <<"direct">>},
    {ok, Ref} = barrel_a2a_client_http:stream(Conn, subscribe_to_task, Req, self(), #{}),
    ?assertEqual([{event, #{<<"task">> => ?TASK}}, done], collect_stream(Ref)).

stream_error_status(Srv) ->
    Rest = conn(Srv, rest),
    {ok, R1} = barrel_a2a_client_http:stream(
        Rest, subscribe_to_task, #{<<"id">> => <<"nope">>}, self(), #{}
    ),
    ?assertMatch([{error, #{type := task_not_found, http_status := 404}}], collect_stream(R1)),
    Rpc = conn(Srv, jsonrpc),
    {ok, R2} = barrel_a2a_client_http:stream(
        Rpc, subscribe_to_task, #{<<"id">> => <<"nope">>}, self(), #{}
    ),
    ?assertMatch([{error, #{type := task_not_found}}], collect_stream(R2)).

stream_owner_down(Srv) ->
    Conn = conn(Srv, rest),
    Test = self(),
    Owner = spawn(fun() ->
        {ok, Ref} = barrel_a2a_client_http:stream(
            Conn, subscribe_to_task, #{<<"id">> => <<"forever">>}, self(), #{}
        ),
        Test ! {ref, Ref},
        receive
            stop -> ok
        end
    end),
    Ref =
        receive
            {ref, R} -> R
        after 5000 -> error(no_ref)
        end,
    receive
        {streaming, _} -> ok
    after 5000 -> error(not_streaming)
    end,
    Owner ! stop,
    ?assertEqual(normal, wait_down(Ref)),
    receive
        {disconnected, _} -> ok
    after 5000 -> error(server_not_disconnected)
    end.

cancel_stream(Srv) ->
    Conn = conn(Srv, rest),
    {ok, Ref} = barrel_a2a_client_http:stream(
        Conn, subscribe_to_task, #{<<"id">> => <<"forever">>}, self(), #{}
    ),
    receive
        {a2a_stream, Ref, {event, #{<<"task">> := _}}} -> ok
    after 5000 -> error(no_first_event)
    end,
    receive
        {streaming, _} -> ok
    after 5000 -> error(not_streaming)
    end,
    ?assertEqual(ok, barrel_a2a_client_http:cancel_stream(Conn, Ref)),
    ?assertEqual(normal, wait_down(Ref)),
    %% Idempotent on a dead stream.
    ?assertEqual(ok, barrel_a2a_client_http:cancel_stream(Conn, Ref)),
    receive
        {disconnected, _} -> ok
    after 5000 -> error(server_not_disconnected)
    end,
    %% No `done' after a cancel.
    receive
        {a2a_stream, Ref, done} -> error(done_after_cancel)
    after 100 -> ok
    end.

fetch_card(Srv) ->
    flush_requests(),
    Url = <<(base(Srv))/binary, "/card">>,
    ?assertEqual(
        {ok, #{<<"name">> => <<"Test Agent">>, <<"protocolVersion">> => <<"1.0">>}, ?ETAG},
        barrel_a2a_client_http:fetch_card(Url, #{headers => [{<<"x-a">>, <<"b">>}]})
    ),
    {<<"GET">>, <<"/card">>, Headers} = next_request(),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"accept">>, Headers)),
    ?assertEqual(<<"b">>, proplists:get_value(<<"x-a">>, Headers)),
    ?assertEqual(undefined, proplists:get_value(<<"if-none-match">>, Headers)).

fetch_card_etag(Srv) ->
    flush_requests(),
    Url = <<(base(Srv))/binary, "/card">>,
    ?assertEqual({ok, not_modified}, barrel_a2a_client_http:fetch_card(Url, #{etag => ?ETAG})),
    {<<"GET">>, <<"/card">>, Headers} = next_request(),
    ?assertEqual(?ETAG, proplists:get_value(<<"if-none-match">>, Headers)),
    ?assertMatch(
        {ok, #{<<"name">> := _}, ?ETAG},
        barrel_a2a_client_http:fetch_card(Url, #{etag => <<"\"other\"">>})
    ).

fetch_card_error(Srv) ->
    Url = <<(base(Srv))/binary, "/missing-card">>,
    ?assertMatch(
        {error, #{type := task_not_found, http_status := 404, message := <<"no card">>}},
        barrel_a2a_client_http:fetch_card(Url, #{})
    ).

call_timeout(Srv) ->
    {ok, Conn} = barrel_a2a_client_http:connect(
        #{<<"url">> => <<(base(Srv))/binary, "/slow">>, <<"protocolBinding">> => <<"HTTP+JSON">>},
        #{}
    ),
    ?assertMatch(
        {error, #{type := timeout}},
        barrel_a2a_client_http:call(Conn, get_task, #{<<"id">> => <<"t1">>}, #{timeout => 300})
    ).

connection_refused(_) ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/rpc">>,
    {ok, Conn} = barrel_a2a_client_http:connect(
        #{<<"url">> => Url, <<"protocolBinding">> => <<"JSONRPC">>}, #{}
    ),
    ?assertMatch(
        {error, #{type := transport}},
        barrel_a2a_client_http:call(Conn, get_task, #{<<"id">> => <<"t1">>}, #{timeout => 2000})
    ),
    ?assertMatch({error, #{type := transport}}, barrel_a2a_client_http:fetch_card(Url, #{})),
    {ok, Ref} = barrel_a2a_client_http:stream(
        Conn, subscribe_to_task, #{<<"id">> => <<"t1">>}, self(), #{}
    ),
    ?assertMatch([{error, #{type := transport}}], collect_stream(Ref)).
