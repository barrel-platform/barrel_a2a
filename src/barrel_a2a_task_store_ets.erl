%%%-------------------------------------------------------------------
%%% @doc In-memory task store, the default. Rows live in an ETS table
%%% owned by the server process and vanish with it.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_store_ets).

-behaviour(barrel_a2a_task_store).

-export([open/1, put/2, get/2, delete/2, all/1, close/1, owner/1]).

open(_Opts) ->
    {ok, ets:new(barrel_a2a_tasks, [set, public, {read_concurrency, true}])}.

%% No process of its own: the table is created here, so it belongs to
%% whoever called `open/1' (the server) and dies with it.
owner(_Tab) ->
    undefined.

put(Tab, #{id := Id} = Row) ->
    true = ets:insert(Tab, {Id, Row}),
    ok.

get(Tab, Id) ->
    case ets:lookup(Tab, Id) of
        [{_, Row}] -> {ok, Row};
        [] -> error
    end.

delete(Tab, Id) ->
    true = ets:delete(Tab, Id),
    ok.

all(Tab) ->
    [Row || {_, Row} <- ets:tab2list(Tab)].

close(Tab) ->
    try
        ets:delete(Tab)
    catch
        error:badarg -> ok
    end,
    ok.
