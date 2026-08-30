%%%-------------------------------------------------------------------
%%% @doc The embedding contract: a server without a listener, driven
%%% through `barrel_a2a_http_engine:handle/6' by a fake responder and
%%% by a second, hand-written h1 listener built the way `livery_a2a'
%%% is (see guides/embedding.md), plus direct calls to
%%% `barrel_a2a_server_core:call/4' the way a gRPC binding would.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_embed_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [
        engine_config_is_validated,
        routes_are_listed,
        card_through_fake_responder,
        jsonrpc_through_fake_responder,
        rest_through_fake_responder,
        stream_through_fake_responder,
        principal_override_skips_auth,
        disconnect_ends_stream,
        embedder_listener_end_to_end,
        core_call_every_operation,
        two_servers_coexist,
        failed_start_leaves_nothing_behind,
        bad_options_are_refused,
        losing_the_task_supervisor_stops_the_server
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_a2a),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    {ok, Server} = barrel_a2a_server:start(
        barrel_a2a_test_agent:card(#{
            supported_interfaces => [
                barrel_a2a_agent_card:interface(
                    <<"http://embedded.example/a2a/jsonrpc">>, <<"JSONRPC">>, <<"1.0">>
                )
            ]
        }),
        #{handler => barrel_a2a_test_agent, listen => false, blocking_timeout => 5000}
    ),
    [{server, Server} | Config].

end_per_testcase(_Case, Config) ->
    barrel_a2a_server:stop(?config(server, Config)).

%%--------------------------------------------------------------------
%% A responder that collects into the test process
%%--------------------------------------------------------------------

fake_responder() ->
    Self = self(),
    #{
        reply => fun(Status, Headers, Body) ->
            Self ! {reply, Status, Headers, iolist_to_binary(Body)},
            ok
        end,
        stream_start => fun(Status, Headers) ->
            Self ! {stream_start, Status, Headers},
            ok
        end,
        stream_chunk => fun(Data) ->
            Self ! {chunk, iolist_to_binary(Data)},
            ok
        end,
        stream_end => fun() ->
            Self ! stream_end,
            ok
        end,
        disconnected => fun(Msg) -> Msg =:= fake_disconnect end
    }.

handle(Config, Method, Path, Headers, Body) ->
    handle(Config, Method, Path, Headers, Body, #{}).

handle(Config, Method, Path, Headers, Body, Overrides) ->
    Cfg = barrel_a2a_server:engine_config(?config(server, Config), Overrides),
    Self = self(),
    Responder = fake_responder(),
    %% The engine runs in the caller's process; run it in a helper so
    %% streaming calls do not block the test process.
    spawn_link(fun() ->
        ok = barrel_a2a_http_engine:handle(Method, Path, Headers, Body, Responder, Cfg),
        Self ! handled
    end),
    ok.

reply() ->
    receive
        {reply, Status, Headers, Body} -> {Status, Headers, Body}
    after 5000 -> ct:fail(no_reply)
    end.

jsonrpc_body(Method, Params) ->
    barrel_a2a_json:encode(barrel_a2a_jsonrpc:request(1, Method, Params)).

json_headers() -> [{<<"a2a-version">>, <<"1.0">>}, {<<"content-type">>, <<"application/json">>}].

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

engine_config_is_validated(Config) ->
    Server = ?config(server, Config),
    Cfg = barrel_a2a_server:engine_config(Server),
    ?assertMatch(#{server := Server, base_path := <<"/a2a">>, keepalive_ms := 15000}, Cfg),
    ?assertMatch(
        #{base_path := <<"/agents/x">>, keepalive_ms := 100},
        barrel_a2a_server:engine_config(Server, #{base_path => <<"/agents/x">>, keepalive_ms => 100})
    ),
    ?assertError(
        {invalid_engine_option, keepalive_ms, 0},
        barrel_a2a_server:engine_config(Server, #{keepalive_ms => 0})
    ),
    %% No listener, no port, and the card carries the embedder's URLs.
    ?assertEqual(undefined, barrel_a2a_server:port(Server)),
    [I] = barrel_a2a_agent_card:interfaces(barrel_a2a_server:card(Server)),
    ?assertEqual(<<"http://embedded.example/a2a/jsonrpc">>, maps:get(<<"url">>, I)).

routes_are_listed(Config) ->
    Cfg = barrel_a2a_server:engine_config(?config(server, Config)),
    Routes = barrel_a2a_http_engine:routes(Cfg),
    ?assert(lists:member({<<"GET">>, <<"/.well-known/agent-card.json">>}, Routes)),
    ?assert(lists:member({<<"POST">>, <<"/a2a/jsonrpc">>}, Routes)),
    ?assert(lists:member({<<"POST">>, <<"/a2a/v1/message:send">>}, Routes)),
    ?assert(lists:member({<<"GET">>, <<"/a2a/v1/tasks/:id">>}, Routes)),
    ?assertEqual(14, length(Routes)),
    TenantCfg = barrel_a2a_server:engine_config(?config(server, Config), #{tenant => <<"acme">>}),
    ?assert(
        lists:member(
            {<<"POST">>, <<"/a2a/v1/acme/message:send">>}, barrel_a2a_http_engine:routes(TenantCfg)
        )
    ).

card_through_fake_responder(Config) ->
    handle(Config, <<"GET">>, <<"/.well-known/agent-card.json">>, [], <<>>),
    {200, Headers, Body} = reply(),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Headers)),
    {ok, Card} = barrel_a2a_json:decode(Body),
    ?assertEqual(<<"Test Agent">>, barrel_a2a_agent_card:name(Card)),
    ETag = proplists:get_value(<<"etag">>, Headers),
    handle(
        Config, <<"GET">>, <<"/.well-known/agent-card.json">>, [{<<"If-None-Match">>, ETag}], <<>>
    ),
    ?assertMatch({304, _, <<>>}, reply()).

jsonrpc_through_fake_responder(Config) ->
    Req = #{<<"message">> => barrel_a2a_message:new(<<"echo: embedded">>)},
    handle(
        Config, <<"POST">>, <<"/a2a/jsonrpc">>, json_headers(), jsonrpc_body(<<"SendMessage">>, Req)
    ),
    {200, _, Body} = reply(),
    {ok, Decoded} = barrel_a2a_json:decode(Body),
    #{<<"result">> := #{<<"task">> := Task}} = Decoded,
    ?assertEqual(completed, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"embedded">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Task)))).

rest_through_fake_responder(Config) ->
    Req = barrel_a2a_json:encode(#{<<"message">> => barrel_a2a_message:new(<<"echo: rest">>)}),
    handle(
        Config,
        <<"POST">>,
        <<"/a2a/v1/message:send">>,
        [{<<"a2a-version">>, <<"1.0">>}, {<<"content-type">>, <<"application/a2a+json">>}],
        Req
    ),
    {200, Headers, Body} = reply(),
    ?assertEqual(<<"application/a2a+json">>, proplists:get_value(<<"content-type">>, Headers)),
    {ok, #{<<"task">> := Task}} = barrel_a2a_json:decode(Body),
    Id = barrel_a2a_task:id(Task),
    handle(
        Config, <<"GET">>, <<"/a2a/v1/tasks/", Id/binary, "?historyLength=0">>, json_headers(), <<>>
    ),
    {200, _, Body2} = reply(),
    {ok, Fetched} = barrel_a2a_json:decode(Body2),
    ?assertEqual(Id, barrel_a2a_task:id(Fetched)),
    ?assertNot(maps:is_key(<<"history">>, Fetched)),
    handle(Config, <<"GET">>, <<"/a2a/v1/tasks/nope">>, json_headers(), <<>>),
    {404, _, Body3} = reply(),
    ?assertMatch(
        {ok, #{<<"error">> := #{<<"status">> := <<"NOT_FOUND">>}}}, barrel_a2a_json:decode(Body3)
    ),
    %% The engine reads `resource:verb' strictly, on this path too.
    handle(Config, <<"POST">>, <<"/a2a/v1/tasks/x:frobnicate">>, json_headers(), <<>>),
    {404, _, Body4} = reply(),
    ?assertMatch(
        {ok, #{
            <<"error">> := #{
                <<"details">> := [#{<<"reason">> := <<"METHOD_NOT_FOUND">>} | _]
            }
        }},
        barrel_a2a_json:decode(Body4)
    ),
    handle(Config, <<"GET">>, <<"/a2a/v1/tasks/x:cancel">>, json_headers(), <<>>),
    {405, Headers5, _} = reply(),
    ?assertEqual(<<"POST">>, proplists:get_value(<<"allow">>, Headers5)).

