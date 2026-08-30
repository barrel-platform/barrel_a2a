%%%-------------------------------------------------------------------
%%% @doc Supervisor of one server instance. Its only child is the
%%% server process, which starts and links the task and push delivery
%%% supervisors itself.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_server_inst_sup).

-behaviour(supervisor).

-export([start_link/1, server/1]).
-export([init/1]).

start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

%% @doc The server process of an instance supervisor.
-spec server(pid()) -> pid() | undefined.
server(Sup) ->
    case lists:keyfind(server, 1, supervisor:which_children(Sup)) of
        {server, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

init(Args) ->
    %% The server process owns its task and push supervisors (linked,
    %% started from its init) so no child ever asks this supervisor
    %% for a sibling while it is still starting that child.
    Child = #{
        id => server,
        start => {barrel_a2a_server, start_link, [self(), Args]},
        shutdown => 10000
    },
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [Child]}}.
