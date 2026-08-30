%%%-------------------------------------------------------------------
%%% @doc The HTTP engine: Agent Card, JSON-RPC and HTTP+JSON bindings
%%% over an abstract responder.
%%%
%%% {@link handle/6} runs in the process the transport spawned for the
%%% request. It never touches a socket: the responder carries the
%%% four write operations plus a predicate recognizing the transport's
%%% disconnect message, so the same engine serves the built-in
%%% `barrel_a2a_listener' and an embedding such as `livery_a2a'. A
%%% streaming response blocks in `receive' here until the task ends,
%%% the peer disconnects, or a write fails.
%%%
%%% Routes (see {@link routes/1}): the Agent Card at `card_path'
%%% (no authentication, cache headers per 8.6), JSON-RPC at
%%% `{base}/jsonrpc' (9), and the REST paths of 11.3 under
%%% `{base}/v1', optionally prefixed by `/{tenant}'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_http_engine).

-export([config/2, routes/1, handle/6]).
-export([sse_headers/0]).

-type responder() :: barrel_a2a_listener:responder().
-type config() :: #{
    server := pid(),
    base_path := binary(),
    card_path := binary(),
    card_cache_max_age := non_neg_integer(),
    hsts := boolean(),
    keepalive_ms := pos_integer(),
    tenant := binary() | undefined,
    principal => barrel_a2a:principal(),
    peer => term()
}.

-export_type([config/0, responder/0]).

-define(JSON, <<"application/json">>).

%%--------------------------------------------------------------------
%% Configuration
%%--------------------------------------------------------------------

