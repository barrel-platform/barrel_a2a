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
%%%
%%% A store backed by a process implements the optional {@link owner/1}
%%% so the server can watch it; see `barrel_a2a_task_store_dets'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_store).

-export([open/1, put/2, get/2, delete/2, all/1, close/1, owner/1]).

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

%% The process the store depends on, if it has one. A store backed by a
%% process must report it: the server links that process and has to
%% notice when it dies, because the store's data usually dies with it.
-callback owner(State :: term()) -> pid() | undefined.

-optional_callbacks([owner/1]).

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

%% @doc The process this store depends on, or `undefined' for a store
%% that is just data. A store that does not implement `owner/1' is
%% taken to have none.
-spec owner(handle()) -> pid() | undefined.
owner({M, S}) ->
    _ = code:ensure_loaded(M),
    case erlang:function_exported(M, owner, 1) of
        true -> M:owner(S);
        false -> undefined
    end.

-spec close(handle()) -> ok.
close({M, S}) -> M:close(S).
