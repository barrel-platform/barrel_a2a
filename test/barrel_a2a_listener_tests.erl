-module(barrel_a2a_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Fixtures
%%====================================================================

setup() ->
    setup(#{}).

setup(Extra) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    Opts = maps:merge(#{port => 0, ip => {127, 0, 0, 1}}, Extra),
    {ok, Pid} = barrel_a2a_listener:start_link(Opts, handler()),
    Port = barrel_a2a_listener:port(Pid),
    #{pid => Pid, port => Port, opts => Extra}.

cleanup(#{pid := Pid}) ->
    unlink(Pid),
    ok = barrel_a2a_listener:stop(Pid).

%% eunit runs setup and each test in different processes, so the
%% handler reports through a registered name the test claims.
-define(WAITER, barrel_a2a_listener_test_waiter).

handler() ->
    fun(Method, Path, Headers, Body, R) ->
        #{
            reply := Reply,
            stream_start := StreamStart,
            stream_chunk := StreamChunk,
            stream_end := StreamEnd,
            disconnected := Disconnected
        } = R,
        case Path of
            <<"/stream">> ->
                ok = StreamStart(200, [{<<"content-type">>, <<"text/event-stream">>}]),
                _ = [ok = StreamChunk(<<"data: n\n\n">>) || _ <- lists:seq(1, 3)],
                ok = StreamEnd();
            <<"/crash">> ->
                error(boom);
            <<"/wait">> ->
                wait_disconnect(Disconnected),
                ?WAITER ! disconnected_seen;
            _ ->
                Json = barrel_a2a_json:encode(#{
                    <<"method">> => Method,
                    <<"path">> => Path,
                    <<"body">> => Body,
                    <<"scheme">> => proplists:get_value(<<"x-a2a-scheme">>, Headers),
                    <<"host">> => proplists:get_value(<<"host">>, Headers, null)
                }),
                Reply(200, [{<<"content-type">>, <<"application/json">>}], Json)
        end
    end.

wait_disconnect(Disconnected) ->
    receive
        Msg ->
            case Disconnected(Msg) of
                true -> ok;
                false -> wait_disconnect(Disconnected)
            end
    end.

url(#{port := Port}, Path) ->
    "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path.

%%====================================================================
%% Cleartext
%%====================================================================

cleartext_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            {"port/1 returns the bound port", ?_assert(maps:get(port, Ctx) > 0)},
            {"echo", fun() -> echo(Ctx) end},
            {"get without body", fun() -> get_no_body(Ctx) end},
            {"stream", fun() -> stream(Ctx) end},
            {"crash gives 500", fun() -> crash(Ctx) end},
            {"disconnect seen by handler", fun() -> disconnect(Ctx) end}
        ]
    end}.

echo(Ctx) ->
    {ok, 200, Headers, Body} = hackney:request(
        post, url(Ctx, "/echo"), [{<<"content-type">>, <<"text/plain">>}], <<"hello">>, []
    ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Headers)),
    ?assertEqual(
        integer_to_binary(byte_size(Body)), proplists:get_value(<<"content-length">>, Headers)
    ),
    {ok, Json} = barrel_a2a_json:decode(Body),
    ?assertEqual(<<"POST">>, maps:get(<<"method">>, Json)),
    ?assertEqual(<<"/echo">>, maps:get(<<"path">>, Json)),
    ?assertEqual(<<"hello">>, maps:get(<<"body">>, Json)),
    ?assertEqual(<<"http">>, maps:get(<<"scheme">>, Json)),
    ?assertMatch(<<"127.0.0.1", _/binary>>, maps:get(<<"host">>, Json)).

get_no_body(Ctx) ->
    {ok, 200, _Headers, Body} = hackney:request(get, url(Ctx, "/x"), [], <<>>, []),
    {ok, Json} = barrel_a2a_json:decode(Body),
    ?assertEqual(<<"GET">>, maps:get(<<"method">>, Json)),
    ?assertEqual(<<>>, maps:get(<<"body">>, Json)).

stream(Ctx) ->
    {ok, Ref} = hackney:request(get, url(Ctx, "/stream"), [], <<>>, [async]),
    {Status, Headers, Chunks} = collect_async(Ref, undefined, undefined, []),
    ?assertEqual(200, Status),
    ?assertEqual(<<"text/event-stream">>, proplists:get_value(<<"content-type">>, Headers)),
    ?assertEqual(undefined, proplists:get_value(<<"content-length">>, Headers)),
    ?assertEqual(
        <<"data: n\n\ndata: n\n\ndata: n\n\n">>, iolist_to_binary(lists:reverse(Chunks))
    ).

collect_async(Ref, Status, Headers, Acc) ->
    receive
        {hackney_response, Ref, {status, S, _Reason}} ->
            collect_async(Ref, S, Headers, Acc);
        {hackney_response, Ref, {headers, H}} ->
            collect_async(Ref, Status, H, Acc);
        {hackney_response, Ref, done} ->
            {Status, Headers, Acc};
        {hackney_response, Ref, {error, Reason}} ->
            error({async_error, Reason});
        {hackney_response, Ref, Bin} when is_binary(Bin) ->
            collect_async(Ref, Status, Headers, [Bin | Acc])
    after 5000 ->
        error({async_timeout, Status, Headers, Acc})
    end.

crash(Ctx) ->
    {ok, 500, _Headers, Body} = hackney:request(get, url(Ctx, "/crash"), [], <<>>, []),
    ?assertEqual(<<"Internal Server Error">>, Body).

