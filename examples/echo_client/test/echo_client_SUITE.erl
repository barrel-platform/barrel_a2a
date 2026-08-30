-module(echo_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, run/1]).

all() -> [run].

run(_Config) ->
    ?assertEqual({ok, <<"analyse this document">>}, echo_client:run()).
