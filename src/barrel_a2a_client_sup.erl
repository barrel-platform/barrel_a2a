%%%-------------------------------------------------------------------
%%% @doc Container for client transport processes.
%%%
%%% One child per connected remote agent, `temporary': the owner holds
%%% the handle and reconnects on its own terms.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_client_sup).

-behaviour(supervisor).

-export([start_link/0, start_transport/2, stop_transport/1, start_child/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start `Module:start_link(Args)' under this supervisor.
-spec start_transport(module(), term()) -> {ok, pid()} | {error, term()}.
start_transport(Module, Args) ->
    supervisor:start_child(?MODULE, [Module, Args]).

-spec stop_transport(pid()) -> ok | {error, not_found}.
stop_transport(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

%% @private
start_child(Module, Args) ->
    Module:start_link(Args).

init([]) ->
    Child = #{
        id => transport,
        start => {?MODULE, start_child, []},
        restart => temporary,
        shutdown => 5000
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 100, period => 60}, [Child]}}.
