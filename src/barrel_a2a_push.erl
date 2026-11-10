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
%%% With a backing `barrel_a2a_task_store' ({@link open_store/3}, server
%%% option `push_config_store'), every config written to or removed
%%% from the table is written through to it, and the table is filled
%%% from it on open, so configs outlive a restart like their tasks.
%%% The config `token' and `authentication.credentials' never reach
%%% the backing store in clear: with the `secret_key' option they are
%%% sealed with AES-256-GCM, bound to the config's ids, and opened on
%%% load; without it they stay in memory only, and a config that had
%%% them is dropped on the next start, since it could no longer
%%% authenticate to its webhook. A row written in clear by an earlier
%%% release is rewritten on load.
%%%
%%% `notify/3' is the fan-out point the task process calls with each
%%% `StreamResponse': every config of the task gets its own ordered
%%% delivery worker (see {@link barrel_a2a_push_delivery}).
%%%
%%% `validate_url/2' is the SSRF guard (13.2): only `http' and
%%% `https' URLs whose host resolves, and only to public addresses
%%% (not loopback, private, link-local or unspecified), are accepted,
%%% unless the host is allowlisted. `target/2' runs the same check at
%%% delivery time and names the address that passed it, so the
%%% connection goes to that address and a name that later resolves
%%% elsewhere (DNS rebinding) cannot redirect it.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_push).

-export([new_store/0, open_store/3, close_store/1, store_owner/1]).
-export([create/4, get/3, list/4, delete/3, delete_task/2, notify/3]).
-export([validate_url/2, target/2, normalize_opts/1, check_secret_key/1]).
-export([opts/1, take_overflow/2]).

-type store() :: ets:table().
-type opts() :: #{
    allow => fun((binary()) -> boolean()) | [binary()],
    ssrf_guard => boolean(),
    %% 32-byte AES-256-GCM key sealing webhook secrets in the backing
    %% store; with a list the first seals and all are tried on load.
    secret_key => binary() | [binary()],
    %% Replaces DNS resolution of webhook hosts for the SSRF guard.
    resolve => fun((binary()) -> {ok, [inet:ip_address()]} | error),
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

