-module(streaming_server_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, streams/1, asks_for_input/1]).

all() -> [streams, asks_for_input].

streams(_Config) ->
    {ok, Server} = streaming_server:start(0),
    try
        {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server)),
        {ok, RT} = barrel_a2a_client:start(Agent, <<"review these three words">>),
        ok = barrel_a2a_remote_task:stream_to(RT, self()),
        Events = collect(RT),
        ?assert(length(Events) >= 6),
        {ok, Task} = barrel_a2a_remote_task:result(RT, 10000),
        ?assertEqual(completed, barrel_a2a_task:state(Task)),
        ?assertMatch(<<"1/4: review looks fine", _/binary>>, barrel_a2a_remote_task:text(RT))
    after
        streaming_server:stop(Server)
    end.

asks_for_input(_Config) ->
    {ok, Server} = streaming_server:start(0),
    try
        {ok, Agent} = barrel_a2a_client:connect(barrel_a2a_server:url(Server)),
        {ok, {task, Paused}} = barrel_a2a_client:send(Agent, <<"short">>),
        ?assertEqual(input_required, barrel_a2a_task:state(Paused)),
        {ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"a much longer request">>, #{
            task_id => barrel_a2a_task:id(Paused)
        }),
        ?assertEqual(completed, barrel_a2a_task:state(Done))
    after
        streaming_server:stop(Server)
    end.

collect(RT) ->
    receive
        {a2a_event, RT, Ev} -> [Ev | collect(RT)];
        {a2a_done, RT, _} -> []
    after 10000 -> []
    end.
