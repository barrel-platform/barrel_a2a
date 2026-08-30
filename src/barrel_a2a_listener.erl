%%%-------------------------------------------------------------------
%%% @doc HTTP listener: one port, HTTP/1.1 and HTTP/2, one handler.
%%%
%%% The listener owns the listen socket and a pool of acceptors. Every
%%% accepted connection runs in its own process, which completes the
%%% TLS handshake, reads the ALPN result and hands the socket to
%%% `h1:serve_socket/2' (`http/1.1', or any cleartext connection) or
%%% `h2:serve_socket/2' (`h2'). Connection and stream state belong to
%%% those libraries; nothing here tracks them.
%%%
%%% Per request, h1 or h2 spawn a process and call the listener's
%%% translator, which reads the whole body (bounded by `max_body' and
%%% `body_timeout'), builds a {@link responder()} over the protocol
%%% module, and calls the {@link handler()} with lowercase headers.
%%%
%%% Header shape seen by the handler:
%%% <ul>
%%% <li>names are lowercase binaries;</li>
%%% <li>`x-a2a-scheme' is prepended with `https' or `http', so the
%%%     handler knows whether TLS is on;</li>
%%% <li>h2 keeps `:authority' and `:scheme'; when `host' is missing it
%%%     is added from `:authority' so both protocols expose `host'.</li>
%%% </ul>
%%%
%%% Options (see {@link opts()}): `port' (0 picks a free port, read it
%%% with `port/1'), `ip', `tls' (certfile, keyfile, optional cacertfile
%%% and versions), `acceptors', `max_connections', `max_body',
%%% `body_timeout' and `handshake_timeout'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_listener).

-behaviour(gen_server).

-export([start_link/2, stop/1, port/1, child_spec/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Internal entry points for spawned processes.
-export([acceptor_init/2, connection_init/2]).

-export_type([responder/0, handler/0, opts/0]).

-type responder() :: #{
    reply := fun((Status :: 100..599, Headers :: [{binary(), binary()}], iodata()) -> ok),
    stream_start := fun((Status :: 100..599, Headers :: [{binary(), binary()}]) -> ok),
    stream_chunk := fun((iodata()) -> ok | {error, term()}),
    stream_end := fun(() -> ok),
    disconnected := fun((term()) -> boolean())
}.

-type handler() :: fun(
    (
        Method :: binary(),
        Path :: binary(),
        Headers :: [{binary(), binary()}],
        Body :: binary(),
        responder()
    ) -> any()
).

-type tls_opts() :: #{
    certfile := file:filename(),
    keyfile := file:filename(),
    cacertfile => file:filename(),
    versions => [ssl:protocol_version()]
}.

-type opts() :: #{
    port := inet:port_number(),
    ip => inet:ip_address(),
    tls => tls_opts() | undefined,
    acceptors => pos_integer(),
    max_connections => pos_integer(),
    max_body => pos_integer(),
    body_timeout => timeout(),
    handshake_timeout => timeout()
}.

-define(DEFAULT_MAX_CONNECTIONS, 16384).
-define(DEFAULT_MAX_BODY, 16 * 1024 * 1024).
-define(DEFAULT_BODY_TIMEOUT, 30000).
-define(DEFAULT_HANDSHAKE_TIMEOUT, 5000).
-define(ACCEPTOR_RESTART_BACKOFF, 50).
-define(ACCEPT_ERROR_BACKOFF, 50).

