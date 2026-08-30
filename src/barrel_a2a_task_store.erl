%%%-------------------------------------------------------------------
%%% @doc Storage behaviour for task rows.
%%%
%%% `barrel_a2a_task_registry' keeps the filtering, ordering and
%%% pagination logic; a store only persists rows keyed by task id. Two
%%% stores ship with the library: `barrel_a2a_task_store_ets' (the
%%% default, in memory) and `barrel_a2a_task_store_dets' (a file,
%%% survives restarts). Configure one with the server option
%%% `task_store => {Module, Opts}'.
%%%
%%% A row is a map: `#{id, pid, task, context_id, state, status_ms,
%%% owner, finished_ms}'. Stores treat it as opaque except for `id'.
%%% Rows loaded by a store after a restart carry the pid of a process
%%% that no longer exists; the registry repairs them on open.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_store).

-export([open/1, put/2, get/2, delete/2, all/1, close/1]).

-type row() :: #{
    id := binary(),
    pid := pid() | undefined,
    task := barrel_a2a:task(),
    context_id := binary() | undefined,
    state := barrel_a2a:state(),
    status_ms := integer(),
    owner := barrel_a2a:principal(),
    finished_ms := integer() | undefined
}.
-type handle() :: {module(), term()}.

-export_type([row/0, handle/0]).

-callback open(Opts :: map()) -> {ok, State :: term()} | {error, term()}.
-callback put(State :: term(), row()) -> ok.
-callback get(State :: term(), binary()) -> {ok, row()} | error.
-callback delete(State :: term(), binary()) -> ok.
-callback all(State :: term()) -> [row()].
-callback close(State :: term()) -> ok.

-spec open({module(), map()}) -> {ok, handle()} | {error, term()}.
open({Module, Opts}) ->
    case Module:open(Opts) of
        {ok, State} -> {ok, {Module, State}};
        {error, _} = E -> E
    end.

-spec put(handle(), row()) -> ok.
put({M, S}, Row) -> M:put(S, Row).

-spec get(handle(), binary()) -> {ok, row()} | error.
get({M, S}, Id) -> M:get(S, Id).

-spec delete(handle(), binary()) -> ok.
delete({M, S}, Id) -> M:delete(S, Id).

-spec all(handle()) -> [row()].
all({M, S}) -> M:all(S).

-spec close(handle()) -> ok.
close({M, S}) -> M:close(S).
