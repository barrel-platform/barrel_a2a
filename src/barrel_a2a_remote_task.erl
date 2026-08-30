%%%-------------------------------------------------------------------
%%% @doc A handle on a task running on a remote agent.
%%%
%%% The handle is a process that owns the event stream (or the polling
%%% loop when the agent does not stream), keeps the latest task
%%% snapshot, and hands events to whoever asks:
%%%
%%% - {@link stream_to/2}: push events to a process as
%%%   `{a2a_event, RT, StreamResponse}', then `{a2a_done, RT, Task}'
%%%   or `{a2a_error, RT, Error}'.
%%% - {@link next/2}: pull the next event.
%%% - {@link result/2}: block until the task settles.
%%%
%%% "Settled" means terminal (completed, failed, canceled, rejected)
%%% or interrupted (input_required, auth_required); a direct message
%%% reply also settles the handle, with {@link result/2} returning
%%% `{ok, {message, M}}'.
%%%
%%% == State ==
%%%
%%% See the `#st{}' comments below. The one thing to hold in mind is
%%% that `listeners', `waiters' and `pullers' are three different ways
%%% of waiting on the same stream, one per public entry point, and that
%%% `settled' is what stops the handle answering twice.
%%%
%%% == Neighbours ==
%%%
%%% Created by `barrel_a2a_client' ({@link start/3} for a new task,
%%% {@link attach/3} for one already running). Calls back into
%%% `barrel_a2a_client' for every remote operation.
%%%
%%% Specification: streaming 3.1.2 and 3.1.6, resubscription 3.1.7.
%%%
%%% == Invariants ==
%%%
%%% A transport signals `done' or an error once and only after the last
%%% event; opening a stream is asynchronous, so a failure arrives as a
%%% message; an attached handle must not settle on a paused state it
%%% was already in. See docs/internals/invariants.md, C1 to C3.
%%%
%%% == Testing ==
%%%
%%% Against a started `barrel_a2a' server in the same node: the client
%%% and the transport are real, so the whole path is exercised. The
%%% end-to-end suites do exactly that over both bindings.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_remote_task).

-behaviour(gen_server).