stream_through_fake_responder(Config) ->
    Req = #{<<"message">> => barrel_a2a_message:new(<<"stream">>)},
    handle(
        Config,
        <<"POST">>,
        <<"/a2a/jsonrpc">>,
        json_headers(),
        jsonrpc_body(<<"SendStreamingMessage">>, Req)
    ),
    receive
        {stream_start, 200, Headers} ->
            ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"content-type">>, Headers))
    after 5000 -> ct:fail(no_stream_start)
    end,
    Frames = collect_chunks([]),
    Events = [decode_frame(F) || F <- Frames],
    ?assertEqual(
        [task, status_update, artifact_update, artifact_update, status_update],
        [barrel_a2a_event:kind(E) || E <- Events]
    ),
    receive
        handled -> ok
    after 1000 -> ct:fail(engine_did_not_return)
    end.

collect_chunks(Acc) ->
    receive
        {chunk, Data} -> collect_chunks([Data | Acc]);
        stream_end -> lists:reverse(Acc)
    after 5000 -> ct:fail({stream_timeout, lists:reverse(Acc)})
    end.

decode_frame(Frame) ->
    P = barrel_a2a_sse:new(),
    {[#{data := Data}], _} = barrel_a2a_sse:feed(Frame, P),
    {ok, #{<<"result">> := Event}} = barrel_a2a_json:decode(Data),
    Event.

principal_override_skips_auth(_Config) ->
    %% A server with bearer auth answers an embedder-supplied
    %% principal without an Authorization header, as livery_a2a does
    %% after its own middleware authenticated the request.
    {ok, Server} = barrel_a2a_server:start(barrel_a2a_test_agent:card(), #{
        handler => barrel_a2a_test_agent,
        listen => false,
        auth => {bearer, fun(_) -> {error, unauthenticated} end}
    }),
    try
        Cfg = barrel_a2a_server:engine_config(Server, #{principal => #{user => <<"mw">>}}),
        Responder = fake_responder(),
        Req = #{<<"message">> => barrel_a2a_message:new(<<"principal">>)},
        ok = barrel_a2a_http_engine:handle(
            <<"POST">>,
            <<"/a2a/jsonrpc">>,
            json_headers(),
            jsonrpc_body(<<"SendMessage">>, Req),
            Responder,
            Cfg
        ),
        {200, _, Body} = reply(),
        {ok, #{<<"result">> := #{<<"task">> := Task}}} = barrel_a2a_json:decode(Body),
        ?assertEqual(
            <<"#{user => <<\"mw\">>}">>,
            barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Task)))
        ),
        %% Without the override the hook applies.
        Cfg2 = barrel_a2a_server:engine_config(Server),
        ok = barrel_a2a_http_engine:handle(
            <<"POST">>,
            <<"/a2a/jsonrpc">>,
            json_headers(),
            jsonrpc_body(<<"SendMessage">>, Req),
            Responder,
            Cfg2
        ),
        ?assertMatch({401, _, _}, reply())
    after
        barrel_a2a_server:stop(Server)
    end.

disconnect_ends_stream(Config) ->
    Req = #{<<"message">> => barrel_a2a_message:new(<<"slow 3000">>)},
    Cfg = barrel_a2a_server:engine_config(?config(server, Config), #{keepalive_ms => 200}),
    Self = self(),
    Responder = fake_responder(),
    Engine = spawn_link(fun() ->
        ok = barrel_a2a_http_engine:handle(
            <<"POST">>,
            <<"/a2a/jsonrpc">>,
            json_headers(),
            jsonrpc_body(<<"SendStreamingMessage">>, Req),
            Responder,
            Cfg
        ),
        Self ! handled
    end),
    receive
        {stream_start, 200, _} -> ok
    after 5000 -> ct:fail(no_stream_start)
    end,
    %% Keepalive comments flow while the task is slow.
    receive
        {chunk, <<":", _/binary>>} -> ok
    after 2000 -> ct:fail(no_keepalive)
    end,
    Engine ! fake_disconnect,
    receive
        handled -> ok
    after 2000 -> ct:fail(engine_did_not_stop_on_disconnect)
    end.

%% The livery_a2a shape: an h1 server whose per-request handler reads
%% the body, builds a responder on h1 and calls the engine.
embedder_listener_end_to_end(_Config) ->
    %% The card must point at the embedder's own listener, so start the
    %% h1 server first and give its URL to a dedicated server instance.
    Self = self(),
    Handler = fun(Conn, Sid, Method, Path, Headers) ->
        Cfg = receive_cfg(Self),
        Body = read_body(Sid, <<>>),
        Responder = #{
            reply => fun(Status, Hs, B) ->
                Bin = iolist_to_binary(B),
                h1:respond(
                    Conn,
                    Sid,
                    Status,
                    [{<<"content-length">>, integer_to_binary(byte_size(Bin))} | Hs],
                    Bin
                )
            end,
            stream_start => fun(Status, Hs) -> h1:send_response(Conn, Sid, Status, Hs) end,
            stream_chunk => fun(D) -> h1:send_data(Conn, Sid, iolist_to_binary(D), false) end,
            stream_end => fun() -> h1:send_data(Conn, Sid, <<>>, true) end,
            disconnected => fun
                ({h1_stream, S, {stream_reset, _}}) when S =:= Sid -> true;
                (_) -> false
            end
        },
        barrel_a2a_http_engine:handle(Method, Path, Headers, Body, Responder, Cfg)
    end,
    {ok, H1} = h1:start_server(0, #{transport => tcp, handler => Handler}),
    Url = <<"http://127.0.0.1:", (integer_to_binary(h1:server_port(H1)))/binary>>,
    Card = barrel_a2a_test_agent:card(#{
        supported_interfaces => [
            barrel_a2a_agent_card:interface(
                <<Url/binary, "/a2a/jsonrpc">>, <<"JSONRPC">>, <<"1.0">>
            ),
            barrel_a2a_agent_card:interface(<<Url/binary, "/a2a/v1">>, <<"HTTP+JSON">>, <<"1.0">>)
        ]
    }),
    {ok, Server} = barrel_a2a_server:start(Card, #{
        handler => barrel_a2a_test_agent, listen => false
    }),
    Cfg = barrel_a2a_server:engine_config(Server),
    persistent_term:put({?MODULE, embed_cfg}, Cfg),
    try
        {ok, Agent} = barrel_a2a_client:connect(Url, #{prefer => [rest]}),
        ?assertEqual(<<"Test Agent">>, barrel_a2a_agent_card:name(barrel_a2a_client:card(Agent))),
        {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"echo: via embedder">>),
        ?assertEqual(
            <<"via embedder">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T)))
        ),
        {ok, RT} = barrel_a2a_client:start(Agent, <<"stream">>),
        ok = barrel_a2a_remote_task:stream_to(RT, self()),
        {ok, Final} = barrel_a2a_remote_task:result(RT, 5000),
        ?assertEqual(completed, barrel_a2a_task:state(Final)),
        ?assertEqual(<<"part one part two">>, barrel_a2a_remote_task:text(RT))
    after
        h1:stop_server(H1),
        barrel_a2a_server:stop(Server)
    end.

