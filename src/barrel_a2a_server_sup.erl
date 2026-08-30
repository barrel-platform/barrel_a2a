%%%-------------------------------------------------------------------
%%% @doc Container for server instances.
%%%
%%% Each {@link barrel_a2a_server:start/2} adds one
%%% `barrel_a2a_server_inst_sup' here. Instances are `temporary': a
%%% server that dies takes its tasks with it and the owner decides
%%% whether to start it again.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_server_sup).

-behaviour(supervisor).

-export([start_link/0, start_server/1, stop_server/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_server(map()) -> {ok, pid()} | {error, term()}.
start_server(Args) ->
    supervisor:start_child(?MODULE, [Args]).

-spec stop_server(pid()) -> ok | {error, not_found}.
stop_server(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

%% @private
init([]) ->
    Child = #{
        id => barrel_a2a_server_inst_sup,
        start => {barrel_a2a_server_inst_sup, start_link, []},
        restart => temporary,
        type => supervisor,
        shutdown => infinity
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 60}, [Child]}}.
