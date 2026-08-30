%%%-------------------------------------------------------------------
%%% @doc Push notification configuration store (specification 3.1.7
%%% to 3.1.10, 4.3).
%%%
%%% One ETS table per server holds every `TaskPushNotificationConfig'
%%% keyed `{TaskId, ConfigId}', plus the delivery worker of each
%%% config under `{worker, ConfigId}'. The server assigns the config
%%% id on create; configs persist until the task reaches a terminal
%%% state (the worker removes its config after delivering the final
%%% event) or the client deletes them.
%%%
%%% `notify/3' is the fan-out point the task process calls with each
%%% `StreamResponse': every config of the task gets its own ordered
%%% delivery worker (see {@link barrel_a2a_push_delivery}).
%%%
%%% `validate_url/2' is the SSRF guard (13.2): only `http' and
%%% `https' URLs whose host does not resolve to a loopback, private,
%%% link-local or unspecified address are accepted, unless the host
%%% is allowlisted.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_push).

-export([new_store/0, create/4, get/3, list/4, delete/3, delete_task/2, notify/3]).
-export([validate_url/2, normalize_opts/1]).
-export([opts/1]).

-type store() :: ets:table().
-type opts() :: #{
    allow => fun((binary()) -> boolean()) | [binary()],
    ssrf_guard => boolean(),
    require_https => boolean(),
    timeout => pos_integer(),
    max_failures => pos_integer(),
    max_queue => pos_integer(),
    backoff => {pos_integer(), number()},
    max_backoff => pos_integer(),
    http_post => fun(
        (binary(), [{binary(), binary()}], binary()) -> {ok, integer()} | {error, term()}
    ),
    sup => pid()
}.

-export_type([store/0, opts/0]).

-define(DEFAULT_PAGE, 50).
-define(MAX_PAGE, 1000).

%%--------------------------------------------------------------------
%% Options
%%--------------------------------------------------------------------

%% @doc Fill in defaults. Idempotent.
-spec normalize_opts(map()) -> opts().
normalize_opts(Opts) when is_map(Opts) ->
    Defaults = #{
        ssrf_guard => true,
        require_https => false,
        timeout => 15000,
        max_failures => 5,
        max_queue => 1000,
        backoff => {1000, 2},
        max_backoff => 60000
    },
    maps:merge(Defaults, Opts).

%% @doc The options recorded by the last `create/4' on this store,
%% used by `notify/3' to start workers.
-spec opts(store()) -> opts().
opts(Store) ->
    case ets:lookup(Store, opts) of
        [{opts, Opts}] -> Opts;
        [] -> normalize_opts(#{})
    end.

%%--------------------------------------------------------------------
%% Store
%%--------------------------------------------------------------------

-spec new_store() -> store().
new_store() ->
    ets:new(barrel_a2a_push, [ordered_set, public, {read_concurrency, true}]).

%% @doc Create a config for a task. The client-supplied `id' is
%% dropped and a fresh one assigned; `taskId' is set to `TaskId'.
%% Authorization (the task belongs to the caller) is the caller's job.
-spec create(store(), binary(), map(), opts()) ->
    {ok, map()} | {error, barrel_a2a_error:error()}.
create(Store, TaskId, Config, Opts0) when is_map(Config) ->
    Opts = normalize_opts(Opts0),
    case maps:get(<<"url">>, Config, undefined) of
        Url when is_binary(Url) ->
            case validate_url(Url, Opts) of
                ok ->
                    Id = barrel_a2a_id:uuid(),
                    Config1 = Config#{<<"id">> => Id, <<"taskId">> => TaskId},
                    true = ets:insert(Store, {opts, Opts}),
                    true = ets:insert(Store, {{TaskId, Id}, Config1}),
                    {ok, Config1};
                {error, Why} ->
                    {error, barrel_a2a_error:invalid(<<"url">>, Why)}
            end;
        _ ->
            {error, barrel_a2a_error:invalid(<<"url">>, <<"url is required">>)}
    end;
create(_Store, _TaskId, _Config, _Opts) ->
    {error, barrel_a2a_error:invalid(<<"taskPushNotificationConfig">>, <<"must be an object">>)}.

-spec get(store(), binary(), binary()) -> {ok, map()} | error.
get(Store, TaskId, Id) ->
    case ets:lookup(Store, {TaskId, Id}) of
        [{_, Config}] -> {ok, Config};
        [] -> error
    end.

