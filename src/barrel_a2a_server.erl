%%%-------------------------------------------------------------------
%%% @doc Expose an agent over A2A.
%%%
%%% ```
%%% Card = barrel_a2a_agent_card:new(#{name => <<"Echo">>, skills => [...]}),
%%% {ok, Server} = barrel_a2a_server:start(Card, #{
%%%     handler => fun(_Ctx, Message) -> {ok, barrel_a2a_message:text(Message)} end,
%%%     http => #{port => 8080}
%%% }).
%%% '''
%%%
%%% A server owns its tasks, the push notification store, the auth and
%%% authorization hooks, and optionally one HTTP listener serving the
%%% JSON-RPC and HTTP+JSON bindings plus the Agent Card. With
%%% `listen => false' no listener is started and an embedding
%%% application (see `guides/embedding.md') serves the bindings with
%%% {@link engine_config/2} and `barrel_a2a_http_engine:handle/6', or a
%%% gRPC binding through `barrel_a2a_server_core:call/4'.
%%%
%%% == Options ==
%%%
%%% - `handler' (required): module or `fun/2', see `barrel_a2a_handler'.
%%% - `http': `#{port, ip, tls => #{certfile, keyfile}, acceptors,
%%%   max_connections, max_body}'. Default port 8080 on 127.0.0.1.
%%% - `listen': `false' to run without a listener. Default `true'.
%%% - `url': public base URL used in the card's `supportedInterfaces'
%%%   when the card does not declare them (default derived from the
%%%   bound address).
%%% - `base_path': mount point of the bindings (default `<<"/a2a">>'):
%%%   JSON-RPC at `{base}/jsonrpc', REST under `{base}/v1'.
%%% - `card_path': where the card is served (default the well-known
%%%   path). `card_cache_max_age' seconds (default 3600).
%%% - `tenant': the tenant this server serves, if any.
%%% - `auth': see `barrel_a2a_auth'. `authorize': `owner' (default,
%%%   tasks are visible to the principal that created them), `any',
%%%   or `fun((Principal, TaskEntry) -> boolean())'.
%%% - `validate_schema': `inbound' (default, checks requests and
%%%   ignores fields the schema does not declare), `strict' (as
%%%   `inbound', but an undeclared field is rejected), `all' (`inbound'
%%%   plus every reply) or `false'.
%%% - `push_notifications': `false' (default) or the options of
%%%   `barrel_a2a_push'. Enables the capability.
%%% - `streaming': capability flag, default `true'.
%%% - `extended_card': a card or `fun((Principal) -> Card)'. Enables
%%%   the capability.
%%% - `signing': `#{key, alg, kid, jku}' to sign the published card
%%%   with `barrel_a2a_card_sign'.
%%% - `supported_versions' (default `[<<"1.0">>]'),
%%%   `accept_legacy_version' (treat a missing `A2A-Version' as
%%%   acceptable, default `false').
%%% - `accept_client_context_id' (default `true'), `dedupe_messages'
%%%   (default `false': reuse the task of a repeated `messageId').
%%% - `task_store': `{Module, Opts}' implementing `barrel_a2a_task_store'
%%%   (default in-memory ETS; `{barrel_a2a_task_store_dets, #{file =>
%%%   Path}}' persists tasks across restarts).
%%% - `blocking_timeout': how long a blocking SendMessage waits for a
%%%   terminal or interrupted state before answering with the task as
%%%   it stands. Milliseconds (default 30000) or `infinity' to wait as
%%%   long as the specification asks; `infinity' ties up the request
%%%   process, so use it only where the transport tolerates that.
%%% - `task_ttl' ms (default 3600000), `history_default' (`all' or an
%%%   integer).
%%% - `hsts' (default `true' when TLS), `rate_limit' hook
%%%   `fun((ReqCtx) -> ok | {error, RetryAfterSeconds})'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_server).

-behaviour(gen_server).

-export([start/2, stop/1, child_spec/2, start_link/2]).
-export([card/1, update_card/2, config/1, engine_config/1, engine_config/2, port/1, url/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_PORT, 8080).
-define(DEFAULT_BASE, <<"/a2a">>).

-type opts() :: map().

%% The resolved server configuration: what {@link start/2}'s options
%% became once defaults were applied and the runtime was built. It is
%% written to `persistent_term' under `{barrel_a2a_server, ServerPid}'
%% and read on every request without a process hop, so treat it as
%% immutable after `init/1' except through {@link update_card/2}.
%%
%% Built in three steps, in this order: `build_config/3' produces
%% everything below except the last two groups, `maybe_listen/1' adds
%% the listener keys, and `finalize_card/1' adds the published card.
%% A reader of `server_core' or `task_proc' sees only the finished map.
-type cfg() :: #{
    %% Identity and the processes the server owns.
    server := pid(),
    started_ms := integer(),
    inst_sup := pid(),
    task_sup := pid(),
    push_sup := pid(),
    %% The two stores. `registry' is a `barrel_a2a_task_store' handle,
    %% `push_store' an ETS table; both are owned by the server process.
    registry := barrel_a2a_task_registry:table(),
    push_store := barrel_a2a_push:store(),
    %% Application behaviour.
    handler := barrel_a2a_handler:handler(),
    auth := barrel_a2a_auth:config(),
    authorize := owner | any | fun((barrel_a2a:principal(), map()) -> boolean()),
    rate_limit := undefined | fun((map()) -> ok | {error, non_neg_integer()}),
    %% Protocol policy.
    validate_schema := inbound | strict | all | false,
    streaming := boolean(),
    push := false | barrel_a2a_push:opts(),
    extended_card :=
        undefined
        | barrel_a2a:agent_card()
        | fun((barrel_a2a:principal()) -> barrel_a2a:agent_card()),
    supported_versions := [binary()],
    accept_legacy_version := boolean(),
    accept_client_context_id := boolean(),
    dedupe_messages := boolean(),
    tenant := undefined | binary(),
    %% Task behaviour.
    blocking_timeout := timeout(),
    task_ttl := non_neg_integer(),
    history_default := all | non_neg_integer(),
    %% Where the bindings are mounted. `engine' is the subset handed to
    %% `barrel_a2a_http_engine:config/2'.
    base_path := binary(),
    engine := map(),
    %% Listener. `http' is the option map; `listen' says whether we own
    %% a port at all. `listener_id', `port' and `url' are derived by
    %% `maybe_listen/1' and absent when `listen' is `false' (except
    %% `url', which the caller may supply for an embedded server).
    http := map(),
    listen := boolean(),
    url := undefined | binary(),
    listener_id => term(),
    port => inet:port_number(),
    %% Signing input, and the published card derived from `card_base'
    %% by `finalize_card/1': `card' is what the well-known route
    %% serves, `card_json' its encoded form, `card_etag' its ETag.
    signing := undefined | map(),
    card_base := barrel_a2a:agent_card(),
    card => barrel_a2a:agent_card(),
    card_json => binary(),
    card_etag => binary(),
    %% Fan-out hook called by every task process on every event, or
    %% `undefined' when push notifications are off.
    push_notify := undefined | fun((binary(), barrel_a2a:stream_response()) -> ok)
}.

-export_type([opts/0, cfg/0]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start(barrel_a2a:agent_card(), opts()) -> {ok, pid()} | {error, term()}.
start(Card, Opts) ->
    case application:ensure_all_started(barrel_a2a) of
        {ok, _} -> start_instance(Card, Opts);
        {error, Reason} -> {error, {application_not_started, Reason}}
    end.

start_instance(Card, Opts) ->
    case barrel_a2a_server_sup:start_server(#{card => Card, opts => Opts}) of
        {ok, Sup} ->
            case barrel_a2a_server_inst_sup:server(Sup) of
                undefined ->
                    _ = barrel_a2a_server_sup:stop_server(Sup),
                    {error, server_not_started};
                Pid ->
                    {ok, Pid}
            end;
        {error, {shutdown, {failed_to_start_child, server, Reason}}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec stop(pid()) -> ok.
stop(Server) ->
    try gen_server:call(Server, inst_sup) of
        Sup when is_pid(Sup) ->
            _ = barrel_a2a_server_sup:stop_server(Sup),
            ok;
        _ ->
            ok
    catch
        exit:_ -> ok
    end.

%% @doc A child spec for embedding a server in the caller's own
%% supervision tree. The child is the instance supervisor.
-spec child_spec(barrel_a2a:agent_card(), opts()) -> supervisor:child_spec().
child_spec(Card, Opts) ->
    #{
        id => maps:get(id, Opts, barrel_a2a_server),
        start => {barrel_a2a_server_inst_sup, start_link, [#{card => Card, opts => Opts}]},
        type => supervisor,
        shutdown => infinity
    }.

%% @private
start_link(InstSup, Args) ->
    gen_server:start_link(?MODULE, {InstSup, Args}, []).

%% @doc The published (signed, interfaces filled) Agent Card.
-spec card(pid()) -> barrel_a2a:agent_card().
card(Server) -> maps:get(card, config(Server)).

%% @doc Replace the card at runtime (interfaces and signature are
%% recomputed).
-spec update_card(pid(), barrel_a2a:agent_card()) -> ok | {error, term()}.
update_card(Server, Card) -> gen_server:call(Server, {update_card, Card}).

%% @doc The server configuration, read without a process hop.
-spec config(pid()) -> cfg().
config(Server) -> persistent_term:get({?MODULE, Server}).

-spec engine_config(pid()) -> barrel_a2a_http_engine:config().
engine_config(Server) -> engine_config(Server, #{}).

%% @doc The configuration an embedder passes to
%% `barrel_a2a_http_engine:handle/6'. Validated once, here.
-spec engine_config(pid(), map()) -> barrel_a2a_http_engine:config().
engine_config(Server, Overrides) ->
    Cfg = config(Server),
    barrel_a2a_http_engine:config(Server, maps:merge(maps:get(engine, Cfg), Overrides)).

%% @doc Bound port of the listener, if any.
-spec port(pid()) -> inet:port_number() | undefined.
port(Server) -> maps:get(port, config(Server), undefined).

%% @doc Public base URL of the listener, if any.
-spec url(pid()) -> binary() | undefined.
url(Server) -> maps:get(url, config(Server), undefined).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

%% @private
init({InstSup, #{card := Card0, opts := Opts}}) ->
    process_flag(trap_exit, true),
    try
        Cfg0 = build_config(InstSup, Card0, Opts),
        persistent_term:put({?MODULE, self()}, Cfg0),
        %% Stored again before the card is finalized so that a failure
        %% in `finalize_card/1' can still find the listener to stop.
        Cfg1 = maybe_listen(Cfg0),
        persistent_term:put({?MODULE, self()}, Cfg1),
        Cfg = finalize_card(Cfg1),
        persistent_term:put({?MODULE, self()}, Cfg),
        {ok, #{cfg => Cfg, timer => arm_expiry(Cfg)}}
    catch
        throw:{invalid_option, _} = Reason ->
            {stop, undo(Reason)};
        throw:{listener, Reason} ->
            {stop, undo({listener_failed, Reason})};
        Class:Reason:Stack ->
            %% Anything else is a bug rather than a rejected option, but
            %% it must not leak what was already built either.
            _ = undo(Reason),
            erlang:raise(Class, Reason, Stack)
    end.

%% Returning `{stop, _}' from `init/1' does not run `terminate/2', so
%% everything built so far has to be undone here. The partial config is
%% read back from `persistent_term' because the throw discarded it.
undo(Reason) ->
    case persistent_term:get({?MODULE, self()}, undefined) of
        undefined ->
            ok;
        Cfg ->
            _ =
                case maps:get(listener_id, Cfg, undefined) of
                    undefined -> ok;
                    Id -> barrel_a2a_listener_sup:stop_listener(Id)
                end,
            _ = barrel_a2a_task_registry:close(maps:get(registry, Cfg)),
            _ = persistent_term:erase({?MODULE, self()}),
            ok
    end,
    Reason.

%% The expiry sweep runs at most once a minute and at least once a
%% second: `task_ttl' can legitimately be 0 (expire as soon as a task is
%% terminal), and `send_after(0, ...)' would spin.
arm_expiry(Cfg) ->
    Ttl = maps:get(task_ttl, Cfg),
    erlang:send_after(max(1000, min(Ttl, 60000)), self(), expire).

%% @private
handle_call(inst_sup, _From, #{cfg := Cfg} = St) ->
    {reply, maps:get(inst_sup, Cfg), St};
handle_call({update_card, Card}, _From, #{cfg := Cfg} = St) ->
    case barrel_a2a_validate:agent_card(with_interfaces(Card, Cfg)) of
        ok ->
            Cfg1 = finalize_card(Cfg#{card_base => Card}),
            persistent_term:put({?MODULE, self()}, Cfg1),
            {reply, ok, St#{cfg => Cfg1}};
        {error, Reason} ->
            {reply, {error, Reason}, St}
    end;
handle_call(_Other, _From, St) ->
    {reply, {error, unknown_call}, St}.

%% @private
handle_cast(_Msg, St) ->
    {noreply, St}.

%% @private
handle_info(expire, #{cfg := Cfg} = St) ->
    _ = barrel_a2a_task_registry:expire(maps:get(registry, Cfg), maps:get(task_ttl, Cfg)),
    {noreply, St#{timer => arm_expiry(Cfg)}};
handle_info({'EXIT', Pid, Reason}, #{cfg := Cfg} = St) ->
    %% The task and push supervisors are linked, not supervised (see
    %% barrel_a2a_server_inst_sup). Losing one leaves this process
    %% holding a dead pid, so stop and let the instance supervisor
    %% rebuild the whole server.
    case Pid =:= maps:get(task_sup, Cfg) orelse Pid =:= maps:get(push_sup, Cfg) of
        true -> {stop, {supervisor_down, Pid, Reason}, St};
        false -> {noreply, St}
    end;
handle_info(_Other, St) ->
    {noreply, St}.

%% @private
terminate(_Reason, #{cfg := Cfg}) ->
    _ =
        case maps:get(listener_id, Cfg, undefined) of
            undefined -> ok;
            Id -> barrel_a2a_listener_sup:stop_listener(Id)
        end,
    _ = barrel_a2a_task_registry:close(maps:get(registry, Cfg)),
    _ = persistent_term:erase({?MODULE, self()}),
    ok.

%%--------------------------------------------------------------------
%% Configuration
%%--------------------------------------------------------------------

build_config(InstSup, Card0, Opts) ->
    {ok, TaskSup} = barrel_a2a_task_sup:start_link(),
    {ok, PushSup} = barrel_a2a_push_sup:start_link(),
    Handler = required(barrel_a2a_handler:normalize(maps:get(handler, Opts, undefined)), handler),
    Auth = required(barrel_a2a_auth:normalize(maps:get(auth, Opts, none)), auth),
    Authorize = authorize_opt(maps:get(authorize, Opts, owner)),
    Push = push_opt(maps:get(push_notifications, Opts, false), PushSup),
    Http = maps:merge(#{port => ?DEFAULT_PORT, ip => {127, 0, 0, 1}}, maps:get(http, Opts, #{})),
    Listen = maps:get(listen, Opts, true),
    Tls = maps:get(tls, Http, undefined) =/= undefined,
    Card =
        case is_map(Card0) of
            true -> Card0;
            false -> throw({invalid_option, {card, Card0}})
        end,
    Registry =
        case barrel_a2a_task_registry:new(task_store_opt(maps:get(task_store, Opts, undefined))) of
            {ok, R} -> R;
            {error, Reason} -> throw({invalid_option, {task_store, Reason}})
        end,
    PushStore = barrel_a2a_push:new_store(),
    Base = base_path(maps:get(base_path, Opts, ?DEFAULT_BASE)),
    Cfg = #{
        server => self(),
        started_ms => barrel_a2a_time:now_ms(),
        inst_sup => InstSup,
        task_sup => TaskSup,
        push_sup => PushSup,
        registry => Registry,
        push_store => PushStore,
        card_base => Card,
        handler => Handler,
        auth => Auth,
        authorize => Authorize,
        validate_schema => schema_opt(maps:get(validate_schema, Opts, inbound)),
        push => Push,
        streaming => maps:get(streaming, Opts, true) =:= true,
        extended_card => maps:get(extended_card, Opts, undefined),
        signing => maps:get(signing, Opts, undefined),
        supported_versions => maps:get(supported_versions, Opts, barrel_a2a:supported_versions()),
        accept_legacy_version => maps:get(accept_legacy_version, Opts, false) =:= true,
        accept_client_context_id => maps:get(accept_client_context_id, Opts, true) =:= true,
        dedupe_messages => maps:get(dedupe_messages, Opts, false) =:= true,
        blocking_timeout => blocking_opt(maps:get(blocking_timeout, Opts, 30000)),
        task_ttl => maps:get(task_ttl, Opts, 3600000),
        history_default => maps:get(history_default, Opts, all),
        rate_limit => maps:get(rate_limit, Opts, undefined),
        tenant => maps:get(tenant, Opts, undefined),
        base_path => Base,
        http => Http,
        listen => Listen,
        url => maps:get(url, Opts, undefined),
        engine => #{
            base_path => Base,
            card_path => maps:get(card_path, Opts, barrel_a2a:well_known_card_path()),
            card_cache_max_age => maps:get(card_cache_max_age, Opts, 3600),
            hsts => maps:get(hsts, Opts, Tls),
            keepalive_ms => maps:get(keepalive_ms, Opts, 15000),
            tenant => maps:get(tenant, Opts, undefined)
        }
    },
    Cfg#{push_notify => push_notify_fun(Cfg)}.

required({ok, V}, _) -> V;
required({error, Reason}, Key) -> throw({invalid_option, {Key, Reason}}).

authorize_opt(owner) -> owner;
authorize_opt(any) -> any;
authorize_opt(F) when is_function(F, 2) -> F;
authorize_opt(Other) -> throw({invalid_option, {authorize, Other}}).

task_store_opt(undefined) -> {barrel_a2a_task_store_ets, #{}};
task_store_opt({Mod, O}) when is_atom(Mod), is_map(O) -> {Mod, O};
task_store_opt(Mod) when is_atom(Mod) -> {Mod, #{}};
task_store_opt(Other) -> throw({invalid_option, {task_store, Other}}).

schema_opt(inbound) -> inbound;
schema_opt(strict) -> strict;
schema_opt(all) -> all;
schema_opt(false) -> false;
schema_opt(true) -> inbound;
schema_opt(Other) -> throw({invalid_option, {validate_schema, Other}}).

blocking_opt(infinity) -> infinity;
blocking_opt(Ms) when is_integer(Ms), Ms > 0 -> Ms;
blocking_opt(Other) -> throw({invalid_option, {blocking_timeout, Other}}).

push_opt(false, _) ->
    false;
push_opt(true, Sup) ->
    push_opt(#{}, Sup);
push_opt(Opts, PushSup) when is_map(Opts) ->
    barrel_a2a_push:normalize_opts(Opts#{sup => PushSup});
push_opt(Other, _) ->
    throw({invalid_option, {push_notifications, Other}}).

push_notify_fun(#{push := false}) ->
    undefined;
push_notify_fun(#{push_store := Store, push := Opts}) ->
    _ = Opts,
    fun(TaskId, Event) -> barrel_a2a_push:notify(Store, TaskId, Event) end.

base_path(<<>>) -> <<>>;
base_path(<<"/">>) -> <<>>;
base_path(<<"/", _/binary>> = B) -> string:trim(B, trailing, "/");
base_path(B) when is_binary(B) -> base_path(<<"/", B/binary>>);
base_path(Other) -> throw({invalid_option, {base_path, Other}}).

%%--------------------------------------------------------------------
%% Listener
%%--------------------------------------------------------------------

maybe_listen(#{listen := false} = Cfg) ->
    Cfg;
maybe_listen(#{http := Http, server := Server} = Cfg) ->
    Id = {barrel_a2a_server, Server},
    Handler = fun(Method, Path, Headers, Body, Responder) ->
        barrel_a2a_http_engine:handle(
            Method, Path, Headers, Body, Responder, barrel_a2a_http_engine:config(Server, #{})
        )
    end,
    ListenOpts = maps:with(
        [port, ip, tls, acceptors, max_connections, max_body, body_timeout, handshake_timeout], Http
    ),
    case barrel_a2a_listener_sup:start_listener(Id, ListenOpts, Handler) of
        {ok, Pid} ->
            Port = barrel_a2a_listener:port(Pid),
            Url =
                case maps:get(url, Cfg) of
                    undefined -> default_url(Http, Port);
                    U -> string:trim(U, trailing, "/")
                end,
            Cfg#{listener_id => Id, port => Port, url => Url};
        {error, Reason} ->
            throw({listener, Reason})
    end.

default_url(Http, Port) ->
    Scheme =
        case maps:get(tls, Http, undefined) of
            undefined -> <<"http">>;
            _ -> <<"https">>
        end,
    Host =
        case maps:get(ip, Http, {127, 0, 0, 1}) of
            {0, 0, 0, 0} -> <<"127.0.0.1">>;
            {0, 0, 0, 0, 0, 0, 0, 0} -> <<"[::1]">>;
            Ip when tuple_size(Ip) =:= 8 -> <<"[", (list_to_binary(inet:ntoa(Ip)))/binary, "]">>;
            Ip -> list_to_binary(inet:ntoa(Ip))
        end,
    <<Scheme/binary, "://", Host/binary, ":", (integer_to_binary(Port))/binary>>.

%%--------------------------------------------------------------------
%% Card
%%--------------------------------------------------------------------

finalize_card(#{card_base := Base} = Cfg) ->
    Card0 = with_interfaces(Base, Cfg),
    Card1 = with_capabilities(Card0, Cfg),
    Card =
        case maps:get(signing, Cfg) of
            undefined -> Card1;
            #{key := Key} = S -> barrel_a2a_card_sign:sign(Card1, Key, maps:remove(key, S))
        end,
    Cfg#{
        card => Card,
        card_etag => barrel_a2a_agent_card:etag(Card),
        card_json => barrel_a2a_json:encode(Card)
    }.

with_interfaces(Card, Cfg) ->
    case barrel_a2a_agent_card:interfaces(Card) of
        [_ | _] ->
            Card;
        [] ->
            case maps:get(url, Cfg, undefined) of
                undefined ->
                    Card;
                Url ->
                    Base = maps:get(base_path, Cfg),
                    Tenant = maps:get(tenant, Cfg),
                    V = barrel_a2a:protocol_version(),
                    Ifs = [
                        barrel_a2a_agent_card:interface(
                            <<Url/binary, Base/binary, "/jsonrpc">>,
                            barrel_a2a:binding_jsonrpc(),
                            V,
                            Tenant
                        ),
                        barrel_a2a_agent_card:interface(
                            <<Url/binary, Base/binary, "/v1">>, barrel_a2a:binding_rest(), V, Tenant
                        )
                    ],
                    barrel_a2a_agent_card:with_interfaces(Ifs, Card)
            end
    end.

with_capabilities(Card, Cfg) ->
    Caps0 = barrel_a2a_agent_card:capabilities(Card),
    Caps = Caps0#{
        <<"streaming">> => maps:get(streaming, Cfg),
        <<"pushNotifications">> => maps:get(push, Cfg) =/= false,
        <<"extendedAgentCard">> => maps:get(extended_card, Cfg) =/= undefined
    },
    Card#{<<"capabilities">> => Caps}.
