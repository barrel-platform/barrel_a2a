%%%-------------------------------------------------------------------
%%% @doc The per-server task index (ListTasks, GetTask, lookups).
%%%
%%% An ETS table owned by the server process. Each row holds the task
%%% process (while it lives), the latest snapshot, and the owner
%%% principal used for authorization scoping (specification 13.1).
%%% Live tasks update their row on every transition; finished tasks
%%% keep their snapshot until `task_ttl' expires.
%%%
%%% ListTasks (3.1.4) sorts by status timestamp descending and uses an
%%% opaque cursor `{TimestampMs, TaskId}' for pagination.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_registry).

-export([new/0, insert/2, update/2, delete/2, lookup/2, list/2, expire/2, all/1]).

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

-type table() :: ets:table().
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
    page_size => pos_integer(),
    page_token => binary() | undefined
}.

-export_type([table/0, entry/0, filter/0]).

-define(DEFAULT_PAGE, 50).
-define(MAX_PAGE, 1000).

-spec new() -> table().
new() ->
    ets:new(barrel_a2a_tasks, [set, public, {keypos, #row.id}, {read_concurrency, true}]).

-spec insert(table(), entry()) -> ok.
insert(Tab, Entry) ->
    true = ets:insert(Tab, to_row(Entry)),
    ok.

%% @doc Store a new snapshot for a task. Keeps the owner and pid
%% unless the entry carries them.
-spec update(table(), entry()) -> ok.
update(Tab, #{id := Id} = Entry) ->
    case ets:lookup(Tab, Id) of
        [Old] ->
            Merged = to_row(Entry),
            Row = Merged#row{
                owner = maps:get(owner, Entry, Old#row.owner),
                pid = maps:get(pid, Entry, Old#row.pid)
            },
            true = ets:insert(Tab, Row),
            ok;
        [] ->
            insert(Tab, Entry)
    end.

-spec delete(table(), binary()) -> ok.
delete(Tab, Id) ->
    true = ets:delete(Tab, Id),
    ok.

-spec lookup(table(), binary()) -> {ok, entry()} | error.
lookup(Tab, Id) ->
    case ets:lookup(Tab, Id) of
        [Row] -> {ok, from_row(Row)};
        [] -> error
    end.

-spec all(table()) -> [entry()].
all(Tab) -> [from_row(R) || R <- ets:tab2list(Tab)].

%% @doc Filtered, sorted, paginated listing.
-spec list(table(), filter()) ->
    {ok, [entry()], NextToken :: binary(), Total :: non_neg_integer()}
    | {error, invalid_page_token}.
list(Tab, Filter) ->
    case decode_token(maps:get(page_token, Filter, undefined)) of
        error ->
            {error, invalid_page_token};
        {ok, Cursor} ->
            Rows = [R || R <- ets:tab2list(Tab), matches(R, Filter)],
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
     || #row{finished_ms = F, pid = undefined} = R <- ets:tab2list(Tab),
        is_integer(F),
        Now - F > TtlMs
    ],
    lists:foreach(fun(Id) -> ets:delete(Tab, Id) end, Old),
    length(Old).

matches(Row, Filter) ->
    owner_ok(Row, maps:get(owner, Filter, any)) andalso
        context_ok(Row, maps:get(context_id, Filter, undefined)) andalso
        state_ok(Row, maps:get(state, Filter, undefined)) andalso
        after_ok(Row, maps:get(after_ms, Filter, undefined)).

owner_ok(_, any) -> true;
owner_ok(#row{owner = O}, Owner) -> O =:= Owner.

context_ok(_, undefined) -> true;
context_ok(#row{context_id = C}, Ctx) -> C =:= Ctx.

state_ok(_, undefined) -> true;
state_ok(#row{state = S}, State) -> S =:= State.

after_ok(_, undefined) -> true;
after_ok(#row{status_ms = Ms}, After) -> Ms > After.

newer(#row{status_ms = A, id = IdA}, #row{status_ms = B, id = IdB}) ->
    {A, IdA} > {B, IdB}.

drop_until(Rows, undefined) ->
    Rows;
drop_until(Rows, {Ms, Id}) ->
    lists:dropwhile(fun(#row{status_ms = M, id = I}) -> {M, I} >= {Ms, Id} end, Rows).

split(N, List) when length(List) =< N -> {List, []};
split(N, List) -> lists:split(N, List).

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