-record(state, {
    transport :: gen_tcp | ssl,
    lsock :: gen_tcp:socket() | ssl:sslsocket(),
    %% The bound port, resolved after listen so that `port => 0' works.
    port :: inet:port_number(),
    %% Live acceptors, used as a set: one dying is replaced after a
    %% short backoff.
    acceptors = #{} :: #{pid() => true},
    %% Everything an accepted connection needs (transport, TLS options,
    %% handler, limits, the connection counter). Passed by value to
    %% each acceptor and on to each connection process, so nothing
    %% calls back into this gen_server on the accept path.
    conn_args :: map()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(opts(), handler()) -> {ok, pid()} | {error, term()}.
start_link(Opts, Handler) when is_map(Opts), is_function(Handler, 5) ->
    gen_server:start_link(?MODULE, {Opts, Handler}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%% @doc The bound port; useful when started with `port => 0'.
-spec port(pid()) -> inet:port_number().
port(Pid) ->
    gen_server:call(Pid, port).

-spec child_spec(term(), opts(), handler()) -> supervisor:child_spec().
child_spec(Id, Opts, Handler) ->
    #{
        id => Id,
        start => {?MODULE, start_link, [Opts, Handler]},
        restart => transient,
        shutdown => 5000,
        type => worker
    }.

%%====================================================================
%% gen_server
%%====================================================================

%% @private
init({Opts, Handler}) ->
    process_flag(trap_exit, true),
    case listen(Opts) of
        {ok, Transport, LSock} ->
            Port = bound_port(Transport, LSock),
            Counter = counters:new(1, []),
            ConnArgs = #{
                listener => self(),
                transport => Transport,
                lsock => LSock,
                counter => Counter,
                max_connections => maps:get(max_connections, Opts, ?DEFAULT_MAX_CONNECTIONS),
                handshake_timeout => maps:get(handshake_timeout, Opts, ?DEFAULT_HANDSHAKE_TIMEOUT),
                serve => serve_opts(Opts, Handler, Transport)
            },
            N = maps:get(acceptors, Opts, max(2, erlang:system_info(schedulers))),
            Acceptors = maps:from_list([{spawn_acceptor(ConnArgs), true} || _ <- lists:seq(1, N)]),
            {ok, #state{
                transport = Transport,
                lsock = LSock,
                port = Port,
                acceptors = Acceptors,
                conn_args = ConnArgs
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

%% @private
handle_call(port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'EXIT', Pid, Reason}, #state{acceptors = Acceptors} = State) ->
    case maps:is_key(Pid, Acceptors) of
        true ->
            acceptor_exited(Pid, Reason, State);
        false ->
            %% A connection process ended; its slot was released by the
            %% process itself.
            {noreply, State}
    end;
handle_info(restart_acceptor, #state{acceptors = Acceptors, conn_args = Args} = State) ->
    Pid = spawn_acceptor(Args),
    {noreply, State#state{acceptors = Acceptors#{Pid => true}}};
handle_info(_Msg, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{transport = Transport, lsock = LSock}) ->
    close(Transport, LSock),
    ok.

acceptor_exited(Pid, Reason, #state{acceptors = Acceptors} = State) ->
    Acceptors1 = maps:remove(Pid, Acceptors),
    case Reason of
        normal ->
            ok;
        shutdown ->
            ok;
        _ ->
            logger:warning("a2a listener acceptor exited: ~p; replacing", [Reason]),
            _ = erlang:send_after(?ACCEPTOR_RESTART_BACKOFF, self(), restart_acceptor),
            ok
    end,
    {noreply, State#state{acceptors = Acceptors1}}.

%%====================================================================
%% Listen socket
%%====================================================================

listen(Opts) ->
    Port = maps:get(port, Opts),
    Ip = maps:get(ip, Opts, {0, 0, 0, 0}),
    Base = [
        binary,
        {active, false},
        {reuseaddr, true},
        {ip, Ip},
        {backlog, 1024}
    ],
    case maps:get(tls, Opts, undefined) of
        undefined ->
            case gen_tcp:listen(Port, Base) of
                {ok, LSock} -> {ok, gen_tcp, LSock};
                {error, _} = E -> E
            end;
        #{certfile := Cert, keyfile := Key} = Tls ->
            CaOpts =
                case maps:get(cacertfile, Tls, undefined) of
                    undefined -> [];
                    CaFile -> [{cacertfile, CaFile}]
                end,
            Versions = maps:get(versions, Tls, ['tlsv1.2', 'tlsv1.3']),
            SslOpts =
                Base ++ CaOpts ++
                    [
                        {certfile, Cert},
                        {keyfile, Key},
                        {versions, Versions},
                        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
                    ],
            case ssl:listen(Port, SslOpts) of
                {ok, LSock} -> {ok, ssl, LSock};
                {error, _} = E -> E
            end
    end.

bound_port(gen_tcp, LSock) ->
    {ok, Port} = inet:port(LSock),
    Port;
bound_port(ssl, LSock) ->
    {ok, {_, Port}} = ssl:sockname(LSock),
    Port.

close(gen_tcp, Sock) ->
    _ = gen_tcp:close(Sock),
    ok;
close(ssl, Sock) ->
    _ = ssl:close(Sock),
    ok.

%%====================================================================
%% Acceptors
%%====================================================================

spawn_acceptor(Args) ->
    proc_lib:spawn_link(?MODULE, acceptor_init, [Args, self()]).

%% @private
acceptor_init(Args, Listener) ->
    acceptor_loop(Args, Listener).

acceptor_loop(#{transport := Transport, lsock := LSock} = Args, Listener) ->
    case accept(Transport, LSock) of
        {ok, Sock} ->
            handle_accepted(Sock, Args, Listener),
            acceptor_loop(Args, Listener);
        {error, closed} ->
            exit(normal);
        {error, Reason} ->
            logger:warning("a2a listener accept failed: ~p", [Reason]),
            timer:sleep(?ACCEPT_ERROR_BACKOFF),
            acceptor_loop(Args, Listener)
    end.

accept(gen_tcp, LSock) -> gen_tcp:accept(LSock);
accept(ssl, LSock) -> ssl:transport_accept(LSock).

%% Admit the connection against `max_connections', then hand the socket
%% to a fresh connection process. The slot is taken here and released
%% by the connection process when it ends.
handle_accepted(
    Sock, #{transport := Transport, counter := Counter, max_connections := Max} = Args, Listener
) ->
    counters:add(Counter, 1, 1),
    case counters:get(Counter, 1) > Max of
        true ->
            counters:sub(Counter, 1, 1),
            close(Transport, Sock);
        false ->
            Pid = proc_lib:spawn(?MODULE, connection_init, [Args, Listener]),
            case transfer(Transport, Sock, Pid) of
                ok ->
                    Pid ! {socket_ready, Sock},
                    ok;
                {error, Reason} ->
                    Pid ! {socket_failed, Reason},
                    close(Transport, Sock)
            end
    end,
    ok.

transfer(gen_tcp, Sock, Pid) -> gen_tcp:controlling_process(Sock, Pid);
transfer(ssl, Sock, Pid) -> ssl:controlling_process(Sock, Pid).

%%====================================================================
%% Per-connection process
%%====================================================================

%% @private
connection_init(#{counter := Counter} = Args, Listener) ->
    %% Linked to the listener so a stop tears the connection down; the
    %% listener traps exits so this process ending never hurts it.
    process_flag(trap_exit, true),
    link(Listener),
    try
        receive
            {socket_ready, Sock} ->
                handle_connection(Sock, Args, Listener);
            {socket_failed, _Reason} ->
                ok;
            {'EXIT', Listener, _} ->
                ok
        after 5000 ->
            ok
        end
    after
        counters:sub(Counter, 1, 1)
    end.

handle_connection(Sock, #{transport := gen_tcp, serve := Serve}, Listener) ->
    serve(h1, gen_tcp, Sock, maps:get(h1, Serve), Listener);
handle_connection(Sock, #{transport := ssl, serve := Serve} = Args, Listener) ->
    case ssl:handshake(Sock, maps:get(handshake_timeout, Args)) of
        {ok, Tls} ->
            case ssl:negotiated_protocol(Tls) of
                {ok, <<"h2">>} -> serve(h2, ssl, Tls, maps:get(h2, Serve), Listener);
                _ -> serve(h1, ssl, Tls, maps:get(h1, Serve), Listener)
            end;
        {error, _Reason} ->
            close(ssl, Sock)
    end.

%% The library's connection process is linked to us. We wait for it to
%% end; if the listener goes first we exit and the link takes the
%% connection with us. h1 closes the socket itself on a failed hand-off,
%% h2 leaves it to us; closing twice is harmless.
serve(Proto, Transport, Sock, Opts, Listener) ->
    case Proto:serve_socket(Sock, Opts) of
        {ok, Pid} ->
            wait_served(Pid, Listener);
        {error, _Reason} ->
            close(Transport, Sock)
    end.

wait_served(Pid, Listener) ->
    receive
        {'EXIT', Pid, _Reason} ->
            ok;
        {'EXIT', Listener, _Reason} ->
            exit(shutdown);
        _Other ->
            wait_served(Pid, Listener)
    end.

%%====================================================================
%% Per-request translator
%%====================================================================

%% The option maps handed to `serve_socket/2', one per protocol. h1
%% enforces the body cap itself; the translator checks it for both.
serve_opts(Opts, Handler, Transport) ->
    Limits = #{
        max_body => maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
        body_timeout => maps:get(body_timeout, Opts, ?DEFAULT_BODY_TIMEOUT),
        scheme => scheme(Transport)
    },
    #{
        h1 => #{
            handler => request_handler(h1, Handler, Limits),
            max_body_size => maps:get(max_body, Limits)
        },
        h2 => #{handler => request_handler(h2, Handler, Limits)}
    }.

scheme(gen_tcp) -> <<"http">>;
scheme(ssl) -> <<"https">>.

%% Runs in the process h1 or h2 spawned for this request.
request_handler(Proto, Handler, Limits) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        case attach(Proto, Conn, StreamId) of
            ok -> serve_request(Proto, Conn, StreamId, Method, Path, Headers, Handler, Limits);
            {error, _Gone} -> ok
        end
    end.

%% h2 delivers a stream's frames only to a registered handler.
attach(h1, _Conn, _StreamId) ->
    ok;
attach(h2, Conn, StreamId) ->
    case h2:set_stream_handler(Conn, StreamId, self()) of
        ok -> ok;
        {ok, _Buffered} -> ok;
        {error, _} = E -> E
    end.

serve_request(Proto, Conn, StreamId, Method, Path, Headers0, Handler, Limits) ->
    case read_body(Proto, Conn, StreamId, Limits, <<>>) of
        {ok, Body} ->
            Headers = request_headers(Headers0, maps:get(scheme, Limits)),
            Responder = responder(Proto, Conn, StreamId),
            run_handler(Proto, Conn, StreamId, Method, Path, Headers, Body, Responder, Handler);
        {error, body_too_large} ->
            answer(Proto, Conn, StreamId, 413, <<"Request body too large">>);
        {error, timeout} ->
            answer(Proto, Conn, StreamId, 408, <<"Request body timeout">>);
        {error, closed} ->
            ok
    end.

run_handler(Proto, Conn, StreamId, Method, Path, Headers, Body, Responder, Handler) ->
    %% `headers_sent' is a process dictionary channel between this
    %% function and the responder closures below, which run in this same
    %% process. It decides whether a crashing handler still gets a 500 or
    %% whether the status line is already on the wire (invariants.md, E2).
    put(headers_sent, false),
    try
        Handler(Method, Path, Headers, Body, Responder)
    catch
        Class:Reason:Stack ->
            log_crash(Class, Reason, Stack),
            case get(headers_sent) of
                true -> ok;
                false -> answer(Proto, Conn, StreamId, 500, <<"Internal Server Error">>)
            end
    end,
    ok.

%% A connection that went away mid-handler is not a crash.
log_crash(exit, shutdown, _) ->
    ok;
log_crash(exit, {shutdown, _}, _) ->
    ok;
log_crash(exit, {noproc, {gen_statem, call, _}}, _) ->
    ok;
log_crash(exit, {normal, {gen_statem, call, _}}, _) ->
    ok;
log_crash(Class, Reason, Stack) ->
    logger:error("a2a http handler crash: ~p:~p~n~p", [Class, Reason, Stack]).

%% A fixed answer from the translator itself. Nothing here may raise.
answer(Proto, Conn, StreamId, Status, Body) ->
    Hdrs = [
        {<<"content-type">>, <<"text/plain">>},
        {<<"content-length">>, integer_to_binary(byte_size(Body))}
    ],
    _ =
        (try
            Proto:send_response(Conn, StreamId, Status, Hdrs)
        catch
            _:_ -> ok
        end),
    _ =
        (try
            Proto:send_data(Conn, StreamId, Body, true)
        catch
            _:_ -> ok
        end),
    ok.

read_body(Proto, Conn, StreamId, #{max_body := Max, body_timeout := Timeout} = Limits, Acc) ->
    receive
        Msg ->
            case body_message(Proto, Conn, StreamId, Msg) of
                {data, Data, End} ->
                    Combined = <<Acc/binary, Data/binary>>,
                    case {byte_size(Combined) > Max, End} of
                        {true, _} -> {error, body_too_large};
                        {false, true} -> {ok, Combined};
                        {false, false} -> read_body(Proto, Conn, StreamId, Limits, Combined)
                    end;
                eof ->
                    {ok, Acc};
                closed ->
                    {error, closed};
                other ->
                    read_body(Proto, Conn, StreamId, Limits, Acc)
            end
    after Timeout ->
        {error, timeout}
    end.

body_message(h1, _Conn, StreamId, {h1_stream, StreamId, {data, Data, End}}) ->
    {data, Data, End};
body_message(h1, _Conn, StreamId, {h1_stream, StreamId, {trailers, _}}) ->
    eof;
body_message(h2, Conn, StreamId, {h2, Conn, {data, StreamId, Data, Fin}}) ->
    {data, Data, Fin};
body_message(h2, Conn, StreamId, {h2, Conn, {trailers, StreamId, _}}) ->
    eof;
body_message(Proto, Conn, StreamId, Msg) ->
    case is_disconnect(Proto, Conn, StreamId, Msg) of
        true -> closed;
        false -> other
    end.

is_disconnect(h1, _Conn, StreamId, {h1_stream, StreamId, {stream_reset, _}}) -> true;
is_disconnect(h2, Conn, StreamId, {h2, Conn, {stream_reset, StreamId, _}}) -> true;
is_disconnect(h2, Conn, _StreamId, {h2, Conn, {closed, _}}) -> true;
is_disconnect(h2, Conn, _StreamId, {h2, Conn, {goaway, _, _}}) -> true;
is_disconnect(_, _, _, _) -> false.

%% Lowercase names, `x-a2a-scheme' first, and `host' derived from
%% `:authority' when h2 did not carry one.
request_headers(Headers0, Scheme) ->
    Headers = [{string:lowercase(K), V} || {K, V} <- Headers0],
    WithHost =
        case {lists:keyfind(<<"host">>, 1, Headers), lists:keyfind(<<":authority">>, 1, Headers)} of
            {false, {_, Authority}} -> [{<<"host">>, Authority} | Headers];
            _ -> Headers
        end,
    [{<<"x-a2a-scheme">>, Scheme} | WithHost].

%% Responder closures over the negotiated protocol module + connection.
%% They run in the request process, so they can read and write the
%% `headers_sent' flag that `run_handler/9' set (invariants.md, E2).
responder(Proto, Conn, StreamId) ->
    #{
        reply => fun(Status, Headers, Body) ->
            Bin = iolist_to_binary(Body),
            Hdrs = ensure_content_length(wire_headers(Proto, Headers), byte_size(Bin)),
            put(headers_sent, true),
            _ = Proto:send_response(Conn, StreamId, Status, Hdrs),
            _ = Proto:send_data(Conn, StreamId, Bin, true),
            ok
        end,
        stream_start => fun(Status, Headers) ->
            put(headers_sent, true),
            case Proto:send_response(Conn, StreamId, Status, wire_headers(Proto, Headers)) of
                ok ->
                    ok;
                {error, Reason} ->
                    %% Nothing written afterwards can reach the peer; a
                    %% stream loop would spin on it.
                    exit({shutdown, {stream_start, Reason}})
            end
        end,
        stream_chunk => fun(Data) ->
            try Proto:send_data(Conn, StreamId, iolist_to_binary(Data), false) of
                ok -> ok;
                {error, _} -> {error, closed}
            catch
                _:_ -> {error, closed}
            end
        end,
        stream_end => fun() ->
            _ =
                (try
                    Proto:send_data(Conn, StreamId, <<>>, true)
                catch
                    _:_ -> ok
                end),
            ok
        end,
        disconnected => fun(Msg) -> is_disconnect(Proto, Conn, StreamId, Msg) end
    }.

%% HTTP/2 forbids connection-specific headers (RFC 9113 section 8.2.2)
%% and h2 refuses the whole response over one.
wire_headers(h1, Headers) ->
    Headers;
wire_headers(h2, Headers) ->
    [
        {K, V}
     || {K, V} <- Headers,
        not lists:member(string:lowercase(K), [
            <<"connection">>,
            <<"keep-alive">>,
            <<"proxy-connection">>,
            <<"transfer-encoding">>,
            <<"upgrade">>
        ])
    ].

%% Add an explicit content-length for fixed responses so h1 does not
%% fall back to chunked framing.
ensure_content_length(Headers, Len) ->
    HasFraming = lists:any(
        fun({K, _}) ->
            L = string:lowercase(K),
            L =:= <<"content-length">> orelse L =:= <<"transfer-encoding">>
        end,
        Headers
    ),
    case HasFraming of
        true -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(Len)} | Headers]
    end.
