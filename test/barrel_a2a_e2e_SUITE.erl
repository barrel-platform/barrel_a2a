%%%-------------------------------------------------------------------
%%% @doc End to end: a real server and a real client, over each
%%% binding. Every group runs the same cases with the client bound to
%%% a different interface.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all, nowarn_deprecated_catch]).

all() ->
    [
        {group, jsonrpc},
        {group, rest},
        {group, rest_tenant},
        {group, tls}
    ].

groups() ->
    Cases = [
        discovery,
        card_caching,
        request_response,
        direct_message,
        long_running,
        streaming_order,
        streaming_subscribe,
        artifacts,
        cancellation,
        remote_failure,
        handler_crash,
        handler_protocol_error,
        client_timeout,
        follow_up_input_required,
        follow_up_queue_is_bounded,
        auth_required_resume,
        list_tasks_filters,
        list_tasks_scoping,
        auth_hook,
        extended_card,
        extended_card_needs_auth,
        extensions,
        version_error,
        client_disconnect_mid_stream,
        push_notifications,
        push_ssrf_rejected,
        content_type_not_supported,
        malformed_request,
        signed_card,
        history_length
    ],
    [
        {jsonrpc, [], Cases},
        {rest, [], Cases},
        {rest_tenant, [], [request_response, streaming_order, tenant_mismatch]},
        {tls, [], [request_response, streaming_order]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_a2a),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Group, Config) ->
    Extra =
        case Group of
            rest_tenant ->
                #{tenant => <<"acme">>};
            tls ->
                Port = free_port(),
                #{
                    http => #{port => Port, tls => tls_opts()},
                    url => <<"https://localhost:", (integer_to_binary(Port))/binary>>
                };
            _ ->
                #{}
        end,
    Prefer =
        case Group of
            jsonrpc -> [jsonrpc];
            _ -> [rest]
        end,
    Sink = spawn(fun sink_loop/0),
    register(a2a_test_sink, Sink),
    {ok, Server} = start_server(Extra),
    [{server, Server}, {prefer, Prefer}, {group, Group}, {sink, Sink} | Config].

end_per_group(_Group, Config) ->
    barrel_a2a_server:stop(?config(server, Config)),
    _ = (catch unregister(a2a_test_sink)),
    exit(?config(sink, Config), kill),
    ok.

init_per_testcase(_Case, Config) ->
    flush_sink(),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

start_server(Extra) ->
    Opts = maps:merge(
        #{
            handler => barrel_a2a_test_agent,
            http => #{port => 0},
            auth => none,
            blocking_timeout => 5000,
            extended_card => fun(Principal) ->
                barrel_a2a_test_agent:card(#{
                    name => <<"Extended">>, description => principal_bin(Principal)
                })
            end
        },
        Extra
    ),
    Card = barrel_a2a_test_agent:card(#{
        capabilities => #{
            extensions => [
                #{uri => <<"https://example.com/ext/one">>, description => <<"one">>},
                #{uri => <<"https://example.com/ext/two">>, description => <<"two">>}
            ]
        }
    }),
    barrel_a2a_server:start(Card, Opts).

principal_bin(P) -> iolist_to_binary(io_lib:format("~0p", [P])).

