-module(echo_server_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, echo/1]).

all() -> [echo].

echo(_Config) ->
    {ok, Server} = echo_server:start(0),
    try
        {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server)),
        {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"hello">>),
        ?assertEqual(completed, barrel_a2a_task:state(Task)),
        [Artifact] = barrel_a2a_task:artifacts(Task),
        ?assertEqual(<<"hello">>, barrel_a2a_artifact:text(Artifact))
    after
        echo_server:stop(Server)
    end.
