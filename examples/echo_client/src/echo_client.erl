%%%-------------------------------------------------------------------
%%% @doc Talk to an A2A agent from the shell.
%%%
%%% `echo_client:run(<<"http://localhost:8080">>)' discovers the Agent
%%% Card, prints the skills, sends one message and prints the result.
%%% `run/0' starts the echo_server example on a free port first, so it
%%% works with nothing else running.
%%% @end
%%%-------------------------------------------------------------------
-module(echo_client).

-export([run/0, run/1, run/2]).

run() ->
    {ok, Server} = echo_server:start(0),
    try
        run(barrel_a2a_server:url(Server))
    after
        echo_server:stop(Server)
    end.

run(Url) -> run(Url, <<"analyse this document">>).

run(Url, Text) ->
    {ok, Agent} = barrel_a2a_client:connect(Url),
    Card = barrel_a2a_client:card(Agent),
    io:format("agent: ~s (~s)~n", [
        barrel_a2a_agent_card:name(Card), barrel_a2a_agent_card:version(Card)
    ]),
    lists:foreach(
        fun(Skill) ->
            io:format("skill: ~s: ~s~n", [
                maps:get(<<"id">>, Skill), maps:get(<<"description">>, Skill)
            ])
        end,
        barrel_a2a_client:skills(Agent)
    ),
    case barrel_a2a_client:send(Agent, Text) of
        {ok, {task, Task}} ->
            io:format("task ~s ~p~n", [barrel_a2a_task:id(Task), barrel_a2a_task:state(Task)]),
            Result = iolist_to_binary([
                barrel_a2a_artifact:text(A)
             || A <- barrel_a2a_task:artifacts(Task)
            ]),
            io:format("result: ~s~n", [Result]),
            {ok, Result};
        {ok, {message, Message}} ->
            io:format("reply: ~s~n", [barrel_a2a_message:text(Message)]),
            {ok, barrel_a2a_message:text(Message)};
        {error, Error} ->
            io:format("error: ~p~n", [Error]),
            {error, Error}
    end.
