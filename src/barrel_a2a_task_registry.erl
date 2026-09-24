%%%-------------------------------------------------------------------
%%% @doc The per-server task index (ListTasks, GetTask, lookups).
%%%
%%% Rows live in a `barrel_a2a_task_store' (ETS by default, DETS for
%%% persistence). Each row holds the latest snapshot and the owner
%%% principal used for authorization scoping (specification 13.1). The
%%% task process is not part of the row: a pid only means something on
%%% the node and run that made it, and a store may be persisted,
%%% replicated or shared. It is kept in a table of this node, keyed by
%%% task id, next to the store. Live tasks update their row on every
%%% transition; finished tasks keep their snapshot until `task_ttl'
%%% expires. On open, rows left by a previous run whose task was still
%%% running are marked failed: their workers are gone. With a `resume'
%%% fun (see {@link new/2}) the application may take such a task back
%%% instead, or keep a paused one waiting for its client; its row is
%%% kept and the server starts a process for it.
%%%
%%% ListTasks (3.1.4) sorts by status timestamp descending and uses an
%%% opaque cursor `{TimestampMs, TaskId}' for pagination.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_registry).

-export([
    new/0, new/1, new/2,
    close/1,
    owner/1,
    insert/2,
    update/2,
    delete/2,
    lookup/2,
    list/2,
    expire/2,
    all/1
]).

-record(row, {
    id :: binary(),
    task :: barrel_a2a:task(),
    context_id :: binary() | undefined,
    state :: barrel_a2a:state(),
    status_ms :: integer(),
    owner :: barrel_a2a:principal(),
    finished_ms :: integer() | undefined
}).

-opaque table() :: {barrel_a2a_task_store:handle(), ets:table()}.
-type entry() :: #{
    id := binary(),
    pid := pid() | undefined,
    task := barrel_a2a:task(),
    owner := barrel_a2a:principal(),
    state := barrel_a2a:state()
}.
-type filter() :: #{
    owner => barrel_a2a:principal() | any,
    context_id => binary(),
    state => barrel_a2a:state(),
    after_ms => integer(),
    %% An extra predicate on the entry, for an authorization rule the
    %% other keys cannot express. It runs with them, before the total
    %% is counted and the page is cut, so `totalSize' and
    %% `nextPageToken' describe only rows the caller may see.
    visible => fun((entry()) -> boolean()),
    page_size => pos_integer(),
    page_token => binary() | undefined
}.

