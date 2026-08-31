%%%-------------------------------------------------------------------
%%% @doc HTTP client transport: the JSON-RPC and HTTP+JSON bindings
%%% over hackney.
%%%
%%% A connection is a plain map; no socket is held between calls
%%% (hackney pools them). Unary operations run in the caller.
%%% Streaming operations run in a dedicated process that owns the
%%% async hackney request, parses SSE with `barrel_a2a_sse' and
%%% forwards events to the owner as documented in
%%% `barrel_a2a_client_transport'. The stream process monitors its
%%% owner and closes the socket when the owner dies.
%%%
%%% Transport options (`transport_opts' of `barrel_a2a_client'):
%%% `timeout', `ssl_options' (hackney `ssl_options'), `proxy' and
%%% `hackney_options' (extra hackney options).
%%%
%%% == State ==
%%%
%%% The connection is a stateless {@link conn()} map. Only a stream has
%%% a process, and its `#st{}' record is documented at its definition:
%%% `parser' is the SSE frame state and `buffer' the bytes not yet
%%% forming a frame, which is why both exist.
%%%
%%% == Neighbours ==
%%%
%%% Selected by `barrel_a2a_client' through the
%%% `barrel_a2a_client_transport' behaviour. Calls hackney and
%%% `barrel_a2a_sse'.
%%%
%%% Specification: JSON-RPC binding 9, HTTP+JSON binding 11, discovery
%%% 8.2 for {@link fetch_card/2}.
%%%
%%% == Testing ==
%%%
%%% `test/barrel_a2a_client_http_tests.erl' covers the pure parts
%%% (option handling, URL and header building) with no network. The
%%% streaming path needs a server; the end-to-end suites provide one.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_client_http).

-behaviour(barrel_a2a_client_transport).

-export([connect/2, call/4, stream/5, cancel_stream/2, close/1, fetch_card/2]).

-define(DEFAULT_TIMEOUT, 30000).
-define(SSE, <<"text/event-stream">>).
-define(JSON, <<"application/json">>).
-define(MAX_BODY, 16 * 1024 * 1024).

-type conn() :: #{
    url := binary(),
    binding := binary(),
    timeout := timeout(),
    ssl_options => list(),
    hackney_options => list(),
    proxy => term()
}.

-export_type([conn/0]).

%%--------------------------------------------------------------------
%% Connection
%%--------------------------------------------------------------------

-spec connect(barrel_a2a_agent_card:interface(), map()) ->
    {ok, conn()} | {error, barrel_a2a_error:error()}.
connect(#{<<"url">> := Url0, <<"protocolBinding">> := Binding}, Opts) when is_binary(Url0) ->
    _ = application:ensure_all_started(hackney),
    Url = string:trim(Url0, trailing, "/"),
    case valid_url(Url) of
        true ->
            Conn0 = #{
                url => Url,
                binding => Binding,
                timeout => maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)
            },
            Conn = maps:merge(Conn0, maps:with([ssl_options, hackney_options, proxy], Opts)),
            {ok, Conn};
        false ->
            {error, barrel_a2a_error:new(invalid_params, [<<"Invalid interface URL: ">>, Url])}
    end;
connect(_, _) ->
    {error, barrel_a2a_error:new(invalid_params, <<"Interface has no URL">>)}.

valid_url(Url) ->
    case uri_string:parse(Url) of
        #{scheme := S, host := H} -> http_scheme(S) andalso H =/= <<>> andalso H =/= "";
        _ -> false
    end.

http_scheme(<<"http">>) -> true;
http_scheme(<<"https">>) -> true;
http_scheme("http") -> true;
http_scheme("https") -> true;
http_scheme(_) -> false.

-spec close(conn()) -> ok.
close(_Conn) -> ok.

%%--------------------------------------------------------------------
%% Unary calls
%%--------------------------------------------------------------------

-spec call(conn(), barrel_a2a:op(), barrel_a2a:object(), map()) ->
    {ok, barrel_a2a:json()} | {error, barrel_a2a_error:error()}.
call(Conn, Op, Request, Opts) ->
    {Method, Url, Headers, Body} = build(Conn, Op, Request, Opts, unary),
    Timeout = maps:get(timeout, Opts, maps:get(timeout, Conn, ?DEFAULT_TIMEOUT)),
    HOpts = [with_body, {recv_timeout, Timeout}, {connect_timeout, Timeout} | hackney_opts(Conn)],
    case request(Method, Url, Headers, Body, HOpts) of
        {ok, Status, _RespHeaders, RespBody} ->
            reply(binding(Conn), Status, decode(RespBody));
        {error, Reason} ->
            {error, transport_error(Reason)}
    end.

