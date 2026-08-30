%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor.
%%%
%%% Two children, both dynamic containers:
%%%
%%% - `barrel_a2a_server_sup': one `barrel_a2a_server_inst_sup' per
%%%   server started with {@link barrel_a2a_server:start/2}.
%%% - `barrel_a2a_listener_sup': listeners started on behalf of
%%%   servers that own their port.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @private
init([]) ->
    Children = [
        #{
            id => barrel_a2a_listener_sup,
            start => {barrel_a2a_listener_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },
        #{
            id => barrel_a2a_server_sup,
            start => {barrel_a2a_server_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        }
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