%% Asked once per unfinished row on open. Any task may answer `fail'
%% (the default behaviour). A `submitted' or `working' task may answer
%% `{resume, Fun}', where `Fun(Ctx)' answers as a handler does. A
%% paused task (`input_required', `auth_required') may answer `keep':
%% it stays paused and the client's next message continues it.
-type resume() :: fun(
    (barrel_a2a:task()) -> {resume, fun((barrel_a2a_ctx:ctx()) -> term())} | keep | fail
).
-type resumed() :: {binary(), fun((barrel_a2a_ctx:ctx()) -> term()) | keep}.

-export_type([table/0, entry/0, filter/0, resume/0, resumed/0]).

%% Both fixed by the specification: "If unspecified, at most 50 tasks
%% will be returned. The minimum value is 1. The maximum value is 100."
-define(DEFAULT_PAGE, 50).
-define(MAX_PAGE, 100).

-spec new() -> table().
new() ->
    {ok, Tab} = new({barrel_a2a_task_store_ets, #{}}),
    Tab.

%% @doc Open a store and repair rows left by a previous run.
-spec new({module(), map()}) -> {ok, table()} | {error, term()}.
new(Spec) ->
    case new(Spec, undefined) of
        {ok, Tab, []} -> {ok, Tab};
        {error, _} = E -> E
    end.

%% @doc As {@link new/1}, asking `Resume' what to do with each
%% unfinished row. Returns the tasks to resume with their funs, and
%% the paused tasks to keep.
-spec new({module(), map()}, resume() | undefined) ->
    {ok, table(), [resumed()]} | {error, term()}.
new(Spec, Resume) ->
    case barrel_a2a_task_store:open(Spec) of
        {ok, Store} ->
            Pids = ets:new(barrel_a2a_task_pids, [set, public, {read_concurrency, true}]),
            Resumed = lists:foldl(
                fun(Row, Acc) ->
                    case repair(Store, Row, Resume) of
                        {resume, Id, How} -> [{Id, How} | Acc];
                        ok -> Acc
                    end
                end,
                [],
                barrel_a2a_task_store:all(Store)
            ),
            {ok, {Store, Pids}, lists:reverse(Resumed)};
        {error, _} = E ->
            E
    end.

%% No task has a process yet: terminal rows keep their snapshot,
%% others become failed with an explanatory message unless the
%% application resumes them. A row written before 0.2.2 may still carry
%% a `pid'; it is dropped here.
repair(Store, Map, Resume) ->
    #row{state = State, task = Task, id = Id} = Row = from_map(Map),
    case barrel_a2a_task_state:is_terminal(State) of
        true ->
            drop_pid(Store, Map, Row);
        false ->
            case ask_resume(Resume, Id, Task, barrel_a2a_task_state:is_interrupted(State)) of
                fail ->
                    fail_row(Store, Row);
                How ->
                    drop_pid(Store, Map, Row),
                    {resume, Id, How}
            end
    end.

drop_pid(Store, #{pid := _}, Row) -> barrel_a2a_task_store:put(Store, to_map(Row));
drop_pid(_Store, _Map, _Row) -> ok.

%% A paused task waits for its client, so it cannot be run again
%% without one: it may only be kept, and a running one only resumed.
ask_resume(undefined, _Id, _Task, _Paused) ->
    fail;
ask_resume(Resume, Id, Task, Paused) ->
    try Resume(Task) of
        {resume, Fun} when is_function(Fun, 1), not Paused ->
            Fun;
        keep when Paused ->
            keep;
        fail ->
            fail;
        Other ->
            logger:warning("a2a task ~s: resume returned ~0p, failing it", [Id, Other]),
            fail
    catch
        Class:Reason ->
            logger:warning("a2a task ~s: resume crashed ~0p:~0p, failing it", [Id, Class, Reason]),
            fail
    end.

fail_row(Store, #row{id = Id, task = Task, owner = Owner}) ->
    Msg = barrel_a2a_message:agent(<<"Task interrupted by a server restart">>),
    Failed = barrel_a2a_task:set_status(Task, failed, Msg),
    barrel_a2a_task_store:put(Store, to_map(to_row(#{id => Id, task => Failed, owner => Owner}))).

-spec close(table()) -> ok.
close({Store, Pids}) ->
    try
        ets:delete(Pids)
    catch
        error:badarg -> ok
    end,
    barrel_a2a_task_store:close(Store).

%% @doc The process the store depends on, or `undefined'. The server
%% links it and stops when it dies; see the store behaviour.
-spec owner(table()) -> pid() | undefined.
owner({Store, _}) -> barrel_a2a_task_store:owner(Store).

-spec insert(table(), entry()) -> ok.
insert({Store, _} = Tab, #{id := Id} = Entry) ->
    ok = barrel_a2a_task_store:put(Store, to_map(to_row(Entry))),
    set_pid(Tab, Id, Entry).

%% @doc Store a new snapshot for a task. Keeps the owner and pid
%% unless the entry carries them.
-spec update(table(), entry()) -> ok.
update({Store, _} = Tab, #{id := Id} = Entry) ->
    case fetch(Tab, Id) of
        {ok, Old} ->
            Merged = to_row(Entry),
            Row = Merged#row{owner = maps:get(owner, Entry, Old#row.owner)},
            ok = barrel_a2a_task_store:put(Store, to_map(Row)),
            set_pid(Tab, Id, Entry);
        error ->
            insert(Tab, Entry)
    end.

-spec delete(table(), binary()) -> ok.
delete({Store, Pids}, Id) ->
    true = ets:delete(Pids, Id),
    barrel_a2a_task_store:delete(Store, Id).

-spec lookup(table(), binary()) -> {ok, entry()} | error.
lookup(Tab, Id) ->
    case fetch(Tab, Id) of
        {ok, Row} -> {ok, from_row(Tab, Row)};
        error -> error
    end.

-spec all(table()) -> [entry()].
all(Tab) -> [from_row(Tab, R) || R <- rows(Tab)].

%% @doc Filtered, sorted, paginated listing.
-spec list(table(), filter()) ->
    {ok, [entry()], NextToken :: binary(), Total :: non_neg_integer()}
    | {error, invalid_page_token}.
list(Tab, Filter) ->
    case decode_token(maps:get(page_token, Filter, undefined)) of
        error ->
            {error, invalid_page_token};
        {ok, Cursor} ->
            Rows = [R || R <- rows(Tab), matches(Tab, R, Filter)],
            Sorted = lists:sort(fun newer/2, Rows),
            Total = length(Sorted),
            AfterCursor = drop_until(Sorted, Cursor),
            PageSize = page_size(Filter),
            {Page, Rest} = split(PageSize, AfterCursor),
            Next =
                case {Rest, Page} of
                    {[], _} -> <<>>;
                    {_, []} -> <<>>;
                    _ -> encode_token(lists:last(Page))
                end,
            {ok, [from_row(Tab, R) || R <- Page], Next, Total}
    end.

%% @doc Remove finished rows older than `TtlMs'.
-spec expire(table(), non_neg_integer()) -> non_neg_integer().
expire(Tab, TtlMs) ->
    Now = barrel_a2a_time:now_ms(),
    Old = [
        Id
     || #row{id = Id, finished_ms = F} <- rows(Tab),
        is_integer(F),
        Now - F > TtlMs,
        pid(Tab, Id) =:= undefined
    ],
    lists:foreach(fun(Id) -> delete(Tab, Id) end, Old),
    length(Old).

matches(Tab, Row, Filter) ->
    owner_ok(Row, maps:get(owner, Filter, any)) andalso
        context_ok(Row, maps:get(context_id, Filter, undefined)) andalso
        state_ok(Row, maps:get(state, Filter, undefined)) andalso
        after_ok(Row, maps:get(after_ms, Filter, undefined)) andalso
        visible_ok(Tab, Row, maps:get(visible, Filter, undefined)).

visible_ok(_, _, undefined) -> true;
visible_ok(Tab, Row, Fun) -> Fun(from_row(Tab, Row)) =:= true.

owner_ok(_, any) -> true;
owner_ok(#row{owner = O}, Owner) -> O =:= Owner.

context_ok(_, undefined) -> true;
context_ok(#row{context_id = C}, Ctx) -> C =:= Ctx.

state_ok(_, undefined) -> true;
state_ok(#row{state = S}, State) -> S =:= State.

%% The specification says "greater than or equal to" (a2a.proto,
%% status_timestamp_after), so the bound is inclusive.
after_ok(_, undefined) -> true;
after_ok(#row{status_ms = Ms}, After) -> Ms >= After.

newer(#row{status_ms = A, id = IdA}, #row{status_ms = B, id = IdB}) ->
    {A, IdA} > {B, IdB}.

drop_until(Rows, undefined) ->
    Rows;
drop_until(Rows, {Ms, Id}) ->
    lists:dropwhile(fun(#row{status_ms = M, id = I}) -> {M, I} >= {Ms, Id} end, Rows).

split(N, List) when length(List) =< N -> {List, []};
split(N, List) -> lists:split(N, List).

%% The range is enforced by `barrel_a2a_validate' before a request gets
%% here, so this only has to pick the default for an unspecified size.
%% The clamp stays as a floor under a direct caller of the registry.
page_size(Filter) ->
    case maps:get(page_size, Filter, ?DEFAULT_PAGE) of
        N when is_integer(N), N > 0 -> min(N, ?MAX_PAGE);
        _ -> ?DEFAULT_PAGE
    end.

encode_token(#row{status_ms = Ms, id = Id}) ->
    barrel_a2a_id:cursor_encode({Ms, Id}).

decode_token(undefined) ->
    {ok, undefined};
decode_token(<<>>) ->
    {ok, undefined};
decode_token(Token) ->
    case barrel_a2a_id:cursor_decode(Token) of
        {ok, {Ms, Id}} when is_integer(Ms), is_binary(Id) -> {ok, {Ms, Id}};
        _ -> error
    end.

to_row(#{id := Id, task := Task} = Entry) ->
    State = barrel_a2a_task:state(Task),
    Finished =
        case barrel_a2a_task_state:is_terminal(State) of
            true -> barrel_a2a_time:now_ms();
            false -> undefined
        end,
    #row{
        id = Id,
        task = Task,
        context_id = barrel_a2a_task:context_id(Task),
        state = State,
        status_ms = status_ms(Task),
        owner = maps:get(owner, Entry, anonymous),
        finished_ms = Finished
    }.

status_ms(Task) ->
    case barrel_a2a_task:status_timestamp(Task) of
        undefined ->
            barrel_a2a_time:now_ms();
        Iso ->
            case barrel_a2a_time:from_iso(Iso) of
                {ok, Ms} -> Ms;
                error -> barrel_a2a_time:now_ms()
            end
    end.

from_row(Tab, #row{id = Id, task = Task, owner = Owner, state = State}) ->
    #{id => Id, pid => pid(Tab, Id), task => Task, owner => Owner, state => State}.

%%--------------------------------------------------------------------
%% Task processes
%%--------------------------------------------------------------------

%% Written after the row, in the same call, so a reader that sees the
%% process also sees its row (invariants.md, T2).
set_pid({_, Pids}, Id, #{pid := Pid}) when is_pid(Pid) ->
    true = ets:insert(Pids, {Id, Pid}),
    ok;
set_pid({_, Pids}, Id, #{pid := undefined}) ->
    true = ets:delete(Pids, Id),
    ok;
set_pid(_Tab, _Id, _Entry) ->
    ok.

%% A process that died without clearing its entry is not running.
pid({_, Pids}, Id) ->
    case ets:lookup(Pids, Id) of
        [{_, Pid}] ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end;
        [] ->
            undefined
    end.

%%--------------------------------------------------------------------
%% Store access
%%--------------------------------------------------------------------

fetch({Store, _}, Id) ->
    case barrel_a2a_task_store:get(Store, Id) of
        {ok, Map} -> {ok, from_map(Map)};
        error -> error
    end.

rows({Store, _}) -> [from_map(M) || M <- barrel_a2a_task_store:all(Store)].

to_map(#row{} = R) ->
    #{
        id => R#row.id,
        task => R#row.task,
        context_id => R#row.context_id,
        state => R#row.state,
        status_ms => R#row.status_ms,
        owner => R#row.owner,
        finished_ms => R#row.finished_ms
    }.

from_map(M) ->
    #row{
        id = maps:get(id, M),
        task = maps:get(task, M),
        context_id = maps:get(context_id, M, undefined),
        state = maps:get(state, M),
        status_ms = maps:get(status_ms, M),
        owner = maps:get(owner, M, anonymous),
        finished_ms = maps:get(finished_ms, M, undefined)
    }.