%% @doc Configs of a task sorted by id, paginated with an opaque
%% cursor. An empty next token means the last page.
-spec list(store(), binary(), pos_integer() | undefined, binary() | undefined) ->
    {ok, [map()], binary()} | {error, invalid_page_token}.
list(Store, TaskId, PageSize, PageToken) ->
    case decode_token(PageToken) of
        error ->
            {error, invalid_page_token};
        {ok, Cursor} ->
            All = lists:sort([C || C <- configs(Store, TaskId)]),
            After = drop_until(All, Cursor),
            {Page, Rest} = split(page_size(PageSize), After),
            Next =
                case {Rest, Page} of
                    {[], _} -> <<>>;
                    {_, []} -> <<>>;
                    _ -> barrel_a2a_id:cursor_encode(element(1, lists:last(Page)))
                end,
            {ok, [C || {_, C} <- Page], Next}
    end.

%% @doc Remove a config and stop its worker. Idempotent.
-spec delete(store(), binary(), binary()) -> ok.
delete(Store, TaskId, Id) ->
    true = ets:delete(Store, {TaskId, Id}),
    stop_worker(Store, Id).

%% @doc Remove every config of a task and stop their workers.
-spec delete_task(store(), binary()) -> ok.
delete_task(Store, TaskId) ->
    lists:foreach(
        fun({Id, _}) -> delete(Store, TaskId, Id) end,
        configs(Store, TaskId)
    ).

%% @doc Enqueue an event on the delivery worker of every config of the
%% task, starting workers as needed.
-spec notify(store(), binary(), barrel_a2a:stream_response()) -> ok.
notify(Store, TaskId, Event) ->
    Opts = opts(Store),
    lists:foreach(
        fun({Id, Config}) ->
            case worker(Store, Id) of
                {ok, Pid} ->
                    barrel_a2a_push_delivery:deliver(Pid, Event);
                error ->
                    case start_worker(Store, Config, Opts) of
                        {ok, Pid} ->
                            true = ets:insert(Store, {{worker, Id}, Pid}),
                            barrel_a2a_push_delivery:deliver(Pid, Event);
                        {error, Reason} ->
                            logger:warning(
                                "a2a push: cannot start delivery worker for ~s: ~0p",
                                [Id, Reason]
                            )
                    end
            end
        end,
        configs(Store, TaskId)
    ).

%%--------------------------------------------------------------------
%% URL validation (13.2)
%%--------------------------------------------------------------------

-spec validate_url(binary(), opts()) -> ok | {error, binary()}.
validate_url(Url, Opts0) when is_binary(Url) ->
    Opts = normalize_opts(Opts0),
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = Parsed when is_binary(Host), Host =/= <<>> ->
            case check_scheme(string:lowercase(Scheme), Opts) of
                ok -> check_host(string:lowercase(Host), Parsed, Opts);
                Error -> Error
            end;
        #{scheme := _} ->
            {error, <<"url has no host">>};
        _ ->
            {error, <<"url is not an absolute http(s) url">>}
    end;
validate_url(_, _) ->
    {error, <<"url must be a string">>}.

check_scheme(<<"https">>, _) ->
    ok;