request(Method, Url, Headers, Body, HOpts) ->
    try hackney:request(Method, Url, Headers, Body, HOpts) of
        {ok, Status, RespHeaders, RespBody} when is_binary(RespBody) ->
            {ok, Status, RespHeaders, RespBody};
        {ok, Status, RespHeaders} ->
            {ok, Status, RespHeaders, <<>>};
        {error, Reason} ->
            {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

reply(jsonrpc, Status, {ok, Decoded}) ->
    case barrel_a2a_jsonrpc:classify(Decoded) of
        {response, _, Result} -> {ok, Result};
        {error, _, E} -> {error, E#{http_status => Status}};
        _ -> {error, barrel_a2a_error:from_http(Status, Decoded)}
    end;
reply(jsonrpc, Status, undefined) ->
    {error, barrel_a2a_error:from_http(Status, undefined)};
reply(rest, Status, {ok, Decoded}) when Status >= 200, Status < 300 ->
    {ok, Decoded};
reply(rest, Status, undefined) when Status >= 200, Status < 300 ->
    {ok, #{}};
reply(rest, Status, {ok, Decoded}) ->
    {error, barrel_a2a_error:from_http(Status, Decoded)};
reply(rest, Status, undefined) ->
    {error, barrel_a2a_error:from_http(Status, undefined)}.

%%--------------------------------------------------------------------
%% Streams
%%--------------------------------------------------------------------

-spec stream(conn(), barrel_a2a:op(), barrel_a2a:object(), pid(), map()) ->
    {ok, pid()} | {error, barrel_a2a_error:error()}.
stream(Conn, Op, Request, Owner, Opts) ->
    {Method, Url, Headers, Body} = build(Conn, Op, Request, Opts, stream),
    Binding = binding(Conn),
    HOpts = [async, {pool, false}, {recv_timeout, infinity} | hackney_opts(Conn)],
    Pid = spawn(fun() -> stream_init(Binding, Method, Url, Headers, Body, HOpts, Owner) end),
    {ok, Pid}.

-spec cancel_stream(conn(), pid()) -> ok.
cancel_stream(_Conn, Pid) when is_pid(Pid) ->
    Pid ! {a2a_cancel_stream, self()},
    ok;
cancel_stream(_Conn, _) ->
    ok.

%% State of one stream process: it owns a single hackney request and
%% forwards what it decodes to `owner'.
-record(st, {
    binding :: jsonrpc | rest,
    %% The remote task that opened the stream. Monitored, so the
    %% stream dies with it.
    owner :: pid(),
    ref :: term(),
    status :: undefined | non_neg_integer(),
    %% Whether the response really is an event stream. The server may
    %% answer a stream request with a single JSON document (a direct
    %% message, or an error), and then `buffer' is used instead of
    %% `parser': one collects the whole body to decode at the end, the
    %% other decodes SSE frames as they arrive.
    sse = false :: boolean(),
    parser = barrel_a2a_sse:new() :: barrel_a2a_sse:parser(),
    buffer = <<>> :: binary()
}).

stream_init(Binding, Method, Url, Headers, Body, HOpts, Owner) ->
    _ = monitor(process, Owner),
    case request_async(Method, Url, Headers, Body, HOpts) of
        {ok, Ref} ->
            stream_loop(#st{binding = Binding, owner = Owner, ref = Ref});
        {error, Reason} ->
            emit(Owner, {error, transport_error(Reason)})
    end.

request_async(Method, Url, Headers, Body, HOpts) ->
    try
        hackney:request(Method, Url, Headers, Body, HOpts)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

stream_loop(#st{ref = Ref, owner = Owner} = St) ->
    receive
        {hackney_response, Ref, {status, Status, _}} ->
            stream_loop(St#st{status = Status});
        {hackney_response, Ref, {headers, Headers}} ->
            Sse = St#st.status =:= 200 andalso is_sse(Headers),
            stream_loop(St#st{sse = Sse});
        {hackney_response, Ref, Chunk} when is_binary(Chunk) ->
            case chunk(Chunk, St) of
                {continue, St1} -> stream_loop(St1);
                stop -> close_ref(Ref)
            end;
        {hackney_response, Ref, done} ->
            finish(St);
        {hackney_response, Ref, {error, Reason}} ->
            emit(Owner, {error, transport_error(Reason)});
        {hackney_response, Ref, {redirect, _, _}} ->
            close_ref(Ref),
            emit(Owner, {error, barrel_a2a_error:transport(redirect)});
        {a2a_cancel_stream, _} ->
            close_ref(Ref);
        {'DOWN', _, process, Owner, _} ->
            close_ref(Ref)
    end.

close_ref(Ref) ->
    try
        hackney:close(Ref)
    catch
        _:_ -> ok
    end,
    ok.

chunk(Chunk, #st{sse = true, parser = P} = St) ->
    case barrel_a2a_sse:feed(Chunk, P) of
        {Events, P1} when is_list(Events) ->
            case deliver(Events, St) of
                ok -> {continue, St#st{parser = P1}};
                stop -> stop
            end;
        {error, Reason} ->
            emit(St#st.owner, {error, barrel_a2a_error:transport(Reason)}),
            stop
    end;
chunk(Chunk, #st{buffer = Buf} = St) when byte_size(Buf) + byte_size(Chunk) =< ?MAX_BODY ->
    {continue, St#st{buffer = <<Buf/binary, Chunk/binary>>}};
%% A stream request answered with a single document, not an event
%% stream: the whole body is collected before it can be decoded, so it
%% needs a ceiling. An SSE response never lands here.
chunk(_Chunk, #st{owner = Owner}) ->
    emit(Owner, {error, barrel_a2a_error:transport(body_too_large)}),
    stop.

%% Stream ended: flush the parser (SSE) or interpret the collected
%% body (an error status, or a direct JSON reply).
finish(#st{sse = true, parser = P, owner = Owner} = St) ->
    _ = deliver(barrel_a2a_sse:finish(P), St),
    emit(Owner, done);
finish(#st{status = Status, buffer = Buf, owner = Owner, binding = Binding}) ->
    case reply(Binding, Status, decode(Buf)) of
        {ok, Reply} ->
            emit(Owner, {event, Reply}),
            emit(Owner, done);
        {error, E} ->
            emit(Owner, {error, E})
    end.

deliver([], _St) ->
    ok;
deliver([#{data := Data} | Rest], #st{owner = Owner, binding = Binding} = St) ->
    case event(Binding, decode(Data)) of
        {event, Reply} ->
            emit(Owner, {event, Reply}),
            deliver(Rest, St);
        {error, E} ->
            emit(Owner, {error, E}),
            stop
    end.

event(jsonrpc, {ok, Decoded}) ->
    case barrel_a2a_jsonrpc:classify(Decoded) of
        {response, _, Result} -> {event, Result};
        {error, _, E} -> {error, E};
        {invalid, _, Msg} -> {error, barrel_a2a_error:new(invalid_agent_response, Msg)};
        {request, _, _, _} -> {error, barrel_a2a_error:new(invalid_agent_response)}
    end;
event(rest, {ok, #{<<"error">> := _} = Decoded}) ->
    {error, barrel_a2a_error:from_http(200, Decoded)};
event(rest, {ok, Decoded}) when is_map(Decoded) ->
    {event, Decoded};
event(_, _) ->
    {error, barrel_a2a_error:new(invalid_agent_response, <<"Stream event is not JSON">>)}.

emit(Owner, Msg) ->
    Owner ! {a2a_stream, self(), Msg},
    ok.

is_sse(Headers) ->
    case header(<<"content-type">>, Headers) of
        undefined -> false;
        CT -> media_type(CT) =:= ?SSE
    end.

media_type(CT) ->
    [Type | _] = binary:split(CT, <<";">>),
    string:lowercase(string:trim(Type)).

%%--------------------------------------------------------------------
%% Agent Card
%%--------------------------------------------------------------------

-spec fetch_card(binary(), map()) ->
    {ok, barrel_a2a:agent_card(), binary() | undefined}
    | {ok, not_modified}
    | {error, barrel_a2a_error:error()}.
fetch_card(Url, Opts) ->
    _ = application:ensure_all_started(hackney),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    TOpts = maps:get(transport_opts, Opts, #{}),
    Headers0 = [{<<"accept">>, ?JSON} | maps:get(headers, Opts, [])],
    Headers =
        case maps:get(etag, Opts, undefined) of
            undefined -> Headers0;
            ETag -> [{<<"if-none-match">>, ETag} | Headers0]
        end,
    HOpts = [
        with_body,
        {recv_timeout, Timeout},
        {connect_timeout, Timeout},
        {follow_redirect, true},
        {max_redirect, 3}
        | hackney_opts(TOpts)
    ],
    case request(get, Url, Headers, <<>>, HOpts) of
        {ok, 304, _, _} ->
            {ok, not_modified};
        {ok, 200, RespHeaders, Body} ->
            case decode(Body) of
                {ok, Card} when is_map(Card) ->
                    {ok, Card, header(<<"etag">>, RespHeaders)};
                _ ->
                    {error, barrel_a2a_error:new(parse_error, <<"Agent Card is not JSON">>)}
            end;
        {ok, Status, _, Body} ->
            {error, barrel_a2a_error:from_http(Status, undefined_or(decode(Body)))};
        {error, Reason} ->
            {error, transport_error(Reason)}
    end.

undefined_or({ok, D}) -> D;
undefined_or(undefined) -> undefined.

%%--------------------------------------------------------------------
%% Request building
%%--------------------------------------------------------------------

build(#{url := Url} = Conn, Op, Request, Opts, Mode) ->
    Extra = maps:get(headers, Opts, []),
    case binding(Conn) of
        jsonrpc ->
            Id = barrel_a2a_id:uuid(),
            Envelope = barrel_a2a_jsonrpc:request(
                Id, barrel_a2a_jsonrpc:method_name(Op), Request
            ),
            Headers = [
                {<<"content-type">>, ?JSON},
                {<<"accept">>, accept(jsonrpc, Mode)}
                | Extra
            ],
            {post, Url, Headers, barrel_a2a_json:encode(Envelope)};
        rest ->
            {Method, Path} = barrel_a2a_rest:path_for(Op, <<>>, Request),
            Accept = {<<"accept">>, accept(rest, Mode)},
            case Method of
                M when M =:= <<"GET">>; M =:= <<"DELETE">> ->
                    Query = barrel_a2a_rest:query_for(Op, Request),
                    Full =
                        case Query of
                            <<>> -> <<Url/binary, Path/binary>>;
                            _ -> <<Url/binary, Path/binary, "?", Query/binary>>
                        end,
                    {method_atom(M), Full, [Accept | Extra], <<>>};
                _ ->
                    Body = barrel_a2a_json:encode(rest_body(Op, Request)),
                    Headers = [{<<"content-type">>, barrel_a2a:media_type()}, Accept | Extra],
                    {method_atom(Method), <<Url/binary, Path/binary>>, Headers, Body}
            end
    end.

accept(_, stream) -> ?SSE;
accept(jsonrpc, unary) -> ?JSON;
accept(rest, unary) -> <<(barrel_a2a:media_type())/binary, ", ", ?JSON/binary>>.

rest_body(cancel_task, Req) -> maps:without([<<"id">>], Req);
rest_body(subscribe_to_task, Req) -> maps:without([<<"id">>], Req);
rest_body(create_push_config, Req) -> maps:without([<<"taskId">>], Req);
rest_body(_, Req) -> Req.

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"DELETE">>) -> delete;
method_atom(<<"PUT">>) -> put.

binding(#{binding := <<"JSONRPC">>}) -> jsonrpc;
binding(#{binding := _}) -> rest.

hackney_opts(Conn) ->
    Ssl =
        case maps:get(ssl_options, Conn, undefined) of
            undefined -> [];
            SslOpts -> [{ssl_options, SslOpts}]
        end,
    Proxy =
        case maps:get(proxy, Conn, undefined) of
            undefined -> [];
            P -> [{proxy, P}]
        end,
    Ssl ++ Proxy ++ maps:get(hackney_options, Conn, []).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

decode(<<>>) ->
    undefined;
decode(Body) ->
    case barrel_a2a_json:decode(Body) of
        {ok, _} = Ok -> Ok;
        {error, _} -> undefined
    end.

header(Name, Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(iolist_to_binary(K)) =:= Name] of
        [V | _] -> iolist_to_binary(V);
        [] -> undefined
    end.

transport_error(timeout) -> barrel_a2a_error:new(timeout, <<"Request timed out">>);
transport_error(connect_timeout) -> barrel_a2a_error:new(timeout, <<"Connect timed out">>);
transport_error(checkout_timeout) -> barrel_a2a_error:new(timeout, <<"Pool checkout timed out">>);
transport_error(Reason) -> barrel_a2a_error:transport(Reason).