disconnect(#{port := Port}) ->
    true = register(?WAITER, self()),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(Sock, <<"GET /wait HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    timer:sleep(200),
    ok = gen_tcp:close(Sock),
    receive
        disconnected_seen -> ok
    after 5000 ->
        error(disconnect_not_seen)
    end.

%%====================================================================
%% Body limit
%%====================================================================

max_body_test_() ->
    {setup, fun() -> setup(#{max_body => 16}) end, fun cleanup/1, fun(Ctx) ->
        [
            {"small body is accepted", fun() ->
                {ok, 200, _, _} = hackney:request(post, url(Ctx, "/e"), [], <<"short">>, [])
            end},
            {"body over max_body gives 413", fun() ->
                Big = binary:copy(<<"x">>, 100),
                {ok, Status, _, _} = hackney:request(post, url(Ctx, "/e"), [], Big, []),
                ?assertEqual(413, Status)
            end}
        ]
    end}.

%%====================================================================
%% Connection limit
%%====================================================================

max_connections_test_() ->
    {setup, fun() -> setup(#{max_connections => 1}) end, fun cleanup/1, fun(#{port := Port}) ->
        [
            {"connections over the limit are closed", fun() ->
                true = register(?WAITER, self()),
                {ok, S1} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
                ok = gen_tcp:send(S1, <<"GET /wait HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
                timer:sleep(100),
                {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
                ?assertEqual({error, closed}, gen_tcp:recv(S2, 0, 2000)),
                ok = gen_tcp:close(S1),
                receive
                    disconnected_seen -> ok
                after 5000 ->
                    error(disconnect_not_seen)
                end,
                %% The slot is released once the first connection ends.
                timer:sleep(100),
                {ok, 200, _, _} = hackney:request(
                    get, "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/e", [], <<>>, []
                )
            end}
        ]
    end}.

%%====================================================================
%% child_spec
%%====================================================================

child_spec_test() ->
    Handler = fun(_, _, _, _, _) -> ok end,
    Spec = barrel_a2a_listener:child_spec(my_id, #{port => 0}, Handler),
    ?assertMatch(
        #{
            id := my_id,
            start := {barrel_a2a_listener, start_link, [#{port := 0}, Handler]},
            restart := transient,
            type := worker
        },
        Spec
    ).

%%====================================================================
%% TLS
%%====================================================================

tls_test_() ->
    {setup,
        fun() ->
            Certs = barrel_a2a_test_tls:make_certs(),
            Tls = maps:with([certfile, keyfile, cacertfile], Certs),
            Ctx = setup(#{tls => Tls}),
            Ctx#{certs => Certs}
        end,
        fun(#{certs := #{dir := Dir}} = Ctx) ->
            cleanup(Ctx),
            _ = file:del_dir_r(Dir)
        end,
        fun(Ctx) ->
            [
                {"hackney over TLS speaks HTTP/1.1", fun() -> tls_h1(Ctx) end},
                {"h2 client over ALPN speaks HTTP/2", fun() -> tls_h2(Ctx) end}
            ]
        end}.

tls_h1(#{port := Port, certs := #{cacertfile := CaFile}}) ->
    Url = "https://localhost:" ++ integer_to_list(Port) ++ "/echo",
    {ok, 200, _Headers, Body} = hackney:request(
        post, Url, [], <<"secure">>, [
            {protocols, [http1]},
            {ssl_options, [{verify, verify_peer}, {cacertfile, CaFile}]},
            {pool, false}
        ]
    ),
    {ok, Json} = barrel_a2a_json:decode(Body),
    ?assertEqual(<<"POST">>, maps:get(<<"method">>, Json)),
    ?assertEqual(<<"secure">>, maps:get(<<"body">>, Json)),
    ?assertEqual(<<"https">>, maps:get(<<"scheme">>, Json)).

tls_h2(#{port := Port}) ->
    {ok, Conn} = h2:connect("localhost", Port, #{
        transport => ssl,
        ssl_opts => [{verify, verify_none}, {alpn_advertised_protocols, [<<"h2">>]}]
    }),
    %% The h2 client turns `host' into `:authority' and drops `host';
    %% the listener puts `host' back for the handler.
    Hdrs = [{<<"host">>, <<"localhost">>}],
    {ok, Sid} = h2:request(Conn, <<"POST">>, <<"/echo">>, Hdrs, <<"secure">>),
    {Status, Headers, Body} = collect_h2(Conn, Sid, undefined, undefined, []),
    ?assertEqual(200, Status),
    ?assertEqual(
        <<"application/json">>, proplists:get_value(<<"content-type">>, Headers)
    ),
    {ok, Json} = barrel_a2a_json:decode(Body),
    ?assertEqual(<<"POST">>, maps:get(<<"method">>, Json)),
    ?assertEqual(<<"secure">>, maps:get(<<"body">>, Json)),
    ?assertEqual(<<"https">>, maps:get(<<"scheme">>, Json)),
    ?assertMatch(<<"localhost", _/binary>>, maps:get(<<"host">>, Json)),
    ok = h2:close(Conn).

collect_h2(Conn, Sid, Status, Headers, Acc) ->
    receive
        {h2, Conn, {response, Sid, S, H}} ->
            collect_h2(Conn, Sid, S, H, Acc);
        {h2, Conn, {data, Sid, Data, true}} ->
            {Status, Headers, iolist_to_binary(lists:reverse([Data | Acc]))};
        {h2, Conn, {data, Sid, Data, false}} ->
            collect_h2(Conn, Sid, Status, Headers, [Data | Acc]);
        {h2, Conn, {trailers, Sid, _}} ->
            {Status, Headers, iolist_to_binary(lists:reverse(Acc))}
    after 5000 ->
        error({h2_timeout, Status, Headers, Acc})
    end.