check_scheme(<<"http">>, #{require_https := true}) ->
    {error, <<"url scheme must be https">>};
check_scheme(<<"http">>, _) ->
    ok;
check_scheme(_, _) ->
    {error, <<"url scheme must be http or https">>}.

check_host(Host, Parsed, Opts) ->
    case allowed(Host, Opts) of
        true ->
            ok;
        false ->
            case maps:get(ssrf_guard, Opts) of
                false -> ok;
                true -> guard_host(Host, maps:get(userinfo, Parsed, undefined))
            end
    end.

allowed(Host, #{allow := Fun}) when is_function(Fun, 1) ->
    case Fun(Host) of
        true -> true;
        _ -> false
    end;
allowed(Host, #{allow := Hosts}) when is_list(Hosts) ->
    lists:member(Host, [string:lowercase(H) || H <- Hosts]);
allowed(_, _) ->
    false.

guard_host(_Host, UserInfo) when UserInfo =/= undefined ->
    {error, <<"url must not carry credentials">>};
guard_host(Host, _) ->
    case is_local_name(Host) of
        true ->
            {error, <<"url host is not allowed">>};
        false ->
            case resolve(Host) of
                {ok, IPs} ->
                    case lists:any(fun is_blocked_ip/1, IPs) of
                        true -> {error, <<"url host resolves to a blocked address">>};
                        false -> ok
                    end;
                error ->
                    ok
            end
    end.

is_local_name(<<"localhost">>) -> true;
is_local_name(Host) -> binary:longest_common_suffix([Host, <<".localhost">>]) =:= 10.

resolve(Host) ->
    Str = binary_to_list(Host),
    case inet:parse_address(Str) of
        {ok, IP} ->
            {ok, [IP]};
        {error, _} ->
            case {inet:getaddrs(Str, inet), inet:getaddrs(Str, inet6)} of
                {{error, _}, {error, _}} -> error;
                {A, B} -> {ok, addrs(A) ++ addrs(B)}
            end
    end.

addrs({ok, IPs}) -> IPs;
addrs({error, _}) -> [].

is_blocked_ip({127, _, _, _}) -> true;
is_blocked_ip({10, _, _, _}) -> true;
is_blocked_ip({192, 168, _, _}) -> true;
is_blocked_ip({169, 254, _, _}) -> true;
is_blocked_ip({172, B, _, _}) when B >= 16, B =< 31 -> true;
is_blocked_ip({100, B, _, _}) when B >= 64, B =< 127 -> true;
is_blocked_ip({0, _, _, _}) -> true;
is_blocked_ip({255, 255, 255, 255}) -> true;
is_blocked_ip(IP) when tuple_size(IP) =:= 8 -> is_blocked_ip6(IP);
is_blocked_ip(_) -> false.

is_blocked_ip6({0, 0, 0, 0, 0, 0, 0, 1}) ->
    true;
is_blocked_ip6({0, 0, 0, 0, 0, 0, 0, 0}) ->
    true;
%% IPv4-mapped: check the embedded address.
is_blocked_ip6({0, 0, 0, 0, 0, 16#ffff, AB, CD}) ->
    is_blocked_ip({AB bsr 8, AB band 255, CD bsr 8, CD band 255});
is_blocked_ip6({W, _, _, _, _, _, _, _}) when W >= 16#fe80, W =< 16#febf -> true;
is_blocked_ip6({W, _, _, _, _, _, _, _}) when W >= 16#fc00, W =< 16#fdff -> true;
is_blocked_ip6(_) ->
    false.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

configs(Store, TaskId) ->
    [{Id, C} || {{_, Id}, C} <- ets:match_object(Store, {{TaskId, '_'}, '_'})].

worker(Store, Id) ->
    case ets:lookup(Store, {worker, Id}) of
        [{_, Pid}] ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> error
            end;
        [] ->
            error
    end.

%% Without a supervisor the worker is linked to the caller (tests and
%% embedded use); with one it is a temporary child of the push sup.
start_worker(Store, Config, #{sup := Sup} = Opts) ->
    barrel_a2a_push_sup:start_worker(Sup, [Config, Opts, Store]);
start_worker(Store, Config, Opts) ->
    barrel_a2a_push_delivery:start_link(Config, Opts, Store).

stop_worker(Store, Id) ->
    case ets:lookup(Store, {worker, Id}) of
        [{_, Pid}] ->
            true = ets:delete(Store, {worker, Id}),
            case Pid =:= self() of
                true -> ok;
                false -> barrel_a2a_push_delivery:stop(Pid)
            end;
        [] ->
            ok
    end.

drop_until(Rows, undefined) ->
    Rows;
drop_until(Rows, Cursor) ->
    lists:dropwhile(fun({Id, _}) -> Id =< Cursor end, Rows).

split(N, List) when length(List) =< N -> {List, []};
split(N, List) -> lists:split(N, List).

page_size(N) when is_integer(N), N > 0 -> min(N, ?MAX_PAGE);
page_size(_) -> ?DEFAULT_PAGE.

decode_token(undefined) ->
    {ok, undefined};
decode_token(<<>>) ->
    {ok, undefined};
decode_token(Token) ->
    case barrel_a2a_id:cursor_decode(Token) of
        {ok, Id} when is_binary(Id) -> {ok, Id};
        _ -> error
    end.