-export([start/3, attach/3]).
-export([
    stream_to/2,
    next/2,
    result/1,
    result/2,
    refresh/1,
    task/1,
    task_id/1,
    context_id/1,
    state/1,
    artifacts/1,
    text/1,
    cancel/1,
    send/2,
    send/3,
    stop/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(POLL_MS, 1000).

-record(st, {
    agent :: barrel_a2a_client:agent(),
    %% The snapshot, folded from every event seen so far, so the handle
    %% can answer without a round trip.
    task :: barrel_a2a:task() | undefined,
    task_id :: binary() | undefined,
    context_id :: binary() | undefined,
    message :: barrel_a2a:message() | undefined,
    %% The transport's stream reference while one is open. Cleared when
    %% the handle settles on a final outcome, kept while the task is
    %% only paused (a paused task may resume server-side).
    stream :: term() | undefined,
    %% Decided once from the card: follow the task over SSE, or poll
    %% GetTask on a timer when the agent does not stream.
    mode :: streaming | polling,
    %% Three ways to be waiting, one per API: `stream_to/2' registers a
    %% listener that is pushed every event; `result/2' blocks a waiter
    %% until the task settles; `next/2' takes one event from `queue',
    %% or parks a puller when it is empty. `queue' only fills while
    %% there is no listener, since a listener consumes events as they
    %% arrive.
    listeners = [] :: [pid()],
    waiters = [] :: [gen_server:from()],
    queue = [] :: [barrel_a2a:stream_response()],
    pullers = [] :: [gen_server:from()],
    %% The handle has an answer: `result/2' returns at once and `next/2'
    %% is at `eof'. Set by a terminal state, by an interrupted one
    %% (input or auth required is an answer to the caller), by a direct
    %% message, or by a stream error. `rearm/1' clears it when the task
    %% goes back to work after a follow-up, so a later `result/2' waits
    %% for the next outcome instead of returning the stale one.
    settled = false :: boolean(),
    %% Set only when the outcome is not the task itself.
    outcome :: undefined | {message, barrel_a2a:message()} | {error, barrel_a2a_error:error()},
    poll_timer :: reference() | undefined,
    initial_request :: barrel_a2a:object() | undefined,
    %% The state a handle attached to with `attach/3'. Without it,
    %% attaching to an already paused task would settle immediately on
    %% its first snapshot and report that pause as the outcome.
    attach_state :: barrel_a2a:state() | undefined
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start a task with a `SendMessageRequest' (built by
%% `barrel_a2a_client:send_request/3').
-spec start(barrel_a2a_client:agent(), barrel_a2a:object(), map()) ->
    {ok, pid()} | {error, barrel_a2a_error:error()}.
start(Agent, Request, Opts) ->
    start_handle(#{agent => Agent, request => Request, opts => Opts}).

%% @doc Attach to an existing task by id.
-spec attach(barrel_a2a_client:agent(), binary(), map()) ->
    {ok, pid()} | {error, barrel_a2a_error:error()}.
attach(Agent, TaskId, Opts) ->
    start_handle(#{agent => Agent, task_id => TaskId, opts => Opts}).

start_handle(Args) ->
    case gen_server:start(?MODULE, Args#{owner => self()}, []) of
        {ok, Pid} -> {ok, Pid};
        {error, {a2a_error, E}} -> {error, E};
        {error, Reason} -> {error, barrel_a2a_error:transport(Reason)}
    end.

-spec stream_to(pid(), pid()) -> ok.
stream_to(RT, Pid) -> gen_server:call(RT, {stream_to, Pid}).

%% @doc Pull the next event; `eof' once the task settled.
-spec next(pid(), timeout()) ->
    {ok, barrel_a2a:stream_response()} | eof | {error, barrel_a2a_error:error() | timeout}.
next(RT, Timeout) ->
    try
        gen_server:call(RT, next, Timeout)
    catch
        exit:{timeout, _} -> give_up(RT)
    end.

-spec result(pid()) -> {ok, barrel_a2a:task() | {message, barrel_a2a:message()}} | {error, term()}.
result(RT) -> result(RT, infinity).

-spec result(pid(), timeout()) ->
    {ok, barrel_a2a:task() | {message, barrel_a2a:message()}} | {error, term()}.
result(RT, Timeout) ->
    try
        gen_server:call(RT, result, Timeout)
    catch
        exit:{timeout, _} -> give_up(RT)
    end.

%% A timed-out `gen_server:call' leaves the caller registered in
%% `pullers' or `waiters', where nothing would ever remove it: the
%% caller is still alive, so no monitor fires. Tell the handle to drop
%% it before returning.
give_up(RT) ->
    gen_server:cast(RT, {give_up, self()}),
    {error, timeout}.

%% @doc Re-fetch the task with GetTask.
-spec refresh(pid()) -> {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
refresh(RT) -> gen_server:call(RT, refresh).

-spec task(pid()) -> barrel_a2a:task() | undefined.
task(RT) -> gen_server:call(RT, task).

-spec task_id(pid()) -> binary() | undefined.
task_id(RT) -> gen_server:call(RT, task_id).

-spec context_id(pid()) -> binary() | undefined.
context_id(RT) -> gen_server:call(RT, context_id).

-spec state(pid()) -> barrel_a2a:state() | undefined.
state(RT) ->
    case task(RT) of
        undefined -> undefined;
        T -> barrel_a2a_task:state(T)
    end.

-spec artifacts(pid()) -> [barrel_a2a:artifact()].
artifacts(RT) ->
    case task(RT) of
        undefined -> [];
        T -> barrel_a2a_task:artifacts(T)
    end.

%% @doc Text of all artifacts, concatenated.
-spec text(pid()) -> binary().
text(RT) ->
    iolist_to_binary([barrel_a2a_artifact:text(A) || A <- artifacts(RT)]).

-spec cancel(pid()) -> {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
cancel(RT) -> gen_server:call(RT, cancel).

%% @doc A follow-up message on the task (for `input_required').
-spec send(pid(), barrel_a2a_message:content() | barrel_a2a:message()) -> ok | {error, term()}.
send(RT, Content) -> send(RT, Content, #{}).

-spec send(pid(), barrel_a2a_message:content() | barrel_a2a:message(), map()) ->
    ok | {error, term()}.
send(RT, Content, Opts) -> gen_server:call(RT, {send, Content, Opts}).

-spec stop(pid()) -> ok.
stop(RT) -> gen_server:stop(RT).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

%% @private
init(#{agent := Agent, owner := Owner} = Args) ->
    _ = erlang:monitor(process, Owner),
    Card = barrel_a2a_client:card(Agent),
    Mode =
        case barrel_a2a_agent_card:supports(Card, streaming) of
            true -> streaming;
            false -> polling
        end,
    St0 = #st{agent = Agent, mode = Mode},
    case Args of
        #{request := Request} -> begin_send(Request, St0);
        #{task_id := TaskId} -> begin_attach(TaskId, St0)
    end.

begin_send(Request, #st{agent = Agent, mode = streaming} = St) ->
    case barrel_a2a_client:stream(Agent, send_streaming_message, Request, self()) of
        {ok, Ref} ->
            {ok, St#st{
                stream = Ref, message = maps:get(<<"message">>, Request), initial_request = Request
            }};
        {error, E} ->
            {stop, {a2a_error, E}}
    end;
begin_send(Request, #st{agent = Agent, mode = polling} = St) ->
    Conf = maps:get(<<"configuration">>, Request, #{}),
    Req = Request#{<<"configuration">> => Conf#{<<"returnImmediately">> => true}},
    case barrel_a2a_client:call(Agent, send_message, Req) of
        {ok, #{<<"task">> := Task}} ->
            St1 = apply_event(barrel_a2a_event:task(Task), St#st{
                message = maps:get(<<"message">>, Request)
            }),
            {ok, schedule_poll(St1)};
        {ok, #{<<"message">> := Message}} ->
            St1 = apply_event(barrel_a2a_event:message(Message), St),
            {ok, St1};
        {ok, Other} ->
            {stop,
                {a2a_error,
                    barrel_a2a_error:new(invalid_agent_response, io_lib:format("~0p", [Other]))}};
        {error, E} ->
            {stop, {a2a_error, E}}
    end.

begin_attach(TaskId, #st{agent = Agent} = St) ->
    case barrel_a2a_client:get_task(Agent, TaskId) of
        {ok, Task} ->
            St0 = apply_event(barrel_a2a_event:task(Task), St),
            Terminal = barrel_a2a_task:is_terminal(Task),
            %% Attaching to a paused task does not settle the handle:
            %% the caller waits for what happens next.
            St1 =
                case Terminal of
                    true ->
                        St0;
                    false ->
                        St0#st{
                            settled = false,
                            outcome = undefined,
                            attach_state = barrel_a2a_task:state(Task)
                        }
                end,
            case {Terminal, St1#st.mode} of
                {true, _} ->
                    {ok, St1};
                {false, streaming} ->
                    Req = #{<<"id">> => TaskId},
                    case barrel_a2a_client:stream(Agent, subscribe_to_task, Req, self()) of
                        {ok, Ref} -> {ok, St1#st{stream = Ref}};
                        {error, E} -> {stop, {a2a_error, E}}
                    end;
                {false, polling} ->
                    {ok, schedule_poll(St1)}
            end;
        {error, E} ->
            {stop, {a2a_error, E}}
    end.

%% @private
handle_call({stream_to, Pid}, _From, #st{listeners = L} = St) ->
    %% Idempotent: registering the same process twice would monitor it
    %% twice and deliver every event to it twice.
    case lists:member(Pid, L) of
        true ->
            {reply, ok, St};
        false ->
            _ = erlang:monitor(process, Pid),
            %% Replay what was queued so far, then live events.
            lists:foreach(fun(Ev) -> Pid ! {a2a_event, self(), Ev} end, St#st.queue),
            St1 = St#st{listeners = [Pid | L], queue = []},
            case St1#st.settled of
                true -> notify_done([Pid], St1);
                false -> ok
            end,
            {reply, ok, St1}
    end;
handle_call(next, _From, #st{queue = [Ev | Rest]} = St) ->
    {reply, {ok, Ev}, St#st{queue = Rest}};
handle_call(next, _From, #st{queue = [], settled = true} = St) ->
    {reply, eof, St};
handle_call(next, From, St) ->
    {noreply, St#st{pullers = St#st.pullers ++ [From]}};
handle_call(result, _From, #st{settled = true} = St) ->
    {reply, outcome(St), St};
handle_call(result, From, St) ->
    {noreply, St#st{waiters = [From | St#st.waiters]}};
handle_call(refresh, _From, #st{task_id = undefined} = St) ->
    {reply, {error, barrel_a2a_error:new(task_not_found, <<"No task yet">>)}, St};
handle_call(refresh, _From, #st{agent = Agent, task_id = Id} = St) ->
    case barrel_a2a_client:get_task(Agent, Id) of
        {ok, Task} -> {reply, {ok, Task}, apply_event(barrel_a2a_event:task(Task), St)};
        {error, _} = E -> {reply, E, St}
    end;
handle_call(task, _From, St) ->
    {reply, St#st.task, St};
handle_call(task_id, _From, St) ->
    {reply, St#st.task_id, St};
handle_call(context_id, _From, St) ->
    {reply, St#st.context_id, St};
handle_call(cancel, _From, #st{task_id = undefined} = St) ->
    {reply, {error, barrel_a2a_error:new(task_not_cancelable, <<"No task yet">>)}, St};
handle_call(cancel, _From, #st{agent = Agent, task_id = Id} = St) ->
    case barrel_a2a_client:cancel(Agent, Id) of
        {ok, Task} -> {reply, {ok, Task}, apply_event(barrel_a2a_event:task(Task), St)};
        {error, _} = E -> {reply, E, St}
    end;
handle_call({send, Content, Opts}, _From, #st{task_id = undefined} = St) ->
    _ = {Content, Opts},
    {reply, {error, barrel_a2a_error:new(task_not_found, <<"No task yet">>)}, St};
handle_call({send, Content, Opts}, _From, #st{task_id = Id, context_id = Ctx} = St) ->
    Agent = St#st.agent,
    SendOpts = Opts#{task_id => Id, context_id => Ctx},
    Request = barrel_a2a_client:send_request(Agent, Content, SendOpts),
    St1 = St#st{settled = false, outcome = undefined},
    case St1#st.mode of
        streaming ->
            _ = cancel_current_stream(St1),
            case barrel_a2a_client:stream(Agent, send_streaming_message, Request, self()) of
                {ok, Ref} -> {reply, ok, St1#st{stream = Ref}};
                {error, _} = E -> {reply, E, St1}
            end;
        polling ->
            Conf = maps:get(<<"configuration">>, Request, #{}),
            Req = Request#{<<"configuration">> => Conf#{<<"returnImmediately">> => true}},
            case barrel_a2a_client:call(Agent, send_message, Req) of
                {ok, #{<<"task">> := Task}} ->
                    {reply, ok, schedule_poll(apply_event(barrel_a2a_event:task(Task), St1))};
                {ok, _} ->
                    {reply, ok, St1};
                {error, _} = E ->
                    {reply, E, St1}
            end
    end;
handle_call(_Other, _From, St) ->
    {reply, {error, unknown_call}, St}.

%% @private
handle_cast({give_up, Pid}, #st{waiters = W, pullers = P} = St) ->
    Mine = fun({Caller, _Tag}) -> Caller =:= Pid end,
    {noreply, St#st{
        waiters = lists:filter(fun(F) -> not Mine(F) end, W),
        pullers = lists:filter(fun(F) -> not Mine(F) end, P)
    }};
handle_cast(_Msg, St) ->
    {noreply, St}.

%% @private
handle_info({a2a_stream, Ref, {event, Ev}}, #st{stream = Ref} = St) ->
    {noreply, apply_event(Ev, St)};
handle_info({a2a_stream, Ref, {error, E}}, #st{stream = Ref} = St) ->
    {noreply, settle({error, E}, St#st{stream = undefined})};
handle_info({a2a_stream, Ref, done}, #st{stream = Ref} = St) ->
    St1 = St#st{stream = undefined},
    case St1#st.settled of
        true ->
            {noreply, St1};
        false ->
            %% The stream closed without a terminal event: fall back to
            %% polling so the caller still gets an outcome.
            {noreply, schedule_poll(St1#st{mode = polling})}
    end;
handle_info({a2a_stream, _, _}, St) ->
    {noreply, St};
handle_info(poll, #st{settled = true} = St) ->
    {noreply, St#st{poll_timer = undefined}};
handle_info(poll, #st{agent = Agent, task_id = Id} = St) when Id =/= undefined ->
    St1 =
        case barrel_a2a_client:get_task(Agent, Id) of
            {ok, Task} -> apply_event(barrel_a2a_event:task(Task), St);
            {error, _} -> St
        end,
    case St1#st.settled of
        true -> {noreply, St1#st{poll_timer = undefined}};
        false -> {noreply, schedule_poll(St1#st{poll_timer = undefined})}
    end;
handle_info(poll, St) ->
    {noreply, schedule_poll(St#st{poll_timer = undefined})};
handle_info({'DOWN', _, process, Pid, _}, #st{listeners = L} = St) ->
    case lists:member(Pid, L) of
        true -> {noreply, St#st{listeners = lists:delete(Pid, L)}};
        false -> {stop, normal, St}
    end;
handle_info(_Other, St) ->
    {noreply, St}.

%% @private
terminate(_Reason, St) ->
    _ = cancel_current_stream(St),
    ok.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

cancel_current_stream(#st{stream = undefined}) ->
    ok;
cancel_current_stream(#st{agent = Agent, stream = Ref}) ->
    try
        barrel_a2a_client:cancel_stream(Agent, Ref)
    catch
        _:_ -> ok
    end,
    ok.

schedule_poll(#st{poll_timer = undefined} = St) ->
    Interval = maps:get(poll_interval_ms, maps:get(opts, St#st.agent, #{}), ?POLL_MS),
    St#st{poll_timer = erlang:send_after(Interval, self(), poll)};
schedule_poll(St) ->
    St.

%% Fold an event into the snapshot, deliver it, settle when final.
apply_event(Ev, St0) ->
    St1 = rearm(fold_event(Ev, St0)),
    St2 = deliver(Ev, St1),
    case barrel_a2a_event:kind(Ev) of
        message ->
            settle({message, barrel_a2a_event:payload(Ev)}, St2);
        _ ->
            case settled_state(St2#st.task) andalso not still_attached(St2) of
                true -> settle(task, St2);
                false -> St2
            end
    end.

%% True while an attached handle still sees the paused state it
%% attached to; cleared as soon as the state moves on.
still_attached(#st{attach_state = undefined}) ->
    false;
still_attached(#st{attach_state = S, task = Task}) ->
    barrel_a2a_task:state(Task) =:= S andalso not barrel_a2a_task_state:is_terminal(S).

fold_event(#{<<"task">> := Task}, St) ->
    St#st{
        task = Task,
        task_id = barrel_a2a_task:id(Task),
        context_id = barrel_a2a_task:context_id(Task)
    };
fold_event(#{<<"statusUpdate">> := #{<<"status">> := Status} = U}, #st{task = T} = St) ->
    Task0 = ensure_task(T, U),
    Task1 = Task0#{<<"status">> => Status},
    Task =
        case maps:get(<<"message">>, Status, undefined) of
            M when is_map(M) -> barrel_a2a_task:add_history(Task1, M);
            _ -> Task1
        end,
    St#st{
        task = Task,
        task_id = barrel_a2a_task:id(Task),
        context_id = barrel_a2a_task:context_id(Task)
    };
fold_event(#{<<"artifactUpdate">> := #{<<"artifact">> := A} = U}, #st{task = T} = St) ->
    Task0 = ensure_task(T, U),
    Append = maps:get(<<"append">>, U, false) =:= true,
    Task = barrel_a2a_task:put_artifact(Task0, A, Append),
    St#st{
        task = Task,
        task_id = barrel_a2a_task:id(Task),
        context_id = barrel_a2a_task:context_id(Task)
    };
fold_event(_, St) ->
    St.

ensure_task(undefined, #{<<"taskId">> := Id} = U) ->
    barrel_a2a_task:new(Id, maps:get(<<"contextId">>, U, <<>>));
ensure_task(Task, _) ->
    Task.

%% A task that resumed after an interruption is live again: waiters
%% registered from now on wait for the next settlement.
rearm(#st{task = Task} = St) when Task =/= undefined ->
    case barrel_a2a_task:state(Task) of
        S when S =:= working; S =:= submitted ->
            St#st{settled = false, outcome = undefined, attach_state = undefined};
        _ ->
            St
    end;
rearm(St) ->
    St.

settled_state(undefined) ->
    false;
settled_state(Task) ->
    S = barrel_a2a_task:state(Task),
    barrel_a2a_task_state:is_terminal(S) orelse barrel_a2a_task_state:is_interrupted(S).

deliver(Ev, #st{listeners = [], pullers = []} = St) ->
    St#st{queue = St#st.queue ++ [Ev]};
deliver(Ev, #st{listeners = [], pullers = [From | Rest]} = St) ->
    gen_server:reply(From, {ok, Ev}),
    St#st{pullers = Rest};
deliver(Ev, #st{listeners = L} = St) ->
    lists:foreach(fun(Pid) -> Pid ! {a2a_event, self(), Ev} end, L),
    St.

settle(Outcome, St) ->
    Outcome1 =
        case Outcome of
            task -> undefined;
            _ -> Outcome
        end,
    St1 = St#st{settled = true, outcome = Outcome1},
    lists:foreach(fun(From) -> gen_server:reply(From, outcome(St1)) end, St1#st.waiters),
    lists:foreach(fun(From) -> gen_server:reply(From, eof) end, St1#st.pullers),
    notify_done(St1#st.listeners, St1),
    %% A paused task may resume without a client message (7.6): keep
    %% the subscription open; only terminal outcomes end it.
    case keep_stream(St1) of
        true ->
            St1#st{waiters = [], pullers = []};
        false ->
            _ = cancel_current_stream(St1),
            St1#st{waiters = [], pullers = [], stream = undefined}
    end.

keep_stream(#st{outcome = undefined, task = Task}) when Task =/= undefined ->
    barrel_a2a_task_state:is_interrupted(barrel_a2a_task:state(Task));
keep_stream(_) ->
    false.

outcome(#st{outcome = {message, M}}) -> {ok, {message, M}};
outcome(#st{outcome = {error, E}}) -> {error, E};
outcome(#st{task = Task}) -> {ok, Task}.

notify_done(Listeners, St) ->
    Msg =
        case outcome(St) of
            {ok, {message, M}} -> {a2a_done, self(), {message, M}};
            {ok, Task} -> {a2a_done, self(), Task};
            {error, E} -> {a2a_error, self(), E}
        end,
    lists:foreach(fun(Pid) -> Pid ! Msg end, Listeners).