%% @doc Build and validate an engine configuration. Raises
%% `{invalid_engine_option, Key, Value}' so a bad option fails once,
%% at mount time, rather than per request.
-spec config(pid(), map()) -> config().
config(Server, Overrides) ->
    Defaults = #{
        base_path => <<"/a2a">>,
        card_path => barrel_a2a:well_known_card_path(),
        card_cache_max_age => 3600,
        hsts => false,
        keepalive_ms => 15000,
        tenant => undefined
    },
    FromServer =
        case safe_config(Server) of
            #{engine := E} -> E;
            _ -> #{}
        end,
    Cfg = maps:merge(maps:merge(Defaults, FromServer), Overrides),
    lists:foreach(fun(K) -> check_option(K, maps:get(K, Cfg)) end, maps:keys(Defaults)),
    Cfg#{server => Server}.

check_option(base_path, V) when is_binary(V) -> ok;
check_option(card_path, <<"/", _/binary>>) -> ok;
check_option(card_cache_max_age, V) when is_integer(V), V >= 0 -> ok;
check_option(hsts, V) when is_boolean(V) -> ok;
check_option(keepalive_ms, V) when is_integer(V), V > 0 -> ok;
check_option(tenant, undefined) -> ok;
check_option(tenant, V) when is_binary(V) -> ok;
check_option(K, V) -> error({invalid_engine_option, K, V}).

%% @doc Every route the engine serves, in router pattern form.
-spec routes(config()) -> [{binary(), binary()}].
routes(#{base_path := Base, card_path := CardPath, tenant := Tenant}) ->
    Rest = barrel_a2a_rest:routes(<<Base/binary, "/v1">>),
    TenantRest =
        case Tenant of
            undefined -> [];
            T -> barrel_a2a_rest:routes(<<Base/binary, "/v1/", T/binary>>)
        end,
    [{<<"GET">>, CardPath}, {<<"HEAD">>, CardPath}, {<<"POST">>, <<Base/binary, "/jsonrpc">>}] ++
        [{M, P} || {M, P, _} <- Rest ++ TenantRest].

%%--------------------------------------------------------------------
%% Entry point
%%--------------------------------------------------------------------

-spec handle(binary(), binary(), [{binary(), binary()}], binary(), responder(), config()) -> ok.
handle(
    Method, RawPath, Headers0, Body, Responder, #{base_path := Base, card_path := CardPath} = Cfg
) ->
    Headers = [{string:lowercase(K), V} || {K, V} <- Headers0],
    {Path, Query} = split_query(RawPath),
    JsonRpc = <<Base/binary, "/jsonrpc">>,
    RestBase = <<Base/binary, "/v1">>,
    try
        case {Method, Path} of
            {M, CardPath} when M =:= <<"GET">>; M =:= <<"HEAD">> ->
                card(M, Headers, Responder, Cfg);
            {<<"POST">>, JsonRpc} ->
                jsonrpc(Headers, Query, Body, Responder, Cfg);
            {_, JsonRpc} ->
                reply_error(
                    rest, 405, [{<<"allow">>, <<"POST">>}], method_not_allowed(), Responder, Cfg
                );
            _ ->
                case is_prefix(RestBase, Path) of
                    true ->
                        rest(Method, Path, Headers, Query, Body, Responder, Cfg);
                    false ->
                        reply_error(
                            rest,
                            404,
                            [],
                            barrel_a2a_error:new(method_not_found, <<"No such route">>),
                            Responder,
                            Cfg
                        )
                end
        end
    catch
        Class:Reason:Stack ->
            logger:error("a2a engine crashed: ~0p:~0p~n~p", [Class, Reason, Stack]),
            try
                reply_error(rest, 500, [], barrel_a2a_error:new(internal_error), Responder, Cfg)
            catch
                _:_ -> ok
            end
    end.

is_prefix(Prefix, Path) ->
    Len = byte_size(Prefix),
    case Path of
        <<Prefix:Len/binary>> -> true;
        <<Prefix:Len/binary, $/, _/binary>> -> true;
        _ -> false
    end.

split_query(RawPath) ->
    case binary:split(RawPath, <<"?">>) of
        [P] -> {P, []};
        [P, Q] -> {P, parse_query(Q)}
    end.

parse_query(Q) ->
    case uri_string:dissect_query(Q) of
        {error, _, _} -> [];
        Pairs -> [{K, value(V)} || {K, V} <- Pairs]
    end.

value(true) -> <<>>;
value(V) -> V.

method_not_allowed() ->
    barrel_a2a_error:new(invalid_request, <<"Method not allowed">>).

%%--------------------------------------------------------------------
%% Agent Card (8.2, 8.6)
%%--------------------------------------------------------------------

card(Method, Headers, Responder, #{server := Server, card_cache_max_age := MaxAge} = Cfg) ->
    #{card_json := Json, card_etag := ETag} = barrel_a2a_server:config(Server),
    Base = [
        {<<"content-type">>, ?JSON},
        {<<"cache-control">>, <<"public, max-age=", (integer_to_binary(MaxAge))/binary>>},
        {<<"etag">>, ETag},
        {<<"last-modified">>, last_modified(Server)}
    ],
    Hdrs = common_headers(Base, Cfg),
    case matches_etag(header(<<"if-none-match">>, Headers), ETag) of
        true ->
            reply(Responder, 304, Hdrs, <<>>);
        false when Method =:= <<"HEAD">> ->
            reply(
                Responder,
                200,
                [{<<"content-length">>, integer_to_binary(byte_size(Json))} | Hdrs],
                <<>>
            );
        false ->
            reply(Responder, 200, Hdrs, Json)
    end.

matches_etag(undefined, _) ->
    false;
matches_etag(Value, ETag) ->
    Tags = [string:trim(T) || T <- binary:split(Value, <<",">>, [global])],
    lists:member(<<"*">>, Tags) orelse lists:member(ETag, Tags) orelse
        lists:member(<<"W/", ETag/binary>>, Tags).

last_modified(Server) ->
    Ms =
        case safe_config(Server) of
            #{started_ms := S} -> S;
            _ -> barrel_a2a_time:now_ms()
        end,
    rfc1123(calendar:system_time_to_universal_time(Ms div 1000, second)).

%% `Sun, 06 Nov 1994 08:49:37 GMT' (RFC 9110 IMF-fixdate).
rfc1123({{Y, Mo, D}, {H, Mi, S}}) ->
    Day = lists:nth(calendar:day_of_the_week(Y, Mo, D), [
        <<"Mon">>, <<"Tue">>, <<"Wed">>, <<"Thu">>, <<"Fri">>, <<"Sat">>, <<"Sun">>
    ]),
    Month = lists:nth(Mo, [
        <<"Jan">>,
        <<"Feb">>,
        <<"Mar">>,
        <<"Apr">>,
        <<"May">>,
        <<"Jun">>,
        <<"Jul">>,
        <<"Aug">>,
        <<"Sep">>,
        <<"Oct">>,
        <<"Nov">>,
        <<"Dec">>
    ]),
    iolist_to_binary(
        io_lib:format("~s, ~2..0b ~s ~4..0b ~2..0b:~2..0b:~2..0b GMT", [Day, D, Month, Y, H, Mi, S])
    ).

