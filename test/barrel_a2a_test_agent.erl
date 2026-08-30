%%%-------------------------------------------------------------------
%%% @doc The agent used by the end-to-end suites. Behaviour is chosen
%%% by the text of the incoming message.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_test_agent).

-behaviour(barrel_a2a_handler).

-export([handle_message/2, handle_cancel/1]).
-export([card/0, card/1, webhook_server/1, webhook_stop/1]).

card() -> card(#{}).

card(Extra) ->
    barrel_a2a_agent_card:new(
        maps:merge(
            #{
                name => <<"Test Agent">>,
                description => <<"Agent used by the barrel_a2a test suites">>,
                version => <<"1.2.3">>,
                default_input_modes => [<<"text/plain">>, <<"application/json">>],
                default_output_modes => [<<"text/plain">>, <<"application/json">>],
                skills => [
                    #{
                        id => <<"echo">>,
                        name => <<"Echo">>,
                        description => <<"Echoes text back">>,
                        tags => [<<"test">>],
                        input_modes => [<<"text/plain">>, <<"image/png">>]
                    }
                ]
            },
            Extra
        )
    ).

handle_message(Ctx, Message) ->
    Text = barrel_a2a_message:text(Message),
    case barrel_a2a_ctx:is_follow_up(Ctx) of
        true ->
            {ok, <<"thanks: ", Text/binary>>};
        false ->
            dispatch(Text, Ctx, Message)
    end.

dispatch(<<"echo: ", Rest/binary>>, _Ctx, _Message) ->
    {ok, Rest};
dispatch(<<"direct">>, _Ctx, _Message) ->
    {message, barrel_a2a_message:agent(<<"direct reply">>)};
dispatch(<<"stream">>, Ctx, _Message) ->
    ok = barrel_a2a_ctx:status(Ctx, working, #{message => <<"starting">>}),
    ok = barrel_a2a_ctx:artifact(Ctx, <<"part one ">>, #{artifact_id => <<"a1">>, name => <<"out">>}),
    ok = barrel_a2a_ctx:artifact(Ctx, <<"part two">>, #{
        artifact_id => <<"a1">>, append => true, last_chunk => true
    }),
    ok;
dispatch(<<"slow ", Ms/binary>>, _Ctx, _Message) ->
    timer:sleep(binary_to_integer(Ms)),
    {ok, <<"done">>};
dispatch(<<"cancel-me">>, Ctx, _Message) ->
    ok = barrel_a2a_ctx:status(Ctx, working),
    wait_cancel(Ctx, 200);
dispatch(<<"fail">>, _Ctx, _Message) ->
    {error, <<"boom">>};
dispatch(<<"crash">>, _Ctx, _Message) ->
    error(deliberate_crash);
dispatch(<<"throw">>, _Ctx, _Message) ->
    throw({a2a_error, barrel_a2a_error:new(content_type_not_supported, <<"nope">>)});
dispatch(<<"ask">>, _Ctx, _Message) ->
    {input_required, <<"more?">>};
dispatch(<<"auth">>, Ctx, _Message) ->
    notify_sink({ctx, Ctx}),
    {auth_required, <<"please log in">>};
dispatch(<<"reject">>, _Ctx, _Message) ->
    {reject, <<"no">>};
dispatch(<<"data">>, Ctx, _Message) ->
    Parts = [
        barrel_a2a_part:data(#{<<"answer">> => 42}),
        barrel_a2a_part:file_url(<<"https://example.com/report.pdf">>, <<"application/pdf">>),
        barrel_a2a_part:file_bytes(<<1, 2, 3>>, <<"application/octet-stream">>, #{
            filename => <<"b.bin">>
        })
    ],
    ok = barrel_a2a_ctx:artifact(Ctx, Parts, #{name => <<"data">>}),
    ok;
dispatch(<<"principal">>, Ctx, _Message) ->
    {ok, iolist_to_binary(io_lib:format("~0p", [barrel_a2a_ctx:principal(Ctx)]))};
dispatch(<<"extensions">>, Ctx, _Message) ->
    {ok, iolist_to_binary(lists:join(<<",">>, barrel_a2a_ctx:extensions(Ctx)))};
dispatch(<<"tenant">>, Ctx, _Message) ->
    {ok, iolist_to_binary(io_lib:format("~0p", [barrel_a2a_ctx:tenant(Ctx)]))};
dispatch(Other, _Ctx, _Message) ->
    {ok, <<"unknown: ", Other/binary>>}.

wait_cancel(_Ctx, 0) ->
    {ok, <<"never cancelled">>};
wait_cancel(Ctx, N) ->
    case barrel_a2a_ctx:cancelled(Ctx) of
        true ->
            notify_sink(cancelled_seen),
            ok;
        false ->
            timer:sleep(50),
            wait_cancel(Ctx, N - 1)
    end.

handle_cancel(_Ctx) ->
    notify_sink(handle_cancel_called),
    ok.

notify_sink(Msg) ->
    case whereis(a2a_test_sink) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.

%% A minimal webhook receiver on h1: every POST body is decoded and
%% sent to `Sink' as `{webhook, Headers, Body}'; replies 200.
webhook_server(Sink) ->
    Handler = fun(Conn, Sid, _Method, _Path, Headers) ->
        Body = read_body(Sid, <<>>),
        Sink ! {webhook, Headers, Body},
        h1:respond(Conn, Sid, 200, [{<<"content-length">>, <<"0">>}], <<>>)
    end,
    {ok, Server} = h1:start_server(0, #{transport => tcp, handler => Handler}),
    {Server, h1:server_port(Server)}.

webhook_stop({Server, _}) ->
    h1:stop_server(Server);
webhook_stop(Server) ->
    h1:stop_server(Server).

read_body(Sid, Acc) ->
    receive
        {h1_stream, Sid, {data, Bin, true}} -> <<Acc/binary, Bin/binary>>;
        {h1_stream, Sid, {data, Bin, false}} -> read_body(Sid, <<Acc/binary, Bin/binary>>);
        {h1_stream, Sid, {trailers, _}} -> Acc;
        {h1_stream, Sid, {stream_reset, _}} -> Acc
    after 5000 -> Acc
    end.
