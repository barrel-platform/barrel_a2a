%%%-------------------------------------------------------------------
%%% @doc Ordered, retried delivery of push notifications for one
%%% `TaskPushNotificationConfig' (specification 4.3.3, 13.2).
%%%
%%% Each event is POSTed as the `StreamResponse' JSON to the config
%%% `url' with `Content-Type: application/a2a+json', the config
%%% `authentication' as an `Authorization' header and the config
%%% `token' as `X-A2A-Notification-Token'. A 2xx acknowledges. Any
%%% other outcome is retried with exponential backoff; after
%%% `max_failures' consecutive failures the config is dropped and the
%%% worker stops. Deliveries for one config are sequential, so the
%%% client sees events in order (at-least-once). The worker also
%%% stops after delivering a final event, removing its config.
%%%
%%% `post/3' does the single HTTP call. An `http_post' fun in the
%%% options replaces hackney, which lets tests run without a network.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_push_delivery).

-behaviour(gen_server).

-export([start_link/3, deliver/2, stop/1, post/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% One worker per push notification configuration.
-record(st, {
    config :: map(),
    opts :: barrel_a2a_push:opts(),
    store :: barrel_a2a_push:store(),
    %% Events waiting to be delivered. One POST is in flight at a
    %% time, so a webhook sees them in the order the task produced
    %% them.
    queue = queue:new() :: queue:queue(),
    %% Consecutive failures. Reset by any success; at `max_failures'
    %% the configuration is dropped and this worker stops.
    failures = 0 :: non_neg_integer(),
    %% Backoff timer between retries, not a periodic tick.
    timer :: reference() | undefined
}).

-define(TOKEN_HEADER, <<"X-A2A-Notification-Token">>).

-spec start_link(map(), barrel_a2a_push:opts(), barrel_a2a_push:store()) ->
    {ok, pid()} | {error, term()}.
start_link(Config, Opts, Store) ->
    gen_server:start_link(?MODULE, {Config, barrel_a2a_push:normalize_opts(Opts), Store}, []).

-spec deliver(pid(), barrel_a2a:stream_response()) -> ok.
deliver(Pid, Event) ->
    gen_server:cast(Pid, {deliver, Event}).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:cast(Pid, stop).

%% @doc One POST of `Event' to the config url.
-spec post(map(), barrel_a2a:stream_response(), barrel_a2a_push:opts()) ->
    ok | {error, term()}.
post(#{<<"url">> := Url} = Config, Event, Opts0) ->
    Opts = barrel_a2a_push:normalize_opts(Opts0),
    Body = barrel_a2a_json:encode(Event),
    Headers = headers(Config),
    Result =
        case maps:get(http_post, Opts, undefined) of
            undefined -> hackney_post(Url, Headers, Body, maps:get(timeout, Opts));
            Fun when is_function(Fun, 3) -> Fun(Url, Headers, Body)
        end,
    case Result of
        {ok, Status} when Status >= 200, Status < 300 -> ok;
        {ok, Status} -> {error, {http, Status}};
        {error, Reason} -> {error, Reason}
    end.

headers(Config) ->
    Base = [{<<"Content-Type">>, barrel_a2a:media_type()}],
    Auth =
        case maps:get(<<"authentication">>, Config, undefined) of
            #{<<"scheme">> := Scheme} = A when is_binary(Scheme) ->
                Value =
                    case maps:get(<<"credentials">>, A, undefined) of
                        Cred when is_binary(Cred) -> <<Scheme/binary, " ", Cred/binary>>;
                        _ -> Scheme
                    end,
                [{<<"Authorization">>, Value}];
            _ ->
                []
        end,
    Token =
        case maps:get(<<"token">>, Config, undefined) of
            T when is_binary(T) -> [{?TOKEN_HEADER, T}];
            _ -> []
        end,
    Base ++ Auth ++ Token.

hackney_post(Url, Headers, Body, Timeout) ->
    HackneyOpts = [
        with_body,
        {follow_redirect, false},
        {connect_timeout, Timeout},
        {recv_timeout, Timeout}
    ],
    try hackney:request(post, Url, Headers, Body, HackneyOpts) of
        {ok, Status, _RespHeaders, _RespBody} -> {ok, Status};
        {ok, Status, _RespHeaders} -> {ok, Status};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

%% @private
init({Config, Opts, Store}) ->
    {ok, #st{config = Config, opts = Opts, store = Store}}.

%% @private
handle_call(_Req, _From, St) ->
    {reply, {error, unsupported}, St}.

%% @private
handle_cast({deliver, Event}, St) ->
    drain(St#st{queue = enqueue(Event, St)});
handle_cast(stop, St) ->
    {stop, normal, St};
handle_cast(_, St) ->
    {noreply, St}.

%% @private
handle_info({retry, Ref}, #st{timer = Ref} = St) ->
    drain(St#st{timer = undefined});
handle_info(_, St) ->
    {noreply, St}.

%% @private
terminate(_Reason, #st{store = Store, config = #{<<"id">> := Id}}) ->
    case ets:lookup(Store, {worker, Id}) of
        [{_, Pid}] when Pid =:= self() -> ets:delete(Store, {worker, Id});
        _ -> ok
    end,
    ok.

%% A webhook that is slow, or backing off, would otherwise let this
%% queue grow for as long as the task keeps producing events. Past the
%% bound the oldest event goes: push is at-least-once and best effort,
%% and the newest state is the one a receiver actually needs. Dropping
%% deliberately does not count as a failure, or a merely slow endpoint
%% would lose its configuration to `max_failures'.
enqueue(Event, #st{queue = Q, opts = Opts, config = Config}) ->
    Max = maps:get(max_queue, Opts),
    case queue:len(Q) >= Max of
        false ->
            queue:in(Event, Q);
        true ->
            {_, Q1} = queue:out(Q),
            logger:warning(
                "a2a push queue full for config ~s, dropping the oldest of ~b events",
                [maps:get(<<"id">>, Config), Max]
            ),
            queue:in(Event, Q1)
    end.

%% Send queued events one at a time until the queue is empty, a
%% delivery fails (then wait for the backoff timer) or a final event
%% went through.
drain(#st{timer = Ref} = St) when Ref =/= undefined ->
    {noreply, St};
drain(#st{queue = Q} = St) ->
    case queue:out(Q) of
        {empty, _} ->
            {noreply, St};
        {{value, Event}, Q1} ->
            case post(St#st.config, Event, St#st.opts) of
                ok -> delivered(Event, St#st{queue = Q1, failures = 0});
                {error, Reason} -> failed(Reason, St)
            end
    end.

delivered(Event, St) ->
    case barrel_a2a_event:is_final(Event) of
        true ->
            remove_config(St),
            {stop, normal, St};
        false ->
            drain(St)
    end.

failed(Reason, #st{failures = N, opts = Opts, config = Config} = St) ->
    Failures = N + 1,
    Max = maps:get(max_failures, Opts),
    Id = maps:get(<<"id">>, Config),
    case Failures >= Max of
        true ->
            logger:warning(
                "a2a push: dropping config ~s after ~b failed deliveries to ~s: ~0p",
                [Id, Failures, maps:get(<<"url">>, Config), Reason]
            ),
            remove_config(St),
            {stop, normal, St#st{failures = Failures}};
        false ->
            Delay = backoff(Failures, Opts),
            logger:info(
                "a2a push: delivery to ~s failed (~0p), retry in ~b ms",
                [maps:get(<<"url">>, Config), Reason, Delay]
            ),
            Ref = make_ref(),
            _ = erlang:send_after(Delay, self(), {retry, Ref}),
            {noreply, St#st{failures = Failures, timer = Ref}}
    end.

backoff(Failures, Opts) ->
    {Initial, Factor} = maps:get(backoff, Opts),
    Max = maps:get(max_backoff, Opts),
    min(Max, round(Initial * math:pow(Factor, Failures - 1))).

remove_config(#st{store = Store, config = #{<<"id">> := Id, <<"taskId">> := TaskId}}) ->
    barrel_a2a_push:delete(Store, TaskId, Id).