%%--------------------------------------------------------------------
%% JSON-RPC (9)
%%--------------------------------------------------------------------

jsonrpc(Headers, Query, Body, Responder, #{server := Server} = Cfg) ->
    case barrel_a2a_json:is_json_media_type(header(<<"content-type">>, Headers)) of
        false ->
            reply_error(
                jsonrpc,
                415,
                [],
                barrel_a2a_error:new(invalid_request, <<"Content-Type must be JSON">>),
                Responder,
                Cfg
            );
        true ->
            case barrel_a2a_json:decode(Body) of
                {error, _} ->
                    reply_jsonrpc_error(
                        null, barrel_a2a_error:new(parse_error), 400, Responder, Cfg
                    );
                {ok, Decoded} ->
                    case barrel_a2a_jsonrpc:classify(Decoded) of
                        {request, Id, Method, Params} ->
                            case barrel_a2a_jsonrpc:op_for_method(Method) of
                                {ok, Op} ->
                                    ReqCtx = req_ctx(jsonrpc, Headers, Query, undefined, Cfg),
                                    Reply = barrel_a2a_server_core:call(Server, Op, Params, ReqCtx),
                                    jsonrpc_reply(Id, Op, Reply, ReqCtx, Responder, Cfg);
                                error ->
                                    reply_jsonrpc_error(
                                        Id,
                                        barrel_a2a_error:new(method_not_found),
                                        200,
                                        Responder,
                                        Cfg
                                    )
                            end;
                        {invalid, Id, Why} ->
                            reply_jsonrpc_error(
                                Id, barrel_a2a_error:new(invalid_request, Why), 400, Responder, Cfg
                            );
                        _ ->
                            reply_jsonrpc_error(
                                null,
                                barrel_a2a_error:new(invalid_request, <<"Expected a request">>),
                                400,
                                Responder,
                                Cfg
                            )
                    end
            end
    end.

jsonrpc_reply(Id, Op, {ok, Result}, ReqCtx, Responder, Cfg) ->
    case outbound_check(Op, Result, Cfg) of
        ok ->
            Hdrs = common_headers(
                [{<<"content-type">>, ?JSON} | extension_headers(ReqCtx, Cfg)], Cfg
            ),
            reply(
                Responder,
                200,
                Hdrs,
                barrel_a2a_json:encode(barrel_a2a_jsonrpc:response(Id, Result))
            );
        {error, E} ->
            reply_jsonrpc_error(Id, E, 500, Responder, Cfg)
    end;
jsonrpc_reply(Id, _Op, {error, #{type := Type} = E}, _ReqCtx, Responder, Cfg) ->
    Status =
        case Type of
            unauthenticated -> 401;
            permission_denied -> 403;
            rate_limited -> 429;
            _ -> 200
        end,
    reply_jsonrpc_error(Id, E, Status, Responder, Cfg);
jsonrpc_reply(Id, _Op, {stream, Subscribe}, ReqCtx, Responder, Cfg) ->
    Frame = fun
        ({event, Ev}) -> barrel_a2a_json:encode(barrel_a2a_jsonrpc:response(Id, Ev));
        ({error, E}) -> barrel_a2a_json:encode(barrel_a2a_jsonrpc:error_response(Id, E))
    end,
    stream(Subscribe, Frame, ReqCtx, Responder, Cfg).

reply_jsonrpc_error(Id, Error, Status, Responder, Cfg) ->
    Hdrs = common_headers([{<<"content-type">>, ?JSON} | error_headers(Error)], Cfg),
    reply(
        Responder,
        Status,
        Hdrs,
        barrel_a2a_json:encode(barrel_a2a_jsonrpc:error_response(Id, Error))
    ).

%%--------------------------------------------------------------------
%% REST (11)
%%--------------------------------------------------------------------

rest(
    Method,
    Path0,
    Headers,
    Query,
    Body,
    Responder,
    #{server := Server, base_path := Base, tenant := Tenant} = Cfg
) ->
    RestBase = <<Base/binary, "/v1">>,
    {PathTenant, Path} = barrel_a2a_tenant:strip_prefix(Tenant, {RestBase, Path0}),
    case barrel_a2a_rest:match(Method, Path, barrel_a2a_rest:routes(RestBase)) of
        {error, not_found} ->
            reply_error(
                rest,
                404,
                [],
                barrel_a2a_error:new(method_not_found, <<"No such route">>),
                Responder,
                Cfg
            );
        {error, {method_not_allowed, Allowed}} ->
            Allow = iolist_to_binary(lists:join(<<", ">>, Allowed)),
            reply_error(rest, 405, [{<<"allow">>, Allow}], method_not_allowed(), Responder, Cfg);
        {ok, Op, Bindings} ->
            case decode_rest_body(Method, Headers, Body) of
                {error, unsupported_media_type} ->
                    reply_error(
                        rest,
                        415,
                        [],
                        barrel_a2a_error:new(invalid_request, <<"Content-Type must be JSON">>),
                        Responder,
                        Cfg
                    );
                {error, parse_error} ->
                    reply_error(rest, 400, [], barrel_a2a_error:new(parse_error), Responder, Cfg);
                {ok, Decoded} ->
                    Request = barrel_a2a_rest:build_request(Op, Bindings, Query, Decoded),
                    ReqCtx = req_ctx(rest, Headers, Query, PathTenant, Cfg),
                    Reply = barrel_a2a_server_core:call(Server, Op, Request, ReqCtx),
                    rest_reply(Op, Reply, ReqCtx, Responder, Cfg)
            end
    end.

decode_rest_body(_Method, _Headers, <<>>) ->
    {ok, undefined};
decode_rest_body(_Method, Headers, Body) ->
    case barrel_a2a_json:is_json_media_type(header(<<"content-type">>, Headers)) of
        false ->
            {error, unsupported_media_type};
        true ->
            case barrel_a2a_json:decode(Body) of
                {ok, Decoded} -> {ok, Decoded};
                {error, _} -> {error, parse_error}
            end
    end.

rest_reply(Op, {ok, Result}, ReqCtx, Responder, Cfg) ->
    case outbound_check(Op, Result, Cfg) of
        ok ->
            Hdrs = common_headers(
                [{<<"content-type">>, barrel_a2a:media_type()} | extension_headers(ReqCtx, Cfg)],
                Cfg
            ),
            reply(Responder, 200, Hdrs, barrel_a2a_json:encode(Result));
        {error, E} ->
            reply_error(rest, 500, [], E, Responder, Cfg)
    end;
rest_reply(_Op, {error, #{type := Type} = E}, _ReqCtx, Responder, Cfg) ->
    reply_error(rest, barrel_a2a_error:http_status(Type), [], E, Responder, Cfg);
rest_reply(_Op, {stream, Subscribe}, ReqCtx, Responder, Cfg) ->
    Frame = fun
        ({event, Ev}) -> barrel_a2a_json:encode(Ev);
        ({error, E}) -> barrel_a2a_json:encode(barrel_a2a_error:to_http_body(E))
    end,
    stream(Subscribe, Frame, ReqCtx, Responder, Cfg).

reply_error(Binding, Status, Extra, Error, Responder, Cfg) ->
    ContentType =
        case Binding of
            jsonrpc -> ?JSON;
            rest -> barrel_a2a:media_type()
        end,
    Hdrs = common_headers([{<<"content-type">>, ContentType} | Extra ++ error_headers(Error)], Cfg),
    Body =
        case Binding of
            jsonrpc -> barrel_a2a_jsonrpc:error_response(null, Error);
            rest -> barrel_a2a_error:to_http_body(Error)
        end,
    reply(Responder, Status, Hdrs, barrel_a2a_json:encode(Body)).

%%--------------------------------------------------------------------
%% Streaming (9.4.2, 11.7)
%%--------------------------------------------------------------------

stream(Subscribe, Frame, ReqCtx, Responder, #{keepalive_ms := Keepalive} = Cfg) ->
    Hdrs = common_headers(sse_headers() ++ extension_headers(ReqCtx, Cfg), Cfg),
    case Subscribe(self()) of
        {error, #{type := Type} = E} ->
            %% Nothing sent yet: answer with the proper status.
            reply_error(
                rest_or_jsonrpc(Frame), barrel_a2a_error:http_status(Type), [], E, Responder, Cfg
            );
        {ok, Initial} ->
            stream_start(Responder, 200, Hdrs),
            case send_events(Initial, Frame, Responder) of
                {ok, final} ->
                    stream_end(Responder);
                {ok, more} ->
                    stream_loop(Frame, Responder, Keepalive, maps:get(disconnected, Responder));
                {error, _} ->
                    stream_end(Responder)
            end
    end.

rest_or_jsonrpc(Frame) ->
    %% Both frame funs share a shape; probe with a marker error.
    Probe = Frame({error, barrel_a2a_error:new(internal_error)}),
    case binary:match(Probe, <<"\"jsonrpc\"">>) of
        nomatch -> rest;
        _ -> jsonrpc
    end.

send_events([], _, _) ->
    {ok, more};
send_events([Ev | Rest], Frame, Responder) ->
    case stream_chunk(Responder, barrel_a2a_sse:encode(Frame({event, Ev}))) of
        ok ->
            case barrel_a2a_event:is_final(Ev) of
                true -> {ok, final};
                false -> send_events(Rest, Frame, Responder)
            end;
        {error, _} = E ->
            E
    end.

stream_loop(Frame, Responder, Keepalive, Disconnected) ->
    receive
        {a2a_task_event, _, Ev} ->
            case send_events([Ev], Frame, Responder) of
                {ok, final} -> stream_end(Responder);
                {ok, more} -> stream_loop(Frame, Responder, Keepalive, Disconnected);
                {error, _} -> stream_end(Responder)
            end;
        {a2a_task_error, _, E} ->
            _ = stream_chunk(Responder, barrel_a2a_sse:encode(Frame({error, E}))),
            stream_end(Responder);
        {'DOWN', _, process, _, _} ->
            stream_end(Responder);
        Msg ->
            case Disconnected(Msg) of
                true -> ok;
                false -> stream_loop(Frame, Responder, Keepalive, Disconnected)
            end
    after Keepalive ->
        case stream_chunk(Responder, barrel_a2a_sse:comment(<<"keepalive">>)) of
            ok -> stream_loop(Frame, Responder, Keepalive, Disconnected);
            {error, _} -> ok
        end
    end.

-spec sse_headers() -> [{binary(), binary()}].
sse_headers() ->
    [
        {<<"content-type">>, <<"text/event-stream">>},
        {<<"cache-control">>, <<"no-cache">>},
        {<<"x-accel-buffering">>, <<"no">>}
    ].

%%--------------------------------------------------------------------
%% Request context
%%--------------------------------------------------------------------

req_ctx(Binding, Headers, Query, PathTenant, Cfg) ->
    Version =
        case header(<<"a2a-version">>, Headers) of
            undefined -> query_ci(<<"a2a-version">>, Query);
            V -> V
        end,
    Ext =
        case header(<<"a2a-extensions">>, Headers) of
            undefined -> query_ci(<<"a2a-extensions">>, Query);
            E -> E
        end,
    Ctx = #{
        binding => Binding,
        headers => Headers,
        version => Version,
        extensions => barrel_a2a_extensions:parse_header(Ext),
        tenant => PathTenant,
        peer => maps:get(peer, Cfg, undefined)
    },
    case maps:get(principal, Cfg, undefined) of
        undefined -> Ctx;
        P -> Ctx#{principal => P}
    end.

query_ci(Name, Query) ->
    case [V || {K, V} <- Query, string:lowercase(K) =:= Name] of
        [V | _] -> V;
        [] -> undefined
    end.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

%%--------------------------------------------------------------------
%% Headers and outbound checks
%%--------------------------------------------------------------------

common_headers(Hdrs, #{hsts := true}) ->
    [{<<"strict-transport-security">>, <<"max-age=31536000">>} | Hdrs];
common_headers(Hdrs, _) ->
    Hdrs.

extension_headers(ReqCtx, #{server := Server}) ->
    case
        barrel_a2a_extensions:format_header(
            barrel_a2a_server_core:active_extensions(Server, ReqCtx)
        )
    of
        undefined -> [];
        Value -> [{<<"a2a-extensions">>, Value}]
    end.

error_headers(#{challenge := Challenge}) when is_list(Challenge) ->
    Challenge;
error_headers(#{retry_after := Seconds}) when is_integer(Seconds) ->
    [{<<"retry-after">>, integer_to_binary(Seconds)}];
error_headers(_) ->
    [].

%% With `validate_schema => all' every reply is checked against the
%% schema; a failure is reported as InvalidAgentResponse (3.3.2).
outbound_check(Op, Result, #{server := Server}) ->
    case safe_config(Server) of
        #{validate_schema := all} ->
            case barrel_a2a_schema:validate(reply_type(Op), Result) of
                ok ->
                    ok;
                {error, Errors} ->
                    logger:error("a2a reply to ~p does not match the schema: ~0p", [Op, Errors]),
                    {error, barrel_a2a_error:new(invalid_agent_response)}
            end;
        _ ->
            ok
    end.

reply_type(send_message) -> <<"SendMessageResponse">>;
reply_type(get_task) -> <<"Task">>;
reply_type(cancel_task) -> <<"Task">>;
reply_type(list_tasks) -> <<"ListTasksResponse">>;
reply_type(create_push_config) -> <<"TaskPushNotificationConfig">>;
reply_type(get_push_config) -> <<"TaskPushNotificationConfig">>;
reply_type(list_push_configs) -> <<"ListTaskPushNotificationConfigsResponse">>;
reply_type(get_extended_agent_card) -> <<"AgentCard">>;
reply_type(_) -> <<"Struct">>.

%%--------------------------------------------------------------------
%% Responder shims
%%--------------------------------------------------------------------

reply(#{reply := F}, Status, Headers, Body) ->
    _ = F(Status, Headers, Body),
    ok.

stream_start(#{stream_start := F}, Status, Headers) ->
    _ = F(Status, Headers),
    ok.

stream_chunk(#{stream_chunk := F}, Data) ->
    F(Data).

stream_end(#{stream_end := F}) ->
    _ = F(),
    ok.

safe_config(Server) ->
    try
        barrel_a2a_server:config(Server)
    catch
        error:badarg -> undefined
    end.
