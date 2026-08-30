%%%-------------------------------------------------------------------
%%% @doc Supervisor of task processes for one server.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_sup).

-behaviour(supervisor).

-export([start_link/0, start_task/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

-spec start_task(pid(), map()) -> {ok, pid()} | {error, term()}.
start_task(Sup, Args) ->
    supervisor:start_child(Sup, [Args]).

%% @private
init([]) ->
    Child = #{
        id => task,
        start => {barrel_a2a_task_proc, start_link, []},
        restart => temporary,
        shutdown => 5000
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 100, period => 10}, [Child]}}.