%% Where a delivery connects: the url as given, or the address the
%% guard checked, with the original host for `Host' and TLS.
-type target() :: direct | {pinned, inet:ip_address(), binary()}.

-export_type([store/0, opts/0, target/0]).

-define(DEFAULT_PAGE, 50).
-define(SEAL_VERSION, 1).
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

%% @doc Check the `secret_key' option: absent, a 32-byte binary, or a
%% non-empty list of them.
-spec check_secret_key(map()) -> ok | {error, {secret_key, term()}}.
check_secret_key(#{secret_key := Key}) ->
    case keys(Key) of
        [_ | _] = Keys ->
            case lists:all(fun(K) -> is_binary(K) andalso byte_size(K) =:= 32 end, Keys) of
                true -> ok;
                false -> {error, {secret_key, must_be_32_bytes}}
            end;
        _ ->
            {error, {secret_key, must_be_32_bytes}}
    end;
check_secret_key(_) ->
    ok.

keys(Keys) when is_list(Keys) -> Keys;
keys(Key) -> [Key].

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

%% @doc A store for a server: `Opts' recorded for delivery, and, with a
%% `{Module, Opts}' spec, a backing store the table is loaded from and
%% written through to. `TaskOf(TaskId)' reads the task of a loaded
%% config: a config whose task is gone is dropped. Returns the tasks
%% that are terminal although their configs remain: their final event
%% was never delivered, so the caller sends it again.
-spec open_store(
    {module(), map()} | undefined,
    opts(),
    fun((binary()) -> {ok, barrel_a2a:task()} | error)
) ->
    {ok, store(), [barrel_a2a:task()]} | {error, term()}.
open_store(Spec, Opts, TaskOf) ->
    Store = new_store(),
    true = ets:insert(Store, {opts, Opts}),
    case Spec of
        undefined ->
            {ok, Store, []};
        _ ->
            case barrel_a2a_task_store:open(Spec) of
                {ok, Backing} ->
                    true = ets:insert(Store, {backing, Backing}),
                    {ok, Store, load(Store, Backing, TaskOf)};
                {error, _} = E ->
                    ets:delete(Store),
                    E
            end
    end.

load(Store, Backing, TaskOf) ->
    Opts = opts(Store),
    Unsent = lists:foldl(
        fun(#{id := Id, task_id := TaskId} = Row, Acc) ->
            case {TaskOf(TaskId), unseal(Row, Opts)} of
                {{ok, Task}, {ok, Config, Rewrite}} ->
                    true = ets:insert(Store, {{TaskId, Id}, Config}),
                    _ = Rewrite andalso persist(Backing, Id, TaskId, Config, Opts),
                    case barrel_a2a_task:is_terminal(Task) of
                        true -> Acc#{TaskId => Task};
                        false -> Acc
                    end;
                {{ok, _}, {drop, Why}} ->
                    logger:warning(
                        "a2a push: dropping config ~s of task ~s: ~s", [Id, TaskId, Why]
                    ),
                    barrel_a2a_task_store:delete(Backing, Id),
                    Acc;
                {error, _} ->
                    barrel_a2a_task_store:delete(Backing, Id),
                    Acc
            end
        end,
        #{},
        barrel_a2a_task_store:all(Backing)
    ),
    maps:values(Unsent).

%% @doc Close the backing store, if any. The table goes with its owner.
-spec close_store(store()) -> ok.
close_store(Store) ->
    case backing(Store) of
        undefined -> ok;
        Backing -> barrel_a2a_task_store:close(Backing)
    end.

%% @doc The process the backing store depends on, or `undefined'.
-spec store_owner(store()) -> pid() | undefined.
store_owner(Store) ->
    case backing(Store) of
        undefined -> undefined;
        Backing -> barrel_a2a_task_store:owner(Backing)
    end.

backing(Store) ->
    try ets:lookup(Store, backing) of
        [{backing, Backing}] -> Backing;
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

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
                    write_through(Store, fun(B) -> persist(B, Id, TaskId, Config1, Opts) end),
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
    write_through(Store, fun(B) -> barrel_a2a_task_store:delete(B, Id) end),
    %% The worker reads and clears this itself, but it may be gone.
    _ = ets:delete(Store, {overflow, Id}),
    stop_worker(Store, Id).

%%--------------------------------------------------------------------
%% Secrets at rest
%%--------------------------------------------------------------------

%% The row for the backing store: the config without its secrets, and
%% the secrets sealed under the first key, or `not_persisted'.
persist(Backing, Id, TaskId, Config, Opts) ->
    {Clear, Secrets} = split_secrets(Config),
    Row0 = #{id => Id, task_id => TaskId, config => Clear},
    Row =
        case {map_size(Secrets), maps:get(secret_key, Opts, undefined)} of
            {0, _} -> Row0;
            {_, undefined} -> Row0#{secrets => not_persisted};
            {_, Key} -> Row0#{secrets => seal(hd(keys(Key)), aad(TaskId, Id), Secrets)}
        end,
    barrel_a2a_task_store:put(Backing, Row).

%% `{ok, Config, Rewrite}': `Rewrite' when the row held secrets in
%% clear, written by a release that did not seal them.
unseal(#{secrets := not_persisted}, _) ->
    {drop, <<"its webhook credentials were not persisted (no secret_key)">>};
unseal(#{id := Id, task_id := TaskId, config := Config, secrets := Blob}, Opts) ->
    Keys = keys(maps:get(secret_key, Opts, [])),
    case open(Keys, aad(TaskId, Id), Blob) of
        {ok, Secrets} -> {ok, join_secrets(Config, Secrets), false};
        error -> {drop, <<"its webhook credentials cannot be opened with secret_key">>}
    end;
unseal(#{config := Config}, _) ->
    {_, Secrets} = split_secrets(Config),
    {ok, Config, map_size(Secrets) > 0}.

split_secrets(Config) ->
    {Config1, S1} =
        case maps:take(<<"token">>, Config) of
            {T, C} -> {C, #{token => T}};
            error -> {Config, #{}}
        end,
    case Config1 of
        #{<<"authentication">> := #{<<"credentials">> := Cred} = A} ->
            {Config1#{<<"authentication">> := maps:remove(<<"credentials">>, A)}, S1#{
                credentials => Cred
            }};
        _ ->
            {Config1, S1}
    end.

join_secrets(Config, Secrets) ->
    Config1 =
        case Secrets of
            #{token := T} -> Config#{<<"token">> => T};
            _ -> Config
        end,
    case {Secrets, Config1} of
        {#{credentials := Cred}, #{<<"authentication">> := A}} ->
            Config1#{<<"authentication">> := A#{<<"credentials">> => Cred}};
        _ ->
            Config1
    end.

%% The ids are authenticated data: a sealed blob only opens for the
%% config it was written for.
aad(TaskId, Id) -> <<TaskId/binary, 0, Id/binary>>.

seal(Key, Aad, Secrets) ->
    IV = crypto:strong_rand_bytes(12),
    {Cipher, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, term_to_binary(Secrets), Aad, 16, true
    ),
    <<?SEAL_VERSION, (key_id(Key))/binary, IV/binary, Tag/binary, Cipher/binary>>.

open(Keys, Aad, <<?SEAL_VERSION, KeyId:8/binary, IV:12/binary, Tag:16/binary, Cipher/binary>>) ->
    case [K || K <- Keys, key_id(K) =:= KeyId] of
        [Key | _] ->
            case crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Cipher, Aad, Tag, false) of
                error -> error;
                Plain -> decode_secrets(Plain)
            end;
        [] ->
            error
    end;
open(_, _, _) ->
    error.

decode_secrets(Plain) ->
    try binary_to_term(Plain, [safe]) of
        #{} = Secrets -> {ok, Secrets};
        _ -> error
    catch
        error:badarg -> error
    end.

key_id(Key) ->
    binary:part(crypto:hash(sha256, Key), 0, 8).

write_through(Store, Fun) ->
    case backing(Store) of
        undefined -> ok;
        Backing -> Fun(Backing)
    end.

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
                    hand_off(Store, Id, Pid, Event, Opts);
                error ->
                    case start_worker(Store, Config, Opts) of
                        {ok, Pid} ->
                            true = ets:insert(Store, {{worker, Id}, Pid}),
                            hand_off(Store, Id, Pid, Event, Opts);
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

%% Bounding the worker's own queue is not enough: this runs in the task
%% process and casts, so while the worker is blocked in a POST the
%% events pile up in its mailbox, which it only inspects afterwards.
%% Check the backlog here instead, and when it is full record the
%% overflow in the store rather than sending anything, so the buffer we
%% are bounding does not grow to report that it is full. The worker
%% turns the count into a delivery failure on its next pass, which is
%% what keeps at-least-once honest.
%%
%% Both operations are local and cheap, as invariant T10 requires of
%% anything on this path.
hand_off(Store, Id, Pid, Event, Opts) ->
    case backlog(Pid) < maps:get(max_queue, Opts) of
        true ->
            barrel_a2a_push_delivery:deliver(Pid, Event);
        false ->
            _ = ets:update_counter(Store, {overflow, Id}, 1, {{overflow, Id}, 0}),
            ok
    end.

backlog(Pid) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        undefined -> 0
    end.

%% @doc How many events were dropped before reaching the worker's
%% mailbox since the last call, resetting the count.
-spec take_overflow(store(), binary()) -> non_neg_integer().
take_overflow(Store, Id) ->
    case ets:take(Store, {overflow, Id}) of
        [{_, N}] -> N;
        [] -> 0
    end.

%%--------------------------------------------------------------------
%% URL validation (13.2)
%%--------------------------------------------------------------------

-spec validate_url(binary(), opts()) -> ok | {error, binary()}.
validate_url(Url, Opts) ->
    case target(Url, Opts) of
        {ok, _} -> ok;
        Error -> Error
    end.

%% @doc Check `Url' as `validate_url/2' does and say where to connect.
%% A guarded host name is resolved now; every address must pass and
%% the first is returned, so the caller connects to an address that
%% was checked rather than resolving the name again.
-spec target(binary(), opts()) -> {ok, target()} | {error, binary()}.
target(Url, Opts0) when is_binary(Url) ->
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
target(_, _) ->
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
            {ok, direct};
        false ->
            case maps:get(ssrf_guard, Opts) of
                false -> {ok, direct};
                true -> guard_host(Host, maps:get(userinfo, Parsed, undefined), Opts)
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

guard_host(_Host, UserInfo, _) when UserInfo =/= undefined ->
    {error, <<"url must not carry credentials">>};
guard_host(Host, _, Opts) ->
    case is_local_name(Host) of
        true ->
            {error, <<"url host is not allowed">>};
        false ->
            case inet:parse_address(binary_to_list(Host)) of
                {ok, IP} -> guard_ips([IP], direct);
                {error, _} -> guard_name(Host, Opts)
            end
    end.

guard_name(Host, Opts) ->
    Resolve = maps:get(resolve, Opts, fun resolve/1),
    case Resolve(Host) of
        {ok, [IP | _] = IPs} -> guard_ips(IPs, {pinned, IP, Host});
        _ -> {error, <<"url host does not resolve">>}
    end.

guard_ips(IPs, Target) ->
    case lists:any(fun is_blocked_ip/1, IPs) of
        true -> {error, <<"url host resolves to a blocked address">>};
        false -> {ok, Target}
    end.

is_local_name(<<"localhost">>) -> true;
is_local_name(Host) -> binary:longest_common_suffix([Host, <<".localhost">>]) =:= 10.

resolve(Host) ->
    Str = binary_to_list(Host),
    case {inet:getaddrs(Str, inet), inet:getaddrs(Str, inet6)} of
        {{error, _}, {error, _}} -> error;
        {A, B} -> {ok, addrs(A) ++ addrs(B)}
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
