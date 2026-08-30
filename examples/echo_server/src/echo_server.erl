%%%-------------------------------------------------------------------
%%% @doc The smallest A2A agent: it echoes the text it receives.
%%%
%%% Run it with `rebar3 shell' then `echo_server:start(8080).', and
%%% point any A2A client at http://localhost:8080. The echo_client
%%% example talks to it.
%%% @end
%%%-------------------------------------------------------------------
-module(echo_server).

-export([start/0, start/1, stop/1, card/0]).

card() ->
    barrel_a2a_agent_card:new(#{
        name => <<"Echo Agent">>,
        description => <<"Repeats whatever you say">>,
        version => <<"1.0.0">>,
        skills => [
            #{
                id => <<"echo">>,
                name => <<"Echo">>,
                description => <<"Returns the received text as an artifact">>,
                tags => [<<"demo">>],
                examples => [<<"hello">>]
            }
        ]
    }).

start() -> start(8080).

%% @doc Start on `Port' (0 picks a free port; see
%% `barrel_a2a_server:port/1').
start(Port) ->
    barrel_a2a_server:start(card(), #{
        handler => fun(_Ctx, Message) -> {ok, barrel_a2a_message:text(Message)} end,
        http => #{port => Port}
    }).

stop(Server) -> barrel_a2a_server:stop(Server).
