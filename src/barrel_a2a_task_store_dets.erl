%%%-------------------------------------------------------------------
%%% @doc File-backed task store on DETS: tasks survive a restart of the
%%% server or the node. Options: `file' (required, the DETS file path),
%%% `sync' (`true' to fsync after every write, default `false').
%%%
%%% ```
%%% barrel_a2a_server:start(Card, #{
%%%     handler => my_agent,
%%%     task_store => {barrel_a2a_task_store_dets, #{file => "tasks.dets"}}
%%% })
%%% '''
%%%
%%% Each server needs its own file. The table is named after the file
%%% so two servers cannot open the same one.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_store_dets).

-behaviour(barrel_a2a_task_store).

-export([open/1, put/2, get/2, delete/2, all/1, close/1]).

open(#{file := File} = Opts) ->
    Name = list_to_atom("barrel_a2a_tasks_" ++ filename:absname(File)),
    case dets:open_file(Name, [{file, File}, {type, set}, {auto_save, 5000}]) of
        {ok, Tab} -> {ok, {Tab, maps:get(sync, Opts, false) =:= true}};
        {error, _} = E -> E
    end;
open(_) ->
    {error, {missing_option, file}}.

put({Tab, Sync}, #{id := Id} = Row) ->
    ok = dets:insert(Tab, {Id, Row}),
    case Sync of
        true -> dets:sync(Tab);
        false -> ok
    end.

get({Tab, _}, Id) ->
    case dets:lookup(Tab, Id) of
        [{_, Row}] -> {ok, Row};
        _ -> error
    end.

delete({Tab, _}, Id) ->
    dets:delete(Tab, Id).

all({Tab, _}) ->
    dets:foldl(fun({_, Row}, Acc) -> [Row | Acc] end, [], Tab).

close({Tab, _}) ->
    _ = dets:close(Tab),
    ok.
