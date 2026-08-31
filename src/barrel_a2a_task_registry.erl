%%%-------------------------------------------------------------------
%%% @doc The per-server task index (ListTasks, GetTask, lookups).
%%%
%%% Rows live in a `barrel_a2a_task_store' (ETS by default, DETS for
%%% persistence). Each row holds the task process (while it lives),
%%% the latest snapshot, and the owner principal used for authorization
%%% scoping (specification 13.1). Live tasks update their row on every
%%% transition; finished tasks keep their snapshot until `task_ttl'
%%% expires. On open, rows left by a previous run whose task was still
%%% running are marked failed: their workers are gone.
%%%
%%% ListTasks (3.1.4) sorts by status timestamp descending and uses an
%%% opaque cursor `{TimestampMs, TaskId}' for pagination.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_registry).

-export([
    new/0, new/1, close/1, owner/1, insert/2, update/2, delete/2, lookup/2, list/2, expire/2, all/1
]).

-record(row, {
    id :: binary(),
    pid :: pid() | undefined,
    task :: barrel_a2a:task(),
    context_id :: binary() | undefined,
    state :: barrel_a2a:state(),
    status_ms :: integer(),
    owner :: barrel_a2a:principal(),
    finished_ms :: integer() | undefined
}).

-type table() :: barrel_a2a_task_store:handle().
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

-export_type([table/0, entry/0, filter/0]).

%% Both fixed by the specification: "If unspecified, at most 50 tasks
%% will be returned. The minimum value is 1. The maximum value is 100."
-define(DEFAULT_PAGE, 50).
-define(MAX_PAGE, 100).

-spec new() -> table().
new() ->
    {ok, Store} = new({barrel_a2a_task_store_ets, #{}}),
    Store.

%% @doc Open a store and repair rows left by a previous run.
-spec new({module(), map()}) -> {ok, table()} | {error, term()}.
new(Spec) ->
    case barrel_a2a_task_store:open(Spec) of
        {ok, Store} ->
            lists:foreach(fun(Row) -> repair(Store, Row) end, barrel_a2a_task_store:all(Store)),
            {ok, Store};
        {error, _} = E ->
            E
    end.

%% A task whose process is gone cannot continue: terminal rows keep
%% their snapshot, others become failed with an explanatory message.
repair(Store, Map) ->
    Raw = maps:get(pid, Map, undefined),
    #row{state = State, task = Task, owner = Owner, id = Id} = Row = from_map(Map),
    case {barrel_a2a_task_state:is_terminal(State), Raw} of
        {true, undefined} ->
            ok;
        {true, _} ->
            barrel_a2a_task_store:put(Store, to_map(Row#row{pid = undefined}));
        {false, _} ->
            Msg = barrel_a2a_message:agent(<<"Task interrupted by a server restart">>),
            Failed = barrel_a2a_task:set_status(Task, failed, Msg),
            barrel_a2a_task_store:put(
                Store, to_map(to_row(#{id => Id, task => Failed, owner => Owner}))
            )
    end.

-spec close(table()) -> ok.
close(Store) -> barrel_a2a_task_store:close(Store).

%% @doc The process the store depends on, or `undefined'. The server
%% links it and stops when it dies; see the store behaviour.
-spec owner(table()) -> pid() | undefined.
owner(Store) -> barrel_a2a_task_store:owner(Store).

-spec insert(table(), entry()) -> ok.
insert(Tab, Entry) ->
    barrel_a2a_task_store:put(Tab, to_map(to_row(Entry))).

%% @doc Store a new snapshot for a task. Keeps the owner and pid
%% unless the entry carries them.
-spec update(table(), entry()) -> ok.
update(Tab, #{id := Id} = Entry) ->
    case fetch(Tab, Id) of
        {ok, Old} ->
            Merged = to_row(Entry),
            Row = Merged#row{
                owner = maps:get(owner, Entry, Old#row.owner),
                pid = maps:get(pid, Entry, Old#row.pid)
            },
            barrel_a2a_task_store:put(Tab, to_map(Row));
        error ->
            insert(Tab, Entry)
    end.

-spec delete(table(), binary()) -> ok.
delete(Tab, Id) ->
    barrel_a2a_task_store:delete(Tab, Id).

-spec lookup(table(), binary()) -> {ok, entry()} | error.
lookup(Tab, Id) ->
    case fetch(Tab, Id) of
        {ok, Row} -> {ok, from_row(Row)};
        error -> error
    end.

-spec all(table()) -> [entry()].
all(Tab) -> [from_row(R) || R <- rows(Tab)].

%% @doc Filtered, sorted, paginated listing.
-spec list(table(), filter()) ->
    {ok, [entry()], NextToken :: binary(), Total :: non_neg_integer()}
    | {error, invalid_page_token}.
list(Tab, Filter) ->
    case decode_token(maps:get(page_token, Filter, undefined)) of
        error ->
            {error, invalid_page_token};
        {ok, Cursor} ->
            Rows = [R || R <- rows(Tab), matches(R, Filter)],
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
            {ok, [from_row(R) || R <- Page], Next, Total}
    end.

%% @doc Remove finished rows older than `TtlMs'.
-spec expire(table(), non_neg_integer()) -> non_neg_integer().
expire(Tab, TtlMs) ->
    Now = barrel_a2a_time:now_ms(),
    Old = [
        R#row.id
     || #row{finished_ms = F, pid = undefined} = R <- rows(Tab),
        is_integer(F),
        Now - F > TtlMs
    ],
    lists:foreach(fun(Id) -> barrel_a2a_task_store:delete(Tab, Id) end, Old),
    length(Old).

matches(Row, Filter) ->
    owner_ok(Row, maps:get(owner, Filter, any)) andalso
        context_ok(Row, maps:get(context_id, Filter, undefined)) andalso
        state_ok(Row, maps:get(state, Filter, undefined)) andalso
        after_ok(Row, maps:get(after_ms, Filter, undefined)) andalso
        visible_ok(Row, maps:get(visible, Filter, undefined)).

visible_ok(_, undefined) -> true;
visible_ok(Row, Fun) -> Fun(from_row(Row)) =:= true.

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
        pid = maps:get(pid, Entry, undefined),
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

from_row(#row{id = Id, pid = Pid, task = Task, owner = Owner, state = State}) ->
    #{id => Id, pid => Pid, task => Task, owner => Owner, state => State}.

%%--------------------------------------------------------------------
%% Store access
%%--------------------------------------------------------------------

fetch(Tab, Id) ->
    case barrel_a2a_task_store:get(Tab, Id) of
        {ok, Map} -> {ok, from_map(Map)};
        error -> error
    end.

rows(Tab) -> [from_map(M) || M <- barrel_a2a_task_store:all(Tab)].

to_map(#row{} = R) ->
    #{
        id => R#row.id,
        pid => R#row.pid,
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
        pid = live_pid(maps:get(pid, M, undefined)),
        task = maps:get(task, M),
        context_id = maps:get(context_id, M, undefined),
        state = maps:get(state, M),
        status_ms = maps:get(status_ms, M),
        owner = maps:get(owner, M, anonymous),
        finished_ms = maps:get(finished_ms, M, undefined)
    }.

%% A pid read back from a persistent store may belong to a previous
%% run of the node.
live_pid(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> Pid;
        false -> undefined
    end;
live_pid(_) ->
    undefined.
