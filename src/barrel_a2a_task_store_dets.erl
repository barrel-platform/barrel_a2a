%%%-------------------------------------------------------------------
%%% @doc Persistent task store: ETS in memory, DETS on disk, written
%%% asynchronously, in the spirit of mnesia disc copies.
%%%
%%% Reads and writes go to an ETS table, so the request path never
%%% waits on the disk. A writer process keeps the set of dirty ids and
%%% flushes them to the DETS file every `flush_interval' ms (default
%%% 1000) or as soon as `flush_max' rows are dirty (default 500).
%%% {@link open/1} loads the file into ETS; {@link close/1} flushes and
%%% closes the file. {@link flush/1} forces a flush.
%%%
%%% Options: `file' (required), `flush_interval', `flush_max',
%%% `sync' (`true' makes every write wait for its flush, trading
%%% latency for durability; default `false').
%%%
%%% ```
%%% barrel_a2a_server:start(Card, #{
%%%     handler => my_agent,
%%%     task_store => {barrel_a2a_task_store_dets, #{file => "tasks.dets"}}
%%% })
%%% '''
%%%
%%% One file per server: the DETS table is named after the absolute
%%% file path, so opening the same file twice fails.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_store_dets).

-behaviour(barrel_a2a_task_store).
-behaviour(gen_server).

-export([open/1, put/2, get/2, delete/2, all/1, close/1, owner/1, flush/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(FLUSH_INTERVAL, 1000).
-define(FLUSH_MAX, 500).

-record(st, {
    ets :: ets:table(),
    dets :: dets:tab_name(),
    dirty = #{} :: #{binary() => put | delete},
    interval :: pos_integer(),
    max :: pos_integer(),
    timer = undefined :: reference() | undefined
}).

-type state() :: {ets:table(), pid(), boolean()}.

%%--------------------------------------------------------------------
%% Store callbacks
%%--------------------------------------------------------------------

-spec open(map()) -> {ok, state()} | {error, term()}.
open(#{file := File} = Opts) ->
    case gen_server:start_link(?MODULE, Opts#{file => File}, []) of
        {ok, Writer} ->
            Ets = gen_server:call(Writer, ets),
            {ok, {Ets, Writer, maps:get(sync, Opts, false) =:= true}};
        {error, {shutdown, Reason}} ->
            {error, Reason};
        {error, _} = E ->
            E
    end;
open(_) ->
    {error, {missing_option, file}}.

put({Ets, Writer, Sync}, #{id := Id} = Row) ->
    true = ets:insert(Ets, {Id, Row}),
    mark(Writer, Id, put, Sync).

get({Ets, _, _}, Id) ->
    case ets:lookup(Ets, Id) of
        [{_, Row}] -> {ok, Row};
        [] -> error
    end.

delete({Ets, Writer, Sync}, Id) ->
    true = ets:delete(Ets, Id),
    mark(Writer, Id, delete, Sync).

all({Ets, _, _}) ->
    [Row || {_, Row} <- ets:tab2list(Ets)].

%% The working copy lives in an ETS table the writer creates in its own
%% `init/1', so the writer's death destroys the data. The server links
%% it and stops when it goes.
owner({_, Writer, _}) ->
    Writer.

close({_, Writer, _}) ->
    try
        gen_server:stop(Writer)
    catch
        exit:_ -> ok
    end,
    ok.

%% @doc Write every dirty row to disk now.
-spec flush(state()) -> ok.
flush({_, Writer, _}) ->
    gen_server:call(Writer, flush).

mark(Writer, Id, Op, true) ->
    gen_server:call(Writer, {dirty_sync, Id, Op});
mark(Writer, Id, Op, false) ->
    gen_server:cast(Writer, {dirty, Id, Op}).

%%--------------------------------------------------------------------
%% Writer process
%%--------------------------------------------------------------------

%% @private
init(#{file := File} = Opts) ->
    process_flag(trap_exit, true),
    %% A dets table name is any term, so the absolute path is used
    %% directly. Deriving an atom from it would leak one per distinct
    %% file, and atoms are never collected.
    Name = {?MODULE, filename:absname(File)},
    case dets:open_file(Name, [{file, File}, {type, set}]) of
        {ok, Dets} ->
            Ets = ets:new(barrel_a2a_tasks, [set, public, {read_concurrency, true}]),
            true = ets:insert(Ets, dets:foldl(fun(Obj, Acc) -> [Obj | Acc] end, [], Dets)),
            {ok, #st{
                ets = Ets,
                dets = Dets,
                interval = maps:get(flush_interval, Opts, ?FLUSH_INTERVAL),
                max = maps:get(flush_max, Opts, ?FLUSH_MAX)
            }};
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end.

%% @private
handle_call(ets, _From, St) ->
    {reply, St#st.ets, St};
handle_call(flush, _From, St) ->
    {reply, ok, do_flush(St)};
handle_call({dirty_sync, Id, Op}, _From, St) ->
    St1 = do_flush(St#st{dirty = (St#st.dirty)#{Id => Op}}),
    {reply, ok, St1};
handle_call(_Other, _From, St) ->
    {reply, {error, unknown_call}, St}.

%% @private
handle_cast({dirty, Id, Op}, #st{dirty = Dirty} = St) ->
    St1 = St#st{dirty = Dirty#{Id => Op}},
    case map_size(St1#st.dirty) >= St1#st.max of
        true -> {noreply, do_flush(St1)};
        false -> {noreply, schedule(St1)}
    end;
handle_cast(_Other, St) ->
    {noreply, St}.

%% @private
handle_info(flush, St) ->
    {noreply, do_flush(St#st{timer = undefined})};
handle_info(_Other, St) ->
    {noreply, St}.

%% @private
terminate(_Reason, St) ->
    _ = do_flush(St),
    _ = dets:close(St#st.dets),
    ok.

schedule(#st{timer = undefined, interval = Interval} = St) ->
    St#st{timer = erlang:send_after(Interval, self(), flush)};
schedule(St) ->
    St.

do_flush(#st{dirty = Dirty} = St) when map_size(Dirty) =:= 0 ->
    cancel(St);
do_flush(#st{ets = Ets, dets = Dets, dirty = Dirty} = St) ->
    {Puts, Deletes} = maps:fold(
        fun(Id, Op, {P, D}) ->
            case {Op, ets:lookup(Ets, Id)} of
                {put, [Obj]} -> {[Obj | P], D};
                _ -> {P, [Id | D]}
            end
        end,
        {[], []},
        Dirty
    ),
    ok = dets:insert(Dets, Puts),
    lists:foreach(fun(Id) -> ok = dets:delete(Dets, Id) end, Deletes),
    ok = dets:sync(Dets),
    cancel(St#st{dirty = #{}}).

cancel(#st{timer = undefined} = St) ->
    St;
cancel(#st{timer = T} = St) ->
    _ = erlang:cancel_timer(T),
    St#st{timer = undefined}.