connect(Config) -> connect(Config, #{}).

connect(Config, Extra) ->
    Server = ?config(server, Config),
    Opts = maps:merge(#{prefer => ?config(prefer, Config), timeout => 5000}, Extra),
    Opts1 =
        case ?config(group, Config) of
            tls -> Opts#{transport_opts => #{ssl_options => [{cacertfile, cacert_file()}]}};
            _ -> Opts
        end,
    {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), Opts1),
    Agent.

free_port() ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    Port.

tls_files() ->
    case persistent_term:get({?MODULE, tls}, undefined) of
        undefined ->
            Files = barrel_a2a_test_tls:make_certs(),
            persistent_term:put({?MODULE, tls}, Files),
            Files;
        Files ->
            Files
    end.

tls_opts() ->
    #{certfile := Cert, keyfile := Key} = tls_files(),
    #{certfile => Cert, keyfile => Key}.

cacert_file() ->
    maps:get(cacertfile, tls_files()).

sink_loop() -> sink_loop([]).

sink_loop(Stored) ->
    receive
        {get, From} ->
            From ! {sink, lists:reverse(Stored)},
            sink_loop([]);
        flush ->
            sink_loop([]);
        Msg ->
            sink_loop([Msg | Stored])
    end.

sink_messages() ->
    a2a_test_sink ! {get, self()},
    receive
        {sink, Msgs} -> Msgs
    after 1000 -> []
    end.

flush_sink() ->
    case whereis(a2a_test_sink) of
        undefined -> ok;
        Pid -> Pid ! flush
    end.

wait_sink(Pred, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_sink_loop(Pred, Deadline).

wait_sink_loop(Pred, Deadline) ->
    case lists:filter(Pred, sink_messages()) of
        [M | _] ->
            {ok, M};
        [] ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    timeout;
                false ->
                    timer:sleep(50),
                    wait_sink_loop(Pred, Deadline)
            end
    end.

collect_events(RT) -> collect_events(RT, []).

collect_events(RT, Acc) ->
    receive
        {a2a_event, RT, Ev} -> collect_events(RT, [Ev | Acc]);
        {a2a_done, RT, Final} -> {lists:reverse(Acc), {done, Final}};
        {a2a_error, RT, E} -> {lists:reverse(Acc), {error, E}}
    after 10000 -> {lists:reverse(Acc), timeout}
    end.

kinds(Events) -> [barrel_a2a_event:kind(E) || E <- Events].

states(Events) ->
    [
        S
     || #{<<"statusUpdate">> := #{<<"status">> := #{<<"state">> := W}}} <- Events,
        {ok, S} <- [barrel_a2a_task_state:from_wire(W)]
    ].

raw_url(Config, Path) ->
    Server = ?config(server, Config),
    <<(barrel_a2a_server:url(Server))/binary, Path/binary>>.

hackney_opts(Config) ->
    case ?config(group, Config) of
        tls -> [{ssl_options, [{cacertfile, cacert_file()}]}];
        _ -> []
    end.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

discovery(Config) ->
    Agent = connect(Config),
    Card = barrel_a2a_client:card(Agent),
    ?assertEqual(<<"Test Agent">>, barrel_a2a_agent_card:name(Card)),
    ?assertMatch([_], barrel_a2a_client:skills(Agent)),
    ?assert(barrel_a2a_agent_card:supports(Card, streaming)),
    ?assert(barrel_a2a_agent_card:supports(Card, extended_agent_card)),
    ?assertNot(barrel_a2a_agent_card:supports(Card, push_notifications)),
    Interfaces = barrel_a2a_agent_card:interfaces(Card),
    ?assertEqual(
        [<<"JSONRPC">>, <<"HTTP+JSON">>],
        [maps:get(<<"protocolBinding">>, I) || I <- Interfaces]
    ),
    ?assertEqual(ok, barrel_a2a_validate:agent_card(Card)),
    ?assertEqual(ok, barrel_a2a_schema:validate(<<"AgentCard">>, Card)).

card_caching(Config) ->
    Url = raw_url(Config, barrel_a2a:well_known_card_path()),
    {ok, 200, Headers, _} = hackney:request(get, Url, [], <<>>, [with_body | hackney_opts(Config)]),
    ETag = proplists:get_value(<<"etag">>, Headers),
    ?assert(is_binary(ETag)),
    ?assertMatch(
        <<"public, max-age=", _/binary>>, proplists:get_value(<<"cache-control">>, Headers)
    ),
    {ok, 304, _, _} = hackney:request(
        get, Url, [{<<"if-none-match">>, ETag}], <<>>, [with_body | hackney_opts(Config)]
    ),
    {ok, 200, HeadHeaders} = hackney:request(head, Url, [], <<>>, hackney_opts(Config)),
    ?assertEqual(ETag, proplists:get_value(<<"etag">>, HeadHeaders)).

request_response(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: hello">>),
    ?assertEqual(completed, barrel_a2a_task:state(Task)),
    [Artifact] = barrel_a2a_task:artifacts(Task),
    ?assertEqual(<<"hello">>, barrel_a2a_artifact:text(Artifact)),
    ?assertMatch([_], barrel_a2a_task:history(Task)),
    ?assertEqual(ok, barrel_a2a_schema:validate(<<"Task">>, Task)),
    {ok, Fetched} = barrel_a2a_client:get_task(Agent, barrel_a2a_task:id(Task)),
    ?assertEqual(barrel_a2a_task:id(Task), barrel_a2a_task:id(Fetched)),
    ?assertMatch({error, #{type := task_not_found}}, barrel_a2a_client:get_task(Agent, <<"nope">>)).

direct_message(Config) ->
    Agent = connect(Config),
    {ok, {message, M}} = barrel_a2a_client:send(Agent, <<"direct">>),
    ?assertEqual(<<"direct reply">>, barrel_a2a_message:text(M)),
    ?assertEqual(agent, barrel_a2a_message:role(M)),
    ?assertEqual(undefined, barrel_a2a_message:task_id(M)),
    ?assert(barrel_a2a_message:context_id(M) =/= undefined),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"direct">>),
    ?assertMatch({ok, {message, _}}, barrel_a2a_remote_task:result(RT, 5000)).

long_running(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"slow 300">>, #{return_immediately => true}),
    ?assert(lists:member(barrel_a2a_task:state(Task), [submitted, working])),
    Id = barrel_a2a_task:id(Task),
    Final = poll_until(Agent, Id, completed, 50),
    ?assertEqual(<<"done">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Final)))).

poll_until(_Agent, _Id, _State, 0) ->
    ct:fail(poll_timeout);
poll_until(Agent, Id, State, N) ->
    {ok, Task} = barrel_a2a_client:get_task(Agent, Id),
    case barrel_a2a_task:state(Task) of
        State ->
            Task;
        _ ->
            timer:sleep(100),
            poll_until(Agent, Id, State, N - 1)
    end.

streaming_order(Config) ->
    Agent = connect(Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"stream">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    {Events, {done, Final}} = collect_events(RT),
    ?assertEqual(task, hd(kinds(Events))),
    ?assertEqual(
        [task, status_update, artifact_update, artifact_update, status_update], kinds(Events)
    ),
    ?assertEqual([working, completed], states(Events)),
    [#{<<"artifactUpdate">> := First}, #{<<"artifactUpdate">> := Second}] = [
        E
     || E <- Events, barrel_a2a_event:kind(E) =:= artifact_update
    ],
    ?assertEqual(false, maps:get(<<"append">>, First)),
    ?assertEqual(true, maps:get(<<"append">>, Second)),
    ?assertEqual(true, maps:get(<<"lastChunk">>, Second)),
    ?assertEqual(completed, barrel_a2a_task:state(Final)),
    [A] = barrel_a2a_task:artifacts(Final),
    ?assertEqual(<<"part one part two">>, barrel_a2a_artifact:text(A)),
    ?assertEqual(<<"part one part two">>, barrel_a2a_remote_task:text(RT)),
    lists:foreach(
        fun(E) -> ?assertEqual(ok, barrel_a2a_schema:validate(<<"StreamResponse">>, E)) end, Events
    ).

streaming_subscribe(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"slow 800">>, #{return_immediately => true}),
    Id = barrel_a2a_task:id(Task),
    {ok, RT} = barrel_a2a_client:subscribe(Agent, Id),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    {Events, {done, Final}} = collect_events(RT),
    ?assertEqual(task, hd(kinds(Events))),
    ?assertEqual(completed, barrel_a2a_task:state(Final)),
    ?assertMatch(
        {error, #{type := unsupported_operation}},
        barrel_a2a_client:call(Agent, subscribe_to_task, #{<<"id">> => Id})
    ),
    {ok, RT2} = barrel_a2a_client:subscribe(Agent, Id),
    ?assertMatch({ok, _}, barrel_a2a_remote_task:result(RT2, 1000)).

artifacts(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"data">>),
    [A] = barrel_a2a_task:artifacts(Task),
    [P1, P2, P3] = barrel_a2a_artifact:parts(A),
    ?assertEqual(#{<<"answer">> => 42}, barrel_a2a_part:data_of(P1)),
    ?assertEqual(<<"https://example.com/report.pdf">>, barrel_a2a_part:url_of(P2)),
    ?assertEqual(<<1, 2, 3>>, barrel_a2a_part:bytes_of(P3)),
    ?assertEqual(<<"b.bin">>, barrel_a2a_part:filename(P3)),
    ?assertEqual(ok, barrel_a2a_schema:validate(<<"Artifact">>, A)),
    Msg = barrel_a2a_message:new([
        barrel_a2a_part:text(<<"echo: multi">>), barrel_a2a_part:data(#{<<"k">> => 1})
    ]),
    {ok, {task, T2}} = barrel_a2a_client:send(Agent, Msg),
    ?assertEqual(completed, barrel_a2a_task:state(T2)).

cancellation(Config) ->
    Agent = connect(Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"cancel-me">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    receive
        {a2a_event, RT, #{
            <<"statusUpdate">> := #{<<"status">> := #{<<"state">> := <<"TASK_STATE_WORKING">>}}
        }} ->
            ok
    after 5000 -> ct:fail(no_working_event)
    end,
    {ok, Task} = barrel_a2a_remote_task:cancel(RT),
    ?assertEqual(canceled, barrel_a2a_task:state(Task)),
    {_Events, Outcome} = collect_events(RT),
    ?assertMatch({done, _}, Outcome),
    ?assertMatch(
        {ok, handle_cancel_called}, wait_sink(fun(M) -> M =:= handle_cancel_called end, 2000)
    ),
    %% A second cancel is idempotent on a canceled task.
    ?assertMatch({ok, _}, barrel_a2a_client:cancel(Agent, barrel_a2a_task:id(Task))).

remote_failure(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"fail">>),
    ?assertEqual(failed, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"boom">>, barrel_a2a_message:text(barrel_a2a_task:status_message(Task))),
    {ok, {task, Rejected}} = barrel_a2a_client:send(Agent, <<"reject">>),
    ?assertEqual(rejected, barrel_a2a_task:state(Rejected)).

handler_crash(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"crash">>),
    ?assertEqual(failed, barrel_a2a_task:state(Task)),
    %% The server is still healthy.
    {ok, {task, T2}} = barrel_a2a_client:send(Agent, <<"echo: still alive">>),
    ?assertEqual(completed, barrel_a2a_task:state(T2)).

handler_protocol_error(Config) ->
    Agent = connect(Config),
    ?assertMatch(
        {error, #{type := content_type_not_supported}}, barrel_a2a_client:send(Agent, <<"throw">>)
    ),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"throw">>),
    ?assertMatch(
        {error, #{type := content_type_not_supported}}, barrel_a2a_remote_task:result(RT, 5000)
    ).

client_timeout(Config) ->
    Agent = connect(Config, #{timeout => 300, retries => 0}),
    Result = barrel_a2a_client:send(Agent, <<"slow 2000">>),
    ?assertMatch({error, #{type := T}} when T =:= timeout; T =:= transport, Result),
    %% The server still answers afterwards.
    Agent2 = connect(Config),
    ?assertMatch({ok, {task, _}}, barrel_a2a_client:send(Agent2, <<"echo: ok">>)).

follow_up_input_required(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"ask">>),
    ?assertEqual(input_required, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"more?">>, barrel_a2a_message:text(barrel_a2a_task:status_message(Task))),
    Id = barrel_a2a_task:id(Task),
    Ctx = barrel_a2a_task:context_id(Task),
    {ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"here you go">>, #{
        task_id => Id, context_id => Ctx
    }),
    ?assertEqual(completed, barrel_a2a_task:state(Done)),
    ?assertEqual(
        <<"thanks: here you go">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Done)))
    ),
    ?assertEqual(3, length(barrel_a2a_task:history(Done))),
    %% Wrong contextId is rejected; terminal task refuses messages.
    ?assertMatch(
        {error, #{type := invalid_params}},
        barrel_a2a_client:send(Agent, <<"x">>, #{task_id => Id, context_id => <<"other">>})
    ),
    ?assertMatch(
        {error, #{type := unsupported_operation}},
        barrel_a2a_client:send(Agent, <<"x">>, #{task_id => Id})
    ),
    %% Same flow through the remote task handle.
    {ok, RT} = barrel_a2a_client:start(Agent, <<"ask">>),
    {ok, Paused} = barrel_a2a_remote_task:result(RT, 5000),
    ?assertEqual(input_required, barrel_a2a_task:state(Paused)),
    ok = barrel_a2a_remote_task:send(RT, <<"second">>),
    {ok, Final} = barrel_a2a_remote_task:result(RT, 5000),
    ?assertEqual(completed, barrel_a2a_task:state(Final)).

auth_required_resume(Config) ->
    Agent = connect(Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"auth">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    {ok, {ctx, Ctx}} = wait_sink(
        fun
            ({ctx, _}) -> true;
            (_) -> false
        end,
        5000
    ),
    receive
        {a2a_event, RT, #{
            <<"statusUpdate">> := #{
                <<"status">> := #{<<"state">> := <<"TASK_STATE_AUTH_REQUIRED">>}
            }
        }} ->
            ok
    after 5000 -> ct:fail(no_auth_required_event)
    end,
    {ok, Paused} = barrel_a2a_remote_task:result(RT, 5000),
    ?assertEqual(auth_required, barrel_a2a_task:state(Paused)),
    %% The out-of-band credential arrives: the agent resumes without a
    %% client message, and a subscriber sees the continuation.
    {ok, RT2} = barrel_a2a_client:subscribe(Agent, barrel_a2a_task:id(Paused)),
    ok = barrel_a2a_remote_task:stream_to(RT2, self()),
    %% Two snapshots arrive: one from the GetTask the handle does on
    %% attach, one from the subscription itself once it is live.
    lists:foreach(
        fun(_) ->
            receive
                {a2a_event, RT2, #{<<"task">> := _}} -> ok
            after 5000 -> ct:fail(no_snapshot_on_subscribe)
            end
        end,
        [1, 2]
    ),
    ok = barrel_a2a_ctx:resume(Ctx),
    {Events, {done, Final}} = collect_events(RT2),
    ?assert(lists:member(working, states(Events))),
    ?assertEqual(completed, barrel_a2a_task:state(Final)).

list_tasks_filters(Config) ->
    Agent = connect(Config),
    CtxId = barrel_a2a_id:uuid(),
    {ok, {task, T1}} = barrel_a2a_client:send(Agent, <<"echo: a">>, #{context_id => CtxId}),
    timer:sleep(5),
    {ok, {task, T2}} = barrel_a2a_client:send(Agent, <<"echo: b">>, #{context_id => CtxId}),
    {ok, {task, _T3}} = barrel_a2a_client:send(Agent, <<"ask">>),
    {ok, #{tasks := Tasks, next_page_token := <<>>}} = barrel_a2a_client:list_tasks(Agent, #{
        context_id => CtxId
    }),
    ?assertEqual([barrel_a2a_task:id(T2), barrel_a2a_task:id(T1)], [
        barrel_a2a_task:id(T)
     || T <- Tasks
    ]),
    %% Artifacts omitted unless asked for.
    ?assertNot(maps:is_key(<<"artifacts">>, hd(Tasks))),
    {ok, #{tasks := [WithArt | _]}} = barrel_a2a_client:list_tasks(Agent, #{
        context_id => CtxId, include_artifacts => true
    }),
    ?assert(maps:is_key(<<"artifacts">>, WithArt)),
    {ok, #{tasks := Paused}} = barrel_a2a_client:list_tasks(Agent, #{status => input_required}),
    ?assert(lists:all(fun(T) -> barrel_a2a_task:state(T) =:= input_required end, Paused)),
    ?assert(length(Paused) >= 1),
    {ok, #{tasks := Page1, next_page_token := Token}} = barrel_a2a_client:list_tasks(Agent, #{
        context_id => CtxId, page_size => 1
    }),
    ?assertEqual(1, length(Page1)),
    ?assert(Token =/= <<>>),
    {ok, #{tasks := Page2, next_page_token := <<>>}} = barrel_a2a_client:list_tasks(Agent, #{
        context_id => CtxId, page_size => 1, page_token => Token
    }),
    ?assertEqual([barrel_a2a_task:id(T1)], [barrel_a2a_task:id(T) || T <- Page2]),
    ?assertMatch(
        {error, #{type := invalid_params}},
        barrel_a2a_client:list_tasks(Agent, #{page_token => <<"garbage">>})
    ).

list_tasks_scoping(Config) ->
    %% A second server with bearer auth: tasks are visible to their
    %% owner only, and reads of foreign tasks answer not found.
    Auth =
        {bearer, fun
            (<<"alice">>) -> {ok, alice};
            (<<"bob">>) -> {ok, bob};
            (_) -> {error, unauthenticated}
        end},
    {ok, Server} = start_server(#{auth => Auth}),
    try
        Prefer = ?config(prefer, Config),
        Url = barrel_a2a_server:url(Server),
        {ok, Alice} = barrel_a2a_client:connect(Url, #{
            prefer => Prefer, auth => {bearer, <<"alice">>}
        }),
        {ok, Bob} = barrel_a2a_client:connect(Url, #{prefer => Prefer, auth => {bearer, <<"bob">>}}),
        {ok, {task, TA}} = barrel_a2a_client:send(Alice, <<"principal">>),
        ?assertEqual(<<"alice">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(TA)))),
        {ok, {task, _TB}} = barrel_a2a_client:send(Bob, <<"echo: b">>),
        {ok, #{tasks := AliceTasks}} = barrel_a2a_client:list_tasks(Alice, #{}),
        ?assertEqual([barrel_a2a_task:id(TA)], [barrel_a2a_task:id(T) || T <- AliceTasks]),
        ?assertMatch(
            {error, #{type := task_not_found}},
            barrel_a2a_client:get_task(Bob, barrel_a2a_task:id(TA))
        ),
        ?assertMatch(
            {error, #{type := task_not_found}},
            barrel_a2a_client:cancel(Bob, barrel_a2a_task:id(TA))
        )
    after
        barrel_a2a_server:stop(Server)
    end.

auth_hook(Config) ->
    Auth =
        {bearer, fun
            (<<"secret">>) -> {ok, #{user => <<"u1">>}};
            (<<"banned">>) -> {error, forbidden};
            (_) -> {error, unauthenticated}
        end},
    {ok, Server} = start_server(#{auth => Auth}),
    try
        Prefer = ?config(prefer, Config),
        Url = barrel_a2a_server:url(Server),
        %% The card is public.
        {ok, Anon} = barrel_a2a_client:connect(Url, #{prefer => Prefer}),
        ?assertMatch(
            {error, #{type := unauthenticated}}, barrel_a2a_client:send(Anon, <<"echo: x">>)
        ),
        {ok, Bad} = barrel_a2a_client:connect(Url, #{
            prefer => Prefer, auth => {bearer, <<"wrong">>}
        }),
        ?assertMatch(
            {error, #{type := unauthenticated}}, barrel_a2a_client:send(Bad, <<"echo: x">>)
        ),
        {ok, Banned} = barrel_a2a_client:connect(Url, #{
            prefer => Prefer, auth => {bearer, <<"banned">>}
        }),
        ?assertMatch(
            {error, #{type := permission_denied}}, barrel_a2a_client:send(Banned, <<"echo: x">>)
        ),
        {ok, Good} = barrel_a2a_client:connect(Url, #{
            prefer => Prefer, auth => {bearer, <<"secret">>}
        }),
        {ok, {task, T}} = barrel_a2a_client:send(Good, <<"principal">>),
        ?assertEqual(
            <<"#{user => <<\"u1\">>}">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T)))
        ),
        %% Raw check of the 401 challenge on the wire.
        {ok, Status, Headers, _} = raw_send(Url, Prefer, [], <<"echo: x">>),
        ?assertEqual(401, Status),
        ?assertMatch(<<"Bearer", _/binary>>, proplists:get_value(<<"www-authenticate">>, Headers))
    after
        barrel_a2a_server:stop(Server)
    end.

raw_send(Url, [jsonrpc], Headers0, Text) ->
    Headers = with_version(Headers0),
    Body = barrel_a2a_json:encode(
        barrel_a2a_jsonrpc:request(1, <<"SendMessage">>, #{
            <<"message">> => barrel_a2a_message:new(Text)
        })
    ),
    hackney:request(
        post,
        <<Url/binary, "/a2a/jsonrpc">>,
        [{<<"content-type">>, <<"application/json">>} | Headers],
        Body,
        [with_body]
    );
raw_send(Url, _, Headers0, Text) ->
    Headers = with_version(Headers0),
    Body = barrel_a2a_json:encode(#{<<"message">> => barrel_a2a_message:new(Text)}),
    hackney:request(
        post,
        <<Url/binary, "/a2a/v1/message:send">>,
        [{<<"content-type">>, <<"application/a2a+json">>} | Headers],
        Body,
        [with_body]
    ).

%% Raw requests default to the current version unless the test sets one.
with_version(Headers) ->
    case lists:keymember(<<"a2a-version">>, 1, Headers) of
        true -> Headers;
        false -> [{<<"a2a-version">>, <<"1.0">>} | Headers]
    end.

v1() -> {<<"a2a-version">>, <<"1.0">>}.

%% The extended card is served to an authenticated caller only, and the
%% hook sees the principal that asked for it.
extended_card(Config) ->
    Auth =
        {bearer, fun
            (<<"alice">>) -> {ok, alice};
            (_) -> {error, unauthenticated}
        end},
    {ok, Server} = start_server(#{auth => Auth}),
    try
        Prefer = ?config(prefer, Config),
        Url = barrel_a2a_server:url(Server),
        {ok, Alice} = barrel_a2a_client:connect(Url, #{
            prefer => Prefer, auth => {bearer, <<"alice">>}
        }),
        {ok, Agent2} = barrel_a2a_client:extended_card(Alice),
        ?assertEqual(<<"Extended">>, barrel_a2a_agent_card:name(barrel_a2a_client:card(Agent2))),
        ?assertEqual(<<"alice">>, barrel_a2a_agent_card:description(barrel_a2a_client:card(Agent2)))
    after
        barrel_a2a_server:stop(Server)
    end.

%% A server with no authentication has no authenticated caller, so it
%% cannot serve the extended card at all.
extended_card_needs_auth(Config) ->
    Agent = connect(Config),
    ?assertMatch(
        {error, #{type := unauthenticated}}, barrel_a2a_client:extended_card(Agent)
    ).

extensions(Config) ->
    Agent = connect(Config, #{
        extensions => [<<"https://example.com/ext/one">>, <<"https://example.com/unknown">>]
    }),
    {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"extensions">>),
    ?assertEqual(
        <<"https://example.com/ext/one">>,
        barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T)))
    ),
    %% The response echoes the active set.
    Url = barrel_a2a_server:url(?config(server, Config)),
    {ok, 200, Headers, _} = raw_send(
        Url,
        ?config(prefer, Config),
        [{<<"a2a-extensions">>, <<"https://example.com/ext/two, https://example.com/nope">>}],
        <<"echo: x">>
    ),
    ?assertEqual(
        <<"https://example.com/ext/two">>, proplists:get_value(<<"a2a-extensions">>, Headers)
    ),
    %% A required extension the client does not request is an error.
    Card = barrel_a2a_test_agent:card(#{
        capabilities => #{extensions => [#{uri => <<"https://example.com/req">>, required => true}]}
    }),
    {ok, Server} = barrel_a2a_server:start(Card, #{
        handler => barrel_a2a_test_agent, http => #{port => 0}
    }),
    try
        {ok, A} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), #{
            prefer => ?config(prefer, Config)
        }),
        ?assertMatch(
            {error, #{type := extension_support_required}}, barrel_a2a_client:send(A, <<"echo: x">>)
        ),
        {ok, B} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), #{
            prefer => ?config(prefer, Config), extensions => [<<"https://example.com/req">>]
        }),
        ?assertMatch({ok, {task, _}}, barrel_a2a_client:send(B, <<"echo: x">>))
    after
        barrel_a2a_server:stop(Server)
    end.

version_error(Config) ->
    Agent = connect(Config, #{version => <<"0.3">>}),
    ?assertMatch(
        {error, #{type := version_not_supported}}, barrel_a2a_client:send(Agent, <<"echo: x">>)
    ),
    Url = barrel_a2a_server:url(?config(server, Config)),
    {ok, Status, _, Body} = raw_send(
        Url, ?config(prefer, Config), [{<<"a2a-version">>, <<"2.0">>}], <<"echo: x">>
    ),
    {ok, Decoded} = barrel_a2a_json:decode(Body),
    case ?config(prefer, Config) of
        [jsonrpc] ->
            ?assertEqual(200, Status),
            ?assertMatch(#{<<"error">> := #{<<"code">> := -32009}}, Decoded);
        _ ->
            ?assertEqual(400, Status),
            ?assertMatch(
                #{
                    <<"error">> := #{
                        <<"code">> := 400,
                        <<"details">> := [#{<<"reason">> := <<"VERSION_NOT_SUPPORTED">>} | _]
                    }
                },
                Decoded
            )
    end,
    %% Legacy acceptance is opt-in.
    {ok, Server} = start_server(#{accept_legacy_version => true}),
    try
        {ok, A} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), #{
            prefer => ?config(prefer, Config), version => <<"0.3">>
        }),
        ?assertMatch({ok, {task, _}}, barrel_a2a_client:send(A, <<"echo: x">>))
    after
        barrel_a2a_server:stop(Server)
    end.

client_disconnect_mid_stream(Config) ->
    Agent = connect(Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"slow 1000">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    receive
        {a2a_event, RT, #{<<"task">> := Task}} ->
            Id = barrel_a2a_task:id(Task),
            barrel_a2a_remote_task:stop(RT),
            %% The task completes regardless of the lost subscriber.
            Final = poll_until(Agent, Id, completed, 50),
            ?assertEqual(completed, barrel_a2a_task:state(Final))
    after 5000 -> ct:fail(no_task_event)
    end.

push_notifications(Config) ->
    {Webhook, Port} = barrel_a2a_test_agent:webhook_server(self()),
    {ok, Server} = start_server(#{
        push_notifications => #{ssrf_guard => false, timeout => 2000, backoff => {50, 2}}
    }),
    try
        Prefer = ?config(prefer, Config),
        {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), #{prefer => Prefer}),
        ?assert(barrel_a2a_agent_card:supports(barrel_a2a_client:card(Agent), push_notifications)),
        WebhookUrl = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/hook">>,
        PushCfg = #{
            url => WebhookUrl,
            token => <<"tok-1">>,
            authentication => #{scheme => <<"Bearer">>, credentials => <<"hook-secret">>}
        },
        %% Config attached at send time.
        {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"stream">>, #{
            push_notification_config => PushCfg
        }),
        Id = barrel_a2a_task:id(T),
        Events = collect_webhooks([]),
        ?assert(length(Events) >= 3),
        {Headers, First} = hd(Events),
        ?assertEqual(<<"Bearer hook-secret">>, proplists:get_value(<<"authorization">>, Headers)),
        ?assertEqual(<<"tok-1">>, proplists:get_value(<<"x-a2a-notification-token">>, Headers)),
        ?assertMatch(
            <<"application/a2a+json", _/binary>>, proplists:get_value(<<"content-type">>, Headers)
        ),
        ?assertEqual(task, barrel_a2a_event:kind(First)),
        Last = element(2, lists:last(Events)),
        ?assert(barrel_a2a_event:is_final(Last)),
        ?assertEqual(Id, barrel_a2a_event:task_id(Last)),
        %% The receiver helper validates the same headers.
        ?assertMatch(
            {ok, _},
            barrel_a2a_webhook:receive_notification(Headers, barrel_a2a_json:encode(First), #{
                token => <<"tok-1">>, authorization => <<"Bearer hook-secret">>, task_ids => [Id]
            })
        ),
        ?assertMatch(
            {error, unauthenticated},
            barrel_a2a_webhook:receive_notification(Headers, barrel_a2a_json:encode(First), #{
                token => <<"other">>
            })
        ),
        %% CRUD on a long-running task.
        {ok, {task, T2}} = barrel_a2a_client:send(Agent, <<"slow 1500">>, #{
            return_immediately => true
        }),
        Id2 = barrel_a2a_task:id(T2),
        {ok, Created} = barrel_a2a_client:create_push_config(Agent, Id2, #{url => WebhookUrl}),
        CfgId = maps:get(<<"id">>, Created),
        ?assertEqual(Id2, maps:get(<<"taskId">>, Created)),
        {ok, Got} = barrel_a2a_client:get_push_config(Agent, Id2, CfgId),
        ?assertEqual(WebhookUrl, maps:get(<<"url">>, Got)),
        {ok, #{configs := [_]}} = barrel_a2a_client:list_push_configs(Agent, Id2, #{}),
        ok = barrel_a2a_client:delete_push_config(Agent, Id2, CfgId),
        ok = barrel_a2a_client:delete_push_config(Agent, Id2, CfgId),
        ?assertMatch(
            {error, #{type := task_not_found}}, barrel_a2a_client:get_push_config(Agent, Id2, CfgId)
        ),
        {ok, #{configs := []}} = barrel_a2a_client:list_push_configs(Agent, Id2, #{}),
        ?assertMatch(
            {error, #{type := task_not_found}},
            barrel_a2a_client:create_push_config(Agent, <<"nope">>, #{url => WebhookUrl})
        )
    after
        barrel_a2a_server:stop(Server),
        barrel_a2a_test_agent:webhook_stop(Webhook)
    end,
    %% Without the capability every push operation is refused.
    Agent0 = connect(Config),
    ?assertMatch(
        {error, #{type := push_notification_not_supported}},
        barrel_a2a_client:list_push_configs(Agent0, <<"x">>, #{})
    ).

collect_webhooks(Acc) ->
    receive
        {webhook, Headers, Body} ->
            {ok, Ev} = barrel_a2a_json:decode(Body),
            Acc1 = Acc ++ [{Headers, Ev}],
            case barrel_a2a_event:is_final(Ev) of
                true -> Acc1;
                false -> collect_webhooks(Acc1)
            end
    after 5000 -> Acc
    end.

push_ssrf_rejected(Config) ->
    {ok, Server} = start_server(#{push_notifications => #{}}),
    try
        {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), #{
            prefer => ?config(prefer, Config)
        }),
        {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"slow 500">>, #{
            return_immediately => true
        }),
        Id = barrel_a2a_task:id(T),
        lists:foreach(
            fun(Url) ->
                ?assertMatch(
                    {error, #{type := invalid_params}},
                    barrel_a2a_client:create_push_config(Agent, Id, #{url => Url})
                )
            end,
            [
                <<"http://10.0.0.1/hook">>,
                <<"http://127.0.0.1/hook">>,
                <<"http://localhost/hook">>,
                <<"ftp://example.com/x">>,
                <<"http://169.254.169.254/latest">>
            ]
        )
    after
        barrel_a2a_server:stop(Server)
    end.

content_type_not_supported(Config) ->
    Agent = connect(Config),
    Msg = barrel_a2a_message:new([barrel_a2a_part:file_url(<<"https://x/y.mp4">>, <<"video/mp4">>)]),
    ?assertMatch(
        {error, #{type := content_type_not_supported}}, barrel_a2a_client:send(Agent, Msg)
    ),
    Png = barrel_a2a_message:new([barrel_a2a_part:file_url(<<"https://x/y.png">>, <<"image/png">>)]),
    ?assertMatch({ok, {task, _}}, barrel_a2a_client:send(Agent, Png)),
    ?assertMatch(
        {error, #{type := content_type_not_supported}},
        barrel_a2a_client:send(Agent, <<"echo: x">>, #{accepted_output_modes => [<<"audio/mpeg">>]})
    ),
    ?assertMatch(
        {ok, {task, _}},
        barrel_a2a_client:send(Agent, <<"echo: x">>, #{accepted_output_modes => [<<"text/*">>]})
    ).

malformed_request(Config) ->
    Url = barrel_a2a_server:url(?config(server, Config)),
    HOpts = hackney_opts(Config),
    case ?config(prefer, Config) of
        [jsonrpc] ->
            J = <<Url/binary, "/a2a/jsonrpc">>,
            {ok, 400, _, B1} = hackney:request(
                post, J, [v1(), {<<"content-type">>, <<"application/json">>}], <<"{not json">>, [
                    with_body | HOpts
                ]
            ),
            ?assertMatch(#{<<"error">> := #{<<"code">> := -32700}}, decode(B1)),
            {ok, 400, _, B2} = hackney:request(
                post, J, [v1(), {<<"content-type">>, <<"application/json">>}], <<"[1,2]">>, [
                    with_body | HOpts
                ]
            ),
            ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, decode(B2)),
            {ok, 200, _, B3} = hackney:request(
                post,
                J,
                [v1(), {<<"content-type">>, <<"application/json">>}],
                <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Nope\"}">>,
                [with_body | HOpts]
            ),
            ?assertMatch(#{<<"error">> := #{<<"code">> := -32601}}, decode(B3)),
            {ok, 200, _, B4} = hackney:request(
                post,
                J,
                [v1(), {<<"content-type">>, <<"application/json">>}],
                <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":{\"message\":{\"role\":\"ROLE_USER\"}}}">>,
                [with_body | HOpts]
            ),
            ?assertMatch(
                #{<<"error">> := #{<<"code">> := -32602, <<"data">> := [_ | _]}}, decode(B4)
            ),
            {ok, 415, _, _} = hackney:request(
                post, J, [v1(), {<<"content-type">>, <<"text/plain">>}], <<"x">>, [
                    with_body | HOpts
                ]
            ),
            {ok, 405, _, _} = hackney:request(get, J, [v1()], <<>>, [with_body | HOpts]);
        _ ->
            R = <<Url/binary, "/a2a/v1">>,
            {ok, 400, _, B1} = hackney:request(
                post,
                <<R/binary, "/message:send">>,
                [v1(), {<<"content-type">>, <<"application/a2a+json">>}],
                <<"{not json">>,
                [with_body | HOpts]
            ),
            ?assertMatch(#{<<"error">> := #{<<"code">> := 400}}, decode(B1)),
            {ok, 400, _, B2} = hackney:request(
                post,
                <<R/binary, "/message:send">>,
                [v1(), {<<"content-type">>, <<"application/a2a+json">>}],
                <<"{\"message\":{\"role\":\"ROLE_USER\"}}">>,
                [with_body | HOpts]
            ),
            ?assertMatch(#{<<"error">> := #{<<"details">> := [_ | _]}}, decode(B2)),
            {ok, 404, _, B3} = hackney:request(get, <<R/binary, "/nothing">>, [v1()], <<>>, [
                with_body | HOpts
            ]),
            ?assertMatch(#{<<"error">> := #{<<"code">> := 404}}, decode(B3)),
            {ok, 405, H4, _} = hackney:request(delete, <<R/binary, "/tasks">>, [v1()], <<>>, [
                with_body | HOpts
            ]),
            ?assertEqual(<<"GET">>, proplists:get_value(<<"allow">>, H4)),
            {ok, 415, _, _} = hackney:request(
                post,
                <<R/binary, "/message:send">>,
                [v1(), {<<"content-type">>, <<"text/plain">>}],
                <<"x">>,
                [with_body | HOpts]
            ),
            {ok, 404, _, B5} = hackney:request(get, <<R/binary, "/tasks/nope">>, [v1()], <<>>, [
                with_body | HOpts
            ]),
            ?assertMatch(
                #{
                    <<"error">> := #{
                        <<"status">> := <<"NOT_FOUND">>,
                        <<"details">> := [#{<<"reason">> := <<"TASK_NOT_FOUND">>} | _]
                    }
                },
                decode(B5)
            ),
            %% `resource:verb' is a custom method: an unknown verb is no
            %% route, and a known one reached with the wrong method names
            %% the method that serves it.
            {ok, 404, _, B6} = hackney:request(
                post, <<R/binary, "/tasks/x:frobnicate">>, [v1()], <<>>, [with_body | HOpts]
            ),
            ?assertMatch(
                #{
                    <<"error">> := #{
                        <<"code">> := 404,
                        <<"details">> := [#{<<"reason">> := <<"METHOD_NOT_FOUND">>} | _]
                    }
                },
                decode(B6)
            ),
            {ok, 405, H7, _} = hackney:request(
                get, <<R/binary, "/tasks/x:cancel">>, [v1()], <<>>, [with_body | HOpts]
            ),
            ?assertEqual(<<"POST">>, proplists:get_value(<<"allow">>, H7))
    end.

decode(Body) ->
    {ok, D} = barrel_a2a_json:decode(Body),
    D.

signed_card(Config) ->
    Key = barrel_a2a_card_sign:generate_key('ES256'),
    Jwk = barrel_a2a_card_sign:jwk(Key),
    Kid = maps:get(<<"kid">>, Jwk),
    {ok, Server} = start_server(#{signing => #{key => Key, alg => 'ES256', kid => Kid}}),
    try
        Prefer = ?config(prefer, Config),
        Url = barrel_a2a_server:url(Server),
        {ok, Agent} = barrel_a2a_client:connect(Url, #{
            prefer => Prefer, verify_signatures => #{keys => [Jwk], required => true}
        }),
        ?assertMatch([_], barrel_a2a_agent_card:signatures(barrel_a2a_client:card(Agent))),
        Other = barrel_a2a_card_sign:jwk(barrel_a2a_card_sign:generate_key('ES256'), Kid),
        ?assertMatch(
            {error, #{type := unauthenticated}},
            barrel_a2a_client:connect(Url, #{
                prefer => Prefer, verify_signatures => #{keys => [Other], required => true}
            })
        ),
        %% An unsigned server is refused when signatures are required.
        Unsigned = barrel_a2a_server:url(?config(server, Config)),
        ?assertMatch(
            {error, #{type := unauthenticated}},
            barrel_a2a_client:connect(Unsigned, #{
                prefer => Prefer, verify_signatures => #{keys => [Jwk], required => true}
            })
        ),
        ?assertMatch(
            {ok, _},
            barrel_a2a_client:connect(Unsigned, #{
                prefer => Prefer, verify_signatures => #{keys => [Jwk]}
            })
        )
    after
        barrel_a2a_server:stop(Server)
    end.

history_length(Config) ->
    Agent = connect(Config),
    {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"ask">>),
    Id = barrel_a2a_task:id(T),
    {ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"more">>, #{
        task_id => Id, history_length => 1
    }),
    ?assertEqual(1, length(barrel_a2a_task:history(Done))),
    {ok, All} = barrel_a2a_client:get_task(Agent, Id),
    ?assertEqual(3, length(barrel_a2a_task:history(All))),
    {ok, None} = barrel_a2a_client:get_task(Agent, Id, #{history_length => 0}),
    ?assertNot(maps:is_key(<<"history">>, None)),
    {ok, Two} = barrel_a2a_client:get_task(Agent, Id, #{history_length => 2}),
    ?assertEqual(2, length(barrel_a2a_task:history(Two))).

tenant_mismatch(Config) ->
    Agent = connect(Config),
    Interface = barrel_a2a_client:interface(Agent),
    ?assertEqual(<<"acme">>, maps:get(<<"tenant">>, Interface)),
    {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"tenant">>),
    ?assertEqual(<<"<<\"acme\">>">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T)))),
    %% A request naming another tenant, or none, is rejected.
    ?assertMatch(
        {error, #{type := invalid_params}},
        barrel_a2a_client:call(Agent, get_task, #{<<"id">> => <<"x">>, <<"tenant">> => <<"other">>})
    ),
    Url = barrel_a2a_server:url(?config(server, Config)),
    Body = barrel_a2a_json:encode(#{<<"message">> => barrel_a2a_message:new(<<"echo: x">>)}),
    {ok, 400, _, _} = hackney:request(
        post,
        <<Url/binary, "/a2a/v1/message:send">>,
        [v1(), {<<"content-type">>, <<"application/a2a+json">>}],
        Body,
        [with_body]
    ),
    %% The tenant path prefix works as well as the field.
    {ok, 200, _, _} = hackney:request(
        post,
        <<Url/binary, "/a2a/v1/acme/message:send">>,
        [v1(), {<<"content-type">>, <<"application/a2a+json">>}],
        Body,
        [with_body]
    ).

%% Follow-ups pile up while a handler runs. Past `max_task_queue' the
%% send is refused rather than queued without limit, and the task still
%% finishes with every message that was accepted.
follow_up_queue_is_bounded(Config) ->
    {ok, Server} = start_server(#{max_task_queue => 2}),
    try
        Prefer = ?config(prefer, Config),
        {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server), #{
            prefer => Prefer, timeout => 10000
        }),
        {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"slow 1500">>, #{
            return_immediately => true
        }),
        Id = barrel_a2a_task:id(Task),
        Ctx = barrel_a2a_task:context_id(Task),
        Send = fun(Text) ->
            barrel_a2a_client:send(Agent, Text, #{
                task_id => Id, context_id => Ctx, return_immediately => true
            })
        end,
        %% Two fit behind the running handler; the third does not.
        ?assertMatch({ok, _}, Send(<<"echo: one">>)),
        ?assertMatch({ok, _}, Send(<<"echo: two">>)),
        ?assertMatch({error, #{type := rate_limited}}, Send(<<"echo: three">>)),
        %% The queue drains and the task still finishes.
        Final = poll_until(Agent, Id, completed, 100),
        ?assertEqual(completed, barrel_a2a_task:state(Final))
    after
        barrel_a2a_server:stop(Server)
    end.
