-module(streaming_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, run/1, run_with_input/1]).

all() -> [run, run_with_input].

run(_Config) ->
    {ok, Text} = streaming_client:run(),
    ?assertMatch(<<"1/4: Review looks fine", _/binary>>, Text).

run_with_input(_Config) ->
    {ok, Server} = streaming_server:start(0),
    try
        {ok, Text} = streaming_client:run(barrel_a2a_server:url(Server), <<"short">>),
        ?assertMatch(<<"1/7: Here looks fine", _/binary>>, Text)
    after
        streaming_server:stop(Server)
    end.
