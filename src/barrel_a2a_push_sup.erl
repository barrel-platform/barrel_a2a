%%%-------------------------------------------------------------------
%%% @doc Supervisor of push delivery workers.
%%%
%%% A `simple_one_for_one' supervisor; one temporary
%%% {@link barrel_a2a_push_delivery} child per push configuration
%%% with pending events.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_push_sup).

-behaviour(supervisor).

-export([start_link/0, start_worker/2]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

%% @doc Start a delivery worker; `Args' are the arguments of
%% `barrel_a2a_push_delivery:start_link/3'.
-spec start_worker(pid(), [term()]) -> {ok, pid()} | {error, term()}.
start_worker(Sup, Args) ->
    case supervisor:start_child(Sup, Args) of
        {ok, Pid} -> {ok, Pid};
        {ok, Pid, _} -> {ok, Pid};
        {error, _} = Error -> Error
    end.

%% @private
init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{
        id => barrel_a2a_push_delivery,
        start => {barrel_a2a_push_delivery, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker
    },
    {ok, {Flags, [Child]}}.
