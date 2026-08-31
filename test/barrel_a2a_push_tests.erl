-module(barrel_a2a_push_tests).

-include_lib("eunit/include/eunit.hrl").

-define(URL, <<"https://example.com/hook">>).
-define(TASK, <<"task-1">>).

%% Validation without a network: the allowlist bypasses resolution.
opts() ->
    #{allow => [<<"example.com">>]}.

config() ->
    config(?URL).

config(Url) ->
    #{<<"url">> => Url, <<"token">> => <<"tok">>}.

status_event(State) ->
    barrel_a2a_event:status_update(?TASK, <<"ctx">>, #{<<"state">> => State}).

%%--------------------------------------------------------------------
%% Store
%%--------------------------------------------------------------------

create_assigns_id_test() ->
    Store = barrel_a2a_push:new_store(),
    {ok, C} = barrel_a2a_push:create(
        Store, ?TASK, (config())#{<<"id">> => <<"client-id">>}, opts()
    ),
    Id = maps:get(<<"id">>, C),
    ?assert(barrel_a2a_id:is_uuid(Id)),
    ?assertEqual(?TASK, maps:get(<<"taskId">>, C)),
    ?assertEqual({ok, C}, barrel_a2a_push:get(Store, ?TASK, Id)),
    ?assertEqual(error, barrel_a2a_push:get(Store, <<"other">>, Id)).

create_rejects_missing_url_test() ->
    Store = barrel_a2a_push:new_store(),
    {error, E} = barrel_a2a_push:create(Store, ?TASK, #{}, opts()),
    ?assertEqual(invalid_params, barrel_a2a_error:type(E)).

create_rejects_bad_url_test() ->
    Store = barrel_a2a_push:new_store(),
    {error, E} = barrel_a2a_push:create(Store, ?TASK, config(<<"ftp://example.com/x">>), opts()),
    ?assertEqual(invalid_params, barrel_a2a_error:type(E)),
    ?assertEqual([], element(2, barrel_a2a_push:list(Store, ?TASK, undefined, undefined))).

list_pagination_test() ->
    Store = barrel_a2a_push:new_store(),
    Ids = [
        maps:get(<<"id">>, element(2, barrel_a2a_push:create(Store, ?TASK, config(), opts())))
     || _ <- lists:seq(1, 5)
    ],
    {ok, _} = barrel_a2a_push:create(Store, <<"other">>, config(), opts()),
    {ok, P1, T1} = barrel_a2a_push:list(Store, ?TASK, 2, undefined),
    ?assertEqual(2, length(P1)),
    ?assertNotEqual(<<>>, T1),
    {ok, P2, T2} = barrel_a2a_push:list(Store, ?TASK, 2, T1),
    ?assertEqual(2, length(P2)),
    {ok, P3, T3} = barrel_a2a_push:list(Store, ?TASK, 2, T2),
    ?assertEqual(1, length(P3)),
    ?assertEqual(<<>>, T3),
    Seen = [maps:get(<<"id">>, C) || C <- P1 ++ P2 ++ P3],
    ?assertEqual(lists:sort(Ids), Seen),
    {ok, All, <<>>} = barrel_a2a_push:list(Store, ?TASK, undefined, undefined),
    ?assertEqual(5, length(All)),
    ?assertEqual(
        {error, invalid_page_token}, barrel_a2a_push:list(Store, ?TASK, 2, <<"not a token">>)
    ).

delete_idempotent_test() ->
    Store = barrel_a2a_push:new_store(),
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, config(), opts()),
    Id = maps:get(<<"id">>, C),
    ?assertEqual(ok, barrel_a2a_push:delete(Store, ?TASK, Id)),
    ?assertEqual(error, barrel_a2a_push:get(Store, ?TASK, Id)),
    ?assertEqual(ok, barrel_a2a_push:delete(Store, ?TASK, Id)),
    ?assertEqual(ok, barrel_a2a_push:delete(Store, ?TASK, <<"never">>)).

delete_task_test() ->
    Store = barrel_a2a_push:new_store(),
    {ok, _} = barrel_a2a_push:create(Store, ?TASK, config(), opts()),
    {ok, _} = barrel_a2a_push:create(Store, ?TASK, config(), opts()),
    {ok, Keep} = barrel_a2a_push:create(Store, <<"other">>, config(), opts()),
    ?assertEqual(ok, barrel_a2a_push:delete_task(Store, ?TASK)),
    ?assertEqual({ok, [], <<>>}, barrel_a2a_push:list(Store, ?TASK, undefined, undefined)),
    ?assertEqual(
        {ok, [Keep], <<>>}, barrel_a2a_push:list(Store, <<"other">>, undefined, undefined)
    ).

%%--------------------------------------------------------------------
%% validate_url
%%--------------------------------------------------------------------

validate_url_test_() ->
    Blocked = fun(Url) ->
        {Url, ?_assertMatch({error, _}, barrel_a2a_push:validate_url(Url, #{}))}
    end,
    [
        Blocked(<<"http://10.0.0.1/hook">>),
        Blocked(<<"http://172.16.5.5/hook">>),
        Blocked(<<"http://192.168.1.1/hook">>),
        Blocked(<<"http://127.0.0.1/hook">>),
        Blocked(<<"http://0.0.0.0/hook">>),
        Blocked(<<"http://169.254.169.254/latest">>),
        Blocked(<<"http://localhost:8080/hook">>),
        Blocked(<<"http://foo.localhost/hook">>),
        Blocked(<<"http://[::1]/hook">>),
        Blocked(<<"http://[fe80::1]/hook">>),
        Blocked(<<"http://[::ffff:127.0.0.1]/hook">>),
        Blocked(<<"http://user:pw@example.com/hook">>),
        {"bad scheme",
            ?_assertEqual(
                {error, <<"url scheme must be http or https">>},
                barrel_a2a_push:validate_url(<<"ftp://example.com/x">>, #{})
            )},
        {"relative", ?_assertMatch({error, _}, barrel_a2a_push:validate_url(<<"/hook">>, #{}))},
        {"no host", ?_assertMatch({error, _}, barrel_a2a_push:validate_url(<<"http:///x">>, #{}))},
        {"not a binary", ?_assertMatch({error, _}, barrel_a2a_push:validate_url(42, #{}))},
        {"require https",
            ?_assertEqual(
                {error, <<"url scheme must be https">>},
                barrel_a2a_push:validate_url(<<"http://8.8.8.8/hook">>, #{require_https => true})
            )},
        {"public ip literal",
            ?_assertEqual(
                ok, barrel_a2a_push:validate_url(<<"https://8.8.8.8/hook">>, #{})
            )},
        {"good https, allowlisted",
            ?_assertEqual(
                ok, barrel_a2a_push:validate_url(?URL, #{allow => [<<"EXAMPLE.com">>]})
            )},
        {"allow fun",
            ?_assertEqual(
                ok,
                barrel_a2a_push:validate_url(<<"http://127.0.0.1/hook">>, #{
                    allow => fun(H) -> H =:= <<"127.0.0.1">> end
                })
            )},
        {"allow fun says no",
            ?_assertMatch(
                {error, _},
                barrel_a2a_push:validate_url(<<"http://127.0.0.1/hook">>, #{
                    allow => fun(_) -> false end
                })
            )},
        {"allowlist does not bypass https",
            ?_assertMatch(
                {error, _},
                barrel_a2a_push:validate_url(<<"http://127.0.0.1/hook">>, #{
                    allow => [<<"127.0.0.1">>], require_https => true
                })
            )},
        {"guard off",
            ?_assertEqual(
                ok,
                barrel_a2a_push:validate_url(<<"http://127.0.0.1/hook">>, #{ssrf_guard => false})
            )}
    ].

%%--------------------------------------------------------------------
%% Delivery worker (http_post override)
%%--------------------------------------------------------------------

%% A scripted HTTP client: each call takes the next result from the
%% script (the last one repeats) and reports the call to the test.
script(Results) ->
    Tab = ets:new(script, [public]),
    true = ets:insert(Tab, {n, 0}),
    Test = self(),
    fun(Url, Headers, Body) ->
        N = ets:update_counter(Tab, n, 1),
        {ok, Event} = barrel_a2a_json:decode(Body),
        Test ! {posted, N, Url, Headers, Event},
        lists:nth(min(N, length(Results)), Results)
    end.

worker_opts(Post) ->
    #{
        http_post => Post,
        backoff => {10, 2},
        max_backoff => 50,
        max_failures => 3,
        allow => [<<"example.com">>]
    }.

wait_posted() ->
    receive
        {posted, N, Url, Headers, Event} -> {N, Url, Headers, Event}
    after 2000 -> error(no_post)
    end.

%% Monitor before triggering the exit so a fast worker is not missed.
wait_down(Pid, Ref) ->
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    after 2000 -> error(still_alive)
    end.

ordered_delivery_test() ->
    Store = barrel_a2a_push:new_store(),
    Opts = worker_opts(script([{ok, 200}])),
    Cfg = (config())#{
        <<"authentication">> => #{<<"scheme">> => <<"Bearer">>, <<"credentials">> => <<"abc">>}
    },
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, Cfg, Opts),
    {ok, Pid} = barrel_a2a_push_delivery:start_link(C, Opts, Store),
    Events = [status_event(<<"TASK_STATE_WORKING">>) || _ <- [1, 2, 3]],
    [barrel_a2a_push_delivery:deliver(Pid, E) || E <- Events],
    Got = [wait_posted() || _ <- Events],
    ?assertEqual([1, 2, 3], [N || {N, _, _, _} <- Got]),
    {1, ?URL, Headers, Ev} = hd(Got),
    ?assertEqual(hd(Events), Ev),
    ?assertEqual(
        <<"application/a2a+json">>, proplists:get_value(<<"Content-Type">>, Headers)
    ),
    ?assertEqual(<<"Bearer abc">>, proplists:get_value(<<"Authorization">>, Headers)),
    ?assertEqual(<<"tok">>, proplists:get_value(<<"X-A2A-Notification-Token">>, Headers)),
    ?assert(is_process_alive(Pid)),
    Mon = monitor(process, Pid),
    barrel_a2a_push_delivery:stop(Pid),
    ?assertEqual(normal, wait_down(Pid, Mon)).

retry_then_success_test() ->
    Store = barrel_a2a_push:new_store(),
    Opts = worker_opts(script([{error, econnrefused}, {ok, 503}, {ok, 204}])),
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, config(), Opts),
    {ok, Pid} = barrel_a2a_push_delivery:start_link(C, Opts, Store),
    Event = status_event(<<"TASK_STATE_WORKING">>),
    barrel_a2a_push_delivery:deliver(Pid, Event),
    ?assertMatch({1, _, _, Event}, wait_posted()),
    ?assertMatch({2, _, _, Event}, wait_posted()),
    ?assertMatch({3, _, _, Event}, wait_posted()),
    %% The second event is queued behind the retries and goes out once.
    Next = status_event(<<"TASK_STATE_WORKING">>),
    barrel_a2a_push_delivery:deliver(Pid, Next),
    ?assertMatch({4, _, _, _}, wait_posted()),
    ?assert(is_process_alive(Pid)),
    ?assertMatch({ok, _}, barrel_a2a_push:get(Store, ?TASK, maps:get(<<"id">>, C))),
    Mon = monitor(process, Pid),
    barrel_a2a_push_delivery:stop(Pid),
    ?assertEqual(normal, wait_down(Pid, Mon)).

give_up_after_max_failures_test() ->
    Store = barrel_a2a_push:new_store(),
    Opts = worker_opts(script([{ok, 500}])),
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, config(), Opts),
    Id = maps:get(<<"id">>, C),
    {ok, Pid} = barrel_a2a_push_delivery:start_link(C, Opts, Store),
    Mon = monitor(process, Pid),
    barrel_a2a_push_delivery:deliver(Pid, status_event(<<"TASK_STATE_WORKING">>)),
    ?assertEqual([1, 2, 3], [element(1, wait_posted()) || _ <- [1, 2, 3]]),
    ?assertEqual(normal, wait_down(Pid, Mon)),
    ?assertEqual(error, barrel_a2a_push:get(Store, ?TASK, Id)),
    receive
        {posted, _, _, _, _} -> error(too_many_posts)
    after 100 -> ok
    end.

final_event_stops_worker_test() ->
    Store = barrel_a2a_push:new_store(),
    Opts = worker_opts(script([{ok, 200}])),
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, config(), Opts),
    Id = maps:get(<<"id">>, C),
    {ok, Pid} = barrel_a2a_push_delivery:start_link(C, Opts, Store),
    Mon = monitor(process, Pid),
    barrel_a2a_push_delivery:deliver(Pid, status_event(<<"TASK_STATE_WORKING">>)),
    barrel_a2a_push_delivery:deliver(Pid, status_event(<<"TASK_STATE_COMPLETED">>)),
    ?assertMatch({1, _, _, _}, wait_posted()),
    ?assertMatch({2, _, _, _}, wait_posted()),
    ?assertEqual(normal, wait_down(Pid, Mon)),
    ?assertEqual(error, barrel_a2a_push:get(Store, ?TASK, Id)).

notify_starts_worker_per_config_test() ->
    {ok, Sup} = barrel_a2a_push_sup:start_link(),
    Store = barrel_a2a_push:new_store(),
    Opts = (worker_opts(script([{ok, 200}])))#{sup => Sup},
    {ok, C1} = barrel_a2a_push:create(Store, ?TASK, config(<<"https://example.com/a">>), Opts),
    {ok, C2} = barrel_a2a_push:create(Store, ?TASK, config(<<"https://example.com/b">>), Opts),
    ok = barrel_a2a_push:notify(Store, ?TASK, status_event(<<"TASK_STATE_WORKING">>)),
    Urls = lists:sort([element(2, wait_posted()), element(2, wait_posted())]),
    ?assertEqual([<<"https://example.com/a">>, <<"https://example.com/b">>], Urls),
    [{{worker, _}, W1}, {{worker, _}, W2}] = lists:sort(
        ets:match_object(Store, {{worker, '_'}, '_'})
    ),
    ?assertEqual(2, length(supervisor:which_children(Sup))),
    %% A second notify reuses the workers.
    ok = barrel_a2a_push:notify(Store, ?TASK, status_event(<<"TASK_STATE_WORKING">>)),
    _ = wait_posted(),
    _ = wait_posted(),
    ?assertEqual(2, length(supervisor:which_children(Sup))),
    %% The final event stops both and removes the configs.
    M1 = monitor(process, W1),
    M2 = monitor(process, W2),
    ok = barrel_a2a_push:notify(Store, ?TASK, status_event(<<"TASK_STATE_COMPLETED">>)),
    _ = wait_posted(),
    _ = wait_posted(),
    ?assertEqual(normal, wait_down(W1, M1)),
    ?assertEqual(normal, wait_down(W2, M2)),
    ?assertEqual(error, barrel_a2a_push:get(Store, ?TASK, maps:get(<<"id">>, C1))),
    ?assertEqual(error, barrel_a2a_push:get(Store, ?TASK, maps:get(<<"id">>, C2))),
    ?assertEqual([], ets:match_object(Store, {{worker, '_'}, '_'})),
    unlink(Sup),
    exit(Sup, shutdown).

delete_stops_worker_test() ->
    Store = barrel_a2a_push:new_store(),
    Opts = worker_opts(script([{ok, 200}])),
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, config(), Opts),
    Id = maps:get(<<"id">>, C),
    ok = barrel_a2a_push:notify(Store, ?TASK, status_event(<<"TASK_STATE_WORKING">>)),
    _ = wait_posted(),
    [{_, Pid}] = ets:lookup(Store, {worker, Id}),
    Mon = monitor(process, Pid),
    ok = barrel_a2a_push:delete(Store, ?TASK, Id),
    ?assertEqual(normal, wait_down(Pid, Mon)),
    ?assertEqual([], ets:lookup(Store, {worker, Id})).

%%--------------------------------------------------------------------
%% Real HTTP round trip with hackney
%%--------------------------------------------------------------------

post_over_network_test_() ->
    {timeout, 30, fun post_over_network/0}.

post_over_network() ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(h1),
    Test = self(),
    Handler = fun(Conn, Id, Method, Path, Hs) ->
        Body = collect_body(Id, <<>>),
        Test ! {request, Method, Path, Hs, Body},
        ok = h1:respond(Conn, Id, 200, [], <<>>)
    end,
    {ok, Ref} = h1:start_server(0, #{transport => tcp, handler => Handler}),
    try
        Port = h1:server_port(Ref),
        Url = iolist_to_binary(["http://127.0.0.1:", integer_to_binary(Port), "/hook"]),
        Cfg = #{
            <<"url">> => Url,
            <<"token">> => <<"secret">>,
            <<"authentication">> => #{<<"scheme">> => <<"Bearer">>, <<"credentials">> => <<"t">>}
        },
        Event = status_event(<<"TASK_STATE_WORKING">>),
        ?assertEqual(ok, barrel_a2a_push_delivery:post(Cfg, Event, #{ssrf_guard => false})),
        receive
            {request, Method, Path, Hs, Body} ->
                ?assertEqual(<<"POST">>, Method),
                ?assertEqual(<<"/hook">>, Path),
                Lower = [{string:lowercase(K), V} || {K, V} <- Hs],
                ?assertEqual(
                    <<"application/a2a+json">>, proplists:get_value(<<"content-type">>, Lower)
                ),
                ?assertEqual(<<"Bearer t">>, proplists:get_value(<<"authorization">>, Lower)),
                ?assertEqual(
                    <<"secret">>, proplists:get_value(<<"x-a2a-notification-token">>, Lower)
                ),
                ?assertEqual({ok, Event}, barrel_a2a_json:decode(Body))
        after 5000 ->
            error(no_request)
        end
    after
        h1:stop_server(Ref)
    end.

collect_body(Id, Acc) ->
    receive
        {h1_stream, Id, {data, Chunk, true}} -> <<Acc/binary, Chunk/binary>>;
        {h1_stream, Id, {data, Chunk, false}} -> collect_body(Id, <<Acc/binary, Chunk/binary>>);
        {h1_stream, Id, {trailers, _}} -> Acc
    after 5000 -> Acc
    end.

%% An event carrying a distinguishable marker, so a test can tell which
%% ones survived a bounded queue.
tagged_event(Tag) ->
    barrel_a2a_event:status_update(?TASK, <<"ctx">>, #{
        <<"state">> => <<"TASK_STATE_WORKING">>, <<"timestamp">> => Tag
    }).

tag_of(Event) ->
    #{<<"statusUpdate">> := #{<<"status">> := #{<<"timestamp">> := Tag}}} = Event,
    Tag.

%% A webhook slow enough to back up loses the oldest events, not the
%% newest, and a drop is not a delivery failure: the worker survives and
%% keeps its configuration.
full_queue_drops_oldest_test() ->
    Store = barrel_a2a_push:new_store(),
    Opts = (worker_opts(script([{error, econnrefused}, {ok, 204}])))#{
        max_queue => 2, backoff => {300, 2}, max_backoff => 300
    },
    {ok, C} = barrel_a2a_push:create(Store, ?TASK, config(), Opts),
    {ok, Pid} = barrel_a2a_push_delivery:start_link(C, Opts, Store),
    %% The first delivery fails, so the worker is in backoff holding it.
    barrel_a2a_push_delivery:deliver(Pid, tagged_event(<<"e1">>)),
    ?assertEqual(<<"e1">>, tag_of(element(4, wait_posted()))),
    %% These pile up behind it and push the queue past max_queue.
    [barrel_a2a_push_delivery:deliver(Pid, tagged_event(T)) || T <- [<<"e2">>, <<"e3">>, <<"e4">>]],
    %% Backoff expires: what comes out is the newest two, in order.
    ?assertEqual(<<"e3">>, tag_of(element(4, wait_posted()))),
    ?assertEqual(<<"e4">>, tag_of(element(4, wait_posted()))),
    ?assert(is_process_alive(Pid)),
    %% max_failures is 3 and only one real failure happened, so the
    %% configuration is still registered.
    ?assertMatch({ok, _}, barrel_a2a_push:get(Store, ?TASK, maps:get(<<"id">>, C))),
    Mon = monitor(process, Pid),
    barrel_a2a_push_delivery:stop(Pid),
    ?assertEqual(normal, wait_down(Pid, Mon)).