receive_cfg(_) ->
    persistent_term:get({?MODULE, embed_cfg}).

read_body(Sid, Acc) ->
    receive
        {h1_stream, Sid, {data, Bin, true}} -> <<Acc/binary, Bin/binary>>;
        {h1_stream, Sid, {data, Bin, false}} -> read_body(Sid, <<Acc/binary, Bin/binary>>);
        {h1_stream, Sid, {trailers, _}} -> Acc
    after 5000 -> Acc
    end.

%% What a gRPC binding does: call the core with wire-shaped maps.
core_call_every_operation(Config) ->
    Server = ?config(server, Config),
    Ctx = #{
        binding => grpc,
        headers => [{<<"a2a-version">>, <<"1.0">>}],
        version => <<"1.0">>,
        extensions => [],
        %% What a gRPC binding supplies after authenticating the peer.
        %% The extended agent card is refused without it.
        principal => <<"embedder">>
    },
    Call = fun(Op, Req) -> barrel_a2a_server_core:call(Server, Op, Req, Ctx) end,
    {ok, #{<<"task">> := T}} = Call(send_message, #{
        <<"message">> => barrel_a2a_message:new(<<"ask">>)
    }),
    Id = barrel_a2a_task:id(T),
    ?assertEqual(input_required, barrel_a2a_task:state(T)),
    {ok, Got} = Call(get_task, #{<<"id">> => Id}),
    ?assertEqual(Id, barrel_a2a_task:id(Got)),
    {ok, #{<<"tasks">> := [_ | _], <<"nextPageToken">> := <<>>}} = Call(list_tasks, #{}),
    ?assertMatch({error, #{type := task_not_found}}, Call(get_task, #{<<"id">> => <<"nope">>})),
    ?assertMatch(
        {error, #{type := push_notification_not_supported}},
        Call(list_push_configs, #{<<"taskId">> => Id})
    ),
    ?assertMatch(
        {error, #{type := unsupported_operation}}, Call(get_extended_agent_card, #{})
    ),
    ?assertMatch({error, #{type := invalid_params}}, Call(send_message, #{<<"message">> => #{}})),
    ?assertMatch(
        {error, #{type := version_not_supported}},
        barrel_a2a_server_core:call(Server, get_task, #{<<"id">> => Id}, Ctx#{version => <<"9.9">>})
    ),
    %% Streaming: subscribe, then events arrive as messages.
    {stream, Subscribe} = Call(subscribe_to_task, #{<<"id">> => Id}),
    {ok, [#{<<"task">> := _}]} = Subscribe(self()),
    {ok, #{<<"task">> := _}} = Call(send_message, #{
        <<"message">> => barrel_a2a_message:new(<<"go">>, #{task_id => Id}),
        <<"configuration">> => #{<<"returnImmediately">> => true}
    }),
    Kinds = collect_core_events(Id, []),
    ?assert(lists:member(status_update, Kinds)),
    ?assert(lists:member(artifact_update, Kinds)),
    %% The follow-up completed the task, so cancel is refused; a live
    %% task would be canceled instead.
    case Call(cancel_task, #{<<"id">> => Id}) of
        {ok, Canceled} -> ?assertEqual(canceled, barrel_a2a_task:state(Canceled));
        {error, #{type := task_not_cancelable}} -> ok
    end,
    ?assertEqual(not_found, barrel_a2a_error:grpc_status(task_not_found)).

collect_core_events(Id, Acc) ->
    receive
        {a2a_task_event, Id, Ev} ->
            case barrel_a2a_event:is_final(Ev) of
                true -> lists:reverse([barrel_a2a_event:kind(Ev) | Acc]);
                false -> collect_core_events(Id, [barrel_a2a_event:kind(Ev) | Acc])
            end
    after 5000 -> lists:reverse(Acc)
    end.

two_servers_coexist(Config) ->
    {ok, Other} = barrel_a2a_server:start(barrel_a2a_test_agent:card(#{name => <<"Other">>}), #{
        handler => fun(_Ctx, _M) -> {ok, <<"other">>} end, listen => false
    }),
    try
        A = barrel_a2a_server:engine_config(?config(server, Config)),
        B = barrel_a2a_server:engine_config(Other),
        R = fake_responder(),
        ok = barrel_a2a_http_engine:handle(
            <<"GET">>, <<"/.well-known/agent-card.json">>, [], <<>>, R, A
        ),
        {200, _, BodyA} = reply(),
        ok = barrel_a2a_http_engine:handle(
            <<"GET">>, <<"/.well-known/agent-card.json">>, [], <<>>, R, B
        ),
        {200, _, BodyB} = reply(),
        {ok, CardA} = barrel_a2a_json:decode(BodyA),
        {ok, CardB} = barrel_a2a_json:decode(BodyB),
        ?assertEqual(<<"Test Agent">>, barrel_a2a_agent_card:name(CardA)),
        ?assertEqual(<<"Other">>, barrel_a2a_agent_card:name(CardB))
    after
        barrel_a2a_server:stop(Other)
    end.

%% `init/1' returning `{stop, _}' never runs `terminate/2', so the
%% config it published and the listener it opened have to be undone by
%% hand. A signing key the card cannot use fails after the listener is
%% up, which is the case that used to leak both.
failed_start_leaves_nothing_behind(_Config) ->
    Listeners = fun() -> length(supervisor:which_children(barrel_a2a_listener_sup)) end,
    Configs = fun() -> length([K || {{barrel_a2a_server, _} = K, _} <- persistent_term:get()]) end,
    {L0, C0} = {Listeners(), Configs()},
    %% A signing key the card cannot use fails in `finalize_card/1',
    %% after `maybe_listen/1' has already opened a port.
    ?assertMatch(
        {error, _},
        barrel_a2a_server:start(barrel_a2a_test_agent:card(), #{
            handler => barrel_a2a_test_agent,
            http => #{port => 0},
            signing => #{key => not_a_key, alg => 'ES256'}
        })
    ),
    %% the instance supervisor needs a moment to give up on its child
    timer:sleep(300),
    ?assertEqual(C0, Configs()),
    ?assertEqual(L0, Listeners()).

bad_options_are_refused(_Config) ->
    Start = fun(Extra) ->
        barrel_a2a_server:start(
            barrel_a2a_test_agent:card(),
            maps:merge(#{handler => barrel_a2a_test_agent, listen => false}, Extra)
        )
    end,
    ?assertMatch(
        {error, {invalid_option, {blocking_timeout, 0}}}, Start(#{blocking_timeout => 0})
    ),
    ?assertMatch(
        {error, {invalid_option, {validate_schema, 'maybe'}}}, Start(#{validate_schema => 'maybe'})
    ),
    {ok, S} = Start(#{blocking_timeout => infinity, validate_schema => strict}),
    ?assertEqual(infinity, maps:get(blocking_timeout, barrel_a2a_server:config(S))),
    barrel_a2a_server:stop(S).

%% The task and push supervisors are linked, not supervised. Losing one
%% must take the server down rather than leave it holding a dead pid.
losing_the_task_supervisor_stops_the_server(Config) ->
    Server = ?config(server, Config),
    TaskSup = maps:get(task_sup, barrel_a2a_server:config(Server)),
    Ref = monitor(process, Server),
    exit(TaskSup, kill),
    receive
        {'DOWN', Ref, process, Server, _} -> ok
    after 5000 -> ct:fail(server_survived_dead_task_sup)
    end.
