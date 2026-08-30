%%%-------------------------------------------------------------------
%%% @doc One process per task: the task's state, its subscribers, and
%%% the worker running the application handler.
%%%
%%% == Lifecycle ==
%%%
%%% The process is created by `barrel_a2a_server_core' for a message
%%% that does not address an existing task. It starts unmaterialized:
%%% no registry row, no `Task' event yet. The first `barrel_a2a_ctx'
%%% call, a handler result other than `{message, _}', or an explicit
%%% {@link materialize/1} (blocking callers that must answer with a
%%% task) materializes it: the row is written and every subscriber
%%% receives the `Task' snapshot first, as the streaming rules
%%% require (3.1.2, 3.1.6). A handler that returns `{message, M}'
%%% before materializing produces a direct message reply and the
%%% process exits.
%%%
%%% Every transition goes through `barrel_a2a_task_state:transition/2'.
%%% Events are sent to subscribers as `{a2a_task_event, TaskId,
%%% StreamResponse}' in order; a direct message reply as the same
%%% message with a `message' event; a protocol error raised by the
%%% handler before materialization as `{a2a_task_error, TaskId,
%%% Error}'. Subscribers are monitored and dropped when they exit.
%%%
%%% Follow-up messages while the handler is running are queued and
%%% delivered one at a time once it returns, so `handle_message' is
%%% never concurrent for one task.
%%%
%%% The process exits `normal' shortly after the task reaches a
%%% terminal state; the registry keeps the snapshot for GetTask.
%%%
%%% == Neighbours ==
%%%
%%% Started by `barrel_a2a_task_sup' on behalf of
%%% `barrel_a2a_server_core', which is also its only caller. Calls
%%% `barrel_a2a_task_state' for every transition, `barrel_a2a_task' and
%%% `barrel_a2a_event' to build wire objects, `barrel_a2a_handler' to
%%% invoke the application, and `barrel_a2a_task_registry' to publish
%%% the row.
%%%
%%% Specification: task lifecycle 7, streaming 3.1.2 and 3.1.6,
%%% cancellation 3.1.4.
%%%
%%% == Invariants ==
%%%
%%% This process is the only writer of its task row; the row is written
%%% before the matching event is published; nothing is published after a
%%% terminal event; the linger before exit is load-bearing. See
%%% docs/internals/invariants.md, T2 to T10.
%%%
%%% == Testing ==
%%%
%%% Start one directly with {@link start_link/1}, subscribe, then
%%% {@link run/1}, and assert on the `{a2a_task_event, ...}' messages.
%%% The `cfg' it needs is only the three keys of
%%% `barrel_a2a_server_core:task_cfg()', so no server is required.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_proc).

-behaviour(gen_server).

-export([start_link/1, run/1, materialize/1]).
-export([subscribe/2, unsubscribe/2, get_task/1, send_message/3, cancel/2, await/2]).
-export([ctx_status/3, ctx_artifact/3, ctx_cancelled/1, ctx_resume/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LINGER_MS, 100).
-define(CANCEL_GRACE_MS, 5000).
-define(DEFAULT_MAX_QUEUE, 100).

-record(st, {
    cfg :: barrel_a2a_server_core:task_cfg(),
    %% The task as the protocol sees it. This process is its only
    %% writer (see docs/internals/invariants.md, T9).
    task :: barrel_a2a:task(),
    task_id :: binary(),
    context_id :: binary(),
    %% The principal that created the task; authorization scoping
    %% compares against it.
    owner :: barrel_a2a:principal(),
    %% The request context of the message being handled, replayed into
    %% every ctx the handler receives.
    req :: barrel_a2a_server_core:task_req(),
    %% False until the task exists for the outside world: no registry
    %% row, no `Task' event, invisible to GetTask and friends. Set by
    %% the first ctx call, by any handler result other than a direct
    %% message, or by an explicit materialize. It decides the wire
    %% shape of the reply, so moving when it flips changes the
    %% protocol without failing a test (ADR 0003).
    materialized = false :: boolean(),
    %% Subscribers to `{a2a_task_event, ...}', each monitored so a
    %% dead one is dropped.
    subscribers = #{} :: #{pid() => reference()},
    %% The handler worker, if one is running. The reference is the
    %% staleness guard: a result carrying any other one belongs to a
    %% worker that was killed during cancel and is discarded.
    worker = undefined :: undefined | {pid(), reference(), barrel_a2a:message()},
    %% Follow-up messages that arrived while a worker was running.
    %% Drained one at a time, so a handler is never concurrent for one
    %% task.
    queue = [] :: [{barrel_a2a:message(), barrel_a2a_server_core:task_req()}],
    %% Set by a cancel request; a cooperative handler polls it through
    %% `barrel_a2a_ctx:cancelled/1'.
    cancel_requested = false :: boolean(),
    %% The message a resume replays when a paused task continues
    %% without a client message (spec 7.6.1).
    last_message :: barrel_a2a:message(),
    %% Terminal and winding down: the linger timer is armed and no
    %% further message or cancel is accepted.
    done = false :: boolean()
}).

-type args() :: #{
    %% Only the three keys a task needs, not the whole server config.
    cfg := barrel_a2a_server_core:task_cfg(),
    task_id := binary(),
    context_id := binary(),
    message := barrel_a2a:message(),
    owner := barrel_a2a:principal(),
    %% What the request knew, replayed into every handler invocation.
    req := barrel_a2a_server_core:task_req(),
    metadata => map()
}.

-export_type([args/0]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link(args()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% @doc Start the handler. Callers subscribe first so no event is
%% lost.
-spec run(pid()) -> ok.
run(Pid) -> gen_server:cast(Pid, run).

%% @doc Force the task into existence (registry row, `Task' event).
-spec materialize(pid()) -> {ok, barrel_a2a:task()}.
materialize(Pid) -> gen_server:call(Pid, materialize).

%% @doc Register for events. Returns the snapshot when materialized.
-spec subscribe(pid(), pid()) -> {ok, barrel_a2a:task() | undefined}.
subscribe(Pid, Subscriber) -> gen_server:call(Pid, {subscribe, Subscriber}).

-spec unsubscribe(pid(), pid()) -> ok.
unsubscribe(Pid, Subscriber) ->
    try
        gen_server:call(Pid, {unsubscribe, Subscriber})
    catch
        exit:_ -> ok
    end.

-spec get_task(pid()) -> {ok, barrel_a2a:task()}.
get_task(Pid) -> gen_server:call(Pid, get_task).

%% @doc A follow-up message on this task.
-spec send_message(pid(), barrel_a2a:message(), map()) -> ok | {error, barrel_a2a_error:error()}.
send_message(Pid, Message, Req) -> gen_server:call(Pid, {send_message, Message, Req}).

-spec cancel(pid(), map()) -> {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
cancel(Pid, Metadata) -> gen_server:call(Pid, {cancel, Metadata}, ?CANCEL_GRACE_MS + 1000).

%% @doc Block until the task is terminal or interrupted, or a direct
%% message arrives, or `Timeout' elapses. The caller must already be
%% subscribed. Returns the latest snapshot or the direct message.
-spec await(pid(), timeout()) ->
    {task, barrel_a2a:task()} | {message, barrel_a2a:message()} | {error, term()}.
await(Pid, Timeout) ->
    Deadline = deadline(Timeout),
    await_loop(Pid, Deadline).

await_loop(Pid, Deadline) ->
    receive
        {a2a_task_event, _, #{<<"message">> := M}} ->
            {message, M};
        {a2a_task_event, _, #{<<"task">> := T}} ->
            settled_or_wait(Pid, Deadline, barrel_a2a_task:state(T));
        {a2a_task_event, _, #{<<"statusUpdate">> := #{<<"status">> := #{<<"state">> := S}}}} ->
            case barrel_a2a_task_state:from_wire(S) of
                {ok, State} -> settled_or_wait(Pid, Deadline, State);
                error -> await_loop(Pid, Deadline)
            end;
        {a2a_task_event, _, _} ->
            await_loop(Pid, Deadline);
        {a2a_task_error, _, Error} ->
            {error, Error};
        {'DOWN', _, process, Pid, _} ->
            {error, task_process_down}
    after remaining(Deadline) ->
        case materialize_safe(Pid) of
            {ok, T} -> {task, T};
            error -> {error, timeout}
        end
    end.

settled_or_wait(Pid, Deadline, State) ->
    case
        barrel_a2a_task_state:is_terminal(State) orelse barrel_a2a_task_state:is_interrupted(State)
    of
        true ->
            case materialize_safe(Pid) of
                {ok, T} -> {task, T};
                error -> {error, task_process_down}
            end;
        false ->
            await_loop(Pid, Deadline)
    end.

materialize_safe(Pid) ->
    try
        materialize(Pid)
    catch
        exit:_ -> error
    end.

deadline(infinity) -> infinity;
deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.

remaining(infinity) -> infinity;
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% ctx calls
-spec ctx_status(pid(), barrel_a2a:state(), barrel_a2a:message() | undefined) ->
    ok | {error, term()}.
ctx_status(Pid, State, Message) -> gen_server:call(Pid, {ctx_status, State, Message}).

-spec ctx_artifact(pid(), barrel_a2a:artifact(), map()) -> ok | {error, term()}.
ctx_artifact(Pid, Artifact, Flags) -> gen_server:call(Pid, {ctx_artifact, Artifact, Flags}).

-spec ctx_cancelled(pid()) -> boolean().
ctx_cancelled(Pid) ->
    try
        gen_server:call(Pid, ctx_cancelled)
    catch
        exit:_ -> true
    end.

-spec ctx_resume(pid(), barrel_a2a:message() | undefined) -> ok | {error, term()}.
ctx_resume(Pid, Message) -> gen_server:call(Pid, {ctx_resume, Message}).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

%% @private
init(
    #{cfg := Cfg, task_id := Id, context_id := Ctx, message := Msg, owner := Owner, req := Req} = A
) ->
    process_flag(trap_exit, true),
    Task0 = barrel_a2a_task:new(Id, Ctx, #{metadata => maps:get(metadata, A, undefined)}),
    Task = barrel_a2a_task:add_history(Task0, Msg),
    {ok, #st{
        cfg = Cfg,
        task = Task,
        task_id = Id,
        context_id = Ctx,
        owner = Owner,
        req = Req,
        last_message = Msg
    }}.

%% @private
handle_call(materialize, _From, St) ->
    St1 = do_materialize(St),
    {reply, {ok, St1#st.task}, St1};
handle_call({subscribe, Sub}, _From, #st{subscribers = Subs} = St) ->
    Subs1 =
        case maps:is_key(Sub, Subs) of
            true -> Subs;
            false -> Subs#{Sub => erlang:monitor(process, Sub)}
        end,
    Snapshot =
        case St#st.materialized of
            true -> St#st.task;
            false -> undefined
        end,
    {reply, {ok, Snapshot}, St#st{subscribers = Subs1}};
handle_call({unsubscribe, Sub}, _From, #st{subscribers = Subs} = St) ->
    case maps:take(Sub, Subs) of
        {Ref, Subs1} ->
            erlang:demonitor(Ref, [flush]),
            {reply, ok, St#st{subscribers = Subs1}};
        error ->
            {reply, ok, St}
    end;
handle_call(get_task, _From, St) ->
    {reply, {ok, St#st.task}, St};
handle_call({send_message, Message, Req}, _From, St) ->
    State = barrel_a2a_task:state(St#st.task),
    case barrel_a2a_task_state:accepts_messages(State) andalso not St#st.done of
        false ->
            {reply,
                {error,
                    barrel_a2a_error:new(
                        unsupported_operation, <<"Task is in a terminal state">>
                    )},
                St};
        true ->
            queue_message(St, Message, Req)
    end;
handle_call({cancel, Metadata}, _From, St) ->
    State = barrel_a2a_task:state(St#st.task),
    case {State, barrel_a2a_task_state:cancelable(State) andalso not St#st.done} of
        {canceled, _} ->
            %% Idempotent (3.3.1).
            {reply, {ok, St#st.task}, St};
        {_, false} ->
            {reply, {error, barrel_a2a_error:new(task_not_cancelable)}, St};
        {_, true} ->
            St1 = do_materialize(St#st{cancel_requested = true}),
            St2 = stop_worker(St1),
            Msg = cancel_message(Metadata),
            St3 = transition(St2, canceled, Msg),
            {reply, {ok, St3#st.task}, finish(St3#st{queue = []})}
    end;
handle_call({ctx_status, State, Message}, _From, St) ->
    St1 = do_materialize(St),
    case barrel_a2a_task_state:transition(barrel_a2a_task:state(St1#st.task), State) of
        ok ->
            St2 = transition(St1, State, Message),
            {reply, ok, St2};
        {error, _} = E ->
            {reply, E, St1}
    end;
handle_call({ctx_artifact, Artifact, Flags}, _From, St) ->
    St1 = do_materialize(St),
    case barrel_a2a_task:is_terminal(St1#st.task) of
        true ->
            {reply, {error, task_terminal}, St1};
        false ->
            Append = maps:get(append, Flags, false),
            Task = barrel_a2a_task:put_artifact(St1#st.task, Artifact, Append),
            St2 = store(St1#st{task = Task}),
            Ev = barrel_a2a_event:artifact_update(
                St2#st.task_id, St2#st.context_id, Artifact, Flags
            ),
            {reply, ok, publish(St2, Ev)}
    end;
handle_call(ctx_cancelled, _From, St) ->
    {reply, St#st.cancel_requested, St};
handle_call({ctx_resume, Message}, _From, St) ->
    State = barrel_a2a_task:state(St#st.task),
    case {barrel_a2a_task_state:is_interrupted(State), St#st.worker} of
        {true, undefined} ->
            Msg =
                case Message of
                    undefined -> St#st.last_message;
                    _ -> Message
                end,
            St1 = transition(St, working, undefined),
            {reply, ok, start_worker(St1, Msg, St#st.req)};
        {false, _} ->
            {reply, {error, {invalid_transition, State, working}}, St};
        {true, _} ->
            {reply, {error, handler_running}, St}
    end;
handle_call(_Other, _From, St) ->
    {reply, {error, unknown_call}, St}.

%% @private
handle_cast(run, #st{worker = undefined} = St) ->
    {noreply, start_worker(St, St#st.last_message, St#st.req, initial)};
handle_cast(_Other, St) ->
    {noreply, St}.

%% @private
handle_info({worker_result, Ref, Result}, #st{worker = {_, Ref, _}} = St) ->
    {noreply, handle_result(Result, St#st{worker = undefined})};
handle_info({'EXIT', Pid, Reason}, #st{worker = {Pid, _, _}} = St) ->
    case Reason of
        normal ->
            %% Result message is already in the mailbox or was handled.
            {noreply, St};
        killed when St#st.cancel_requested ->
            {noreply, St#st{worker = undefined}};
        _ ->
            logger:error("a2a task ~s handler crashed: ~0p", [St#st.task_id, Reason]),
            Msg = barrel_a2a_message:agent(<<"Handler crashed">>),
            {noreply, handle_result({error, Msg}, St#st{worker = undefined})}
    end;
handle_info({'EXIT', _Other, _Reason}, St) ->
    {noreply, St};
handle_info({'DOWN', Ref, process, Pid, _}, #st{subscribers = Subs} = St) ->
    case maps:get(Pid, Subs, undefined) of
        Ref -> {noreply, St#st{subscribers = maps:remove(Pid, Subs)}};
        _ -> {noreply, St}
    end;
handle_info(linger_done, St) ->
    {stop, normal, St};
handle_info(_Other, St) ->
    {noreply, St}.

%% @private
terminate(_Reason, #st{materialized = true} = St) ->
    %% The store may already be gone when the server shuts down.
    try
        registry_update(St, undefined)
    catch
        error:badarg -> ok
    end,
    ok;
terminate(_Reason, _St) ->
    ok.

%%--------------------------------------------------------------------
%% Worker
%%--------------------------------------------------------------------

start_worker(St, Message, Req) ->
    start_worker(St, Message, Req, follow_up).

%% `initial' invocations see no task in the context even when the task
%% was materialized before the handler ran (returnImmediately).
start_worker(St, Message, Req, Kind) ->
    Self = self(),
    Ref = make_ref(),
    Ctx = make_ctx(St, Message, Req, Kind),
    Handler = maps:get(handler, St#st.cfg),
    Pid = spawn_link(fun() ->
        Result =
            try
                barrel_a2a_handler:invoke(Handler, Ctx, Message)
            catch
                throw:{a2a_error, #{type := _} = Err} -> {error, Err};
                Class:Reason:Stack -> {crash, Class, Reason, Stack}
            end,
        Self ! {worker_result, Ref, Result}
    end),
    St#st{worker = {Pid, Ref, Message}}.

make_ctx(St, Message, Req) ->
    make_ctx(St, Message, Req, follow_up).

make_ctx(St, Message, Req, Kind) ->
    barrel_a2a_ctx:new(self(), #{
        task_id => St#st.task_id,
        context_id => St#st.context_id,
        message => Message,
        task => task_for_ctx(St, Kind),
        configuration => maps:get(configuration, Req, #{}),
        metadata => maps:get(metadata, Req, #{}),
        extensions => maps:get(extensions, Req, []),
        tenant => maps:get(tenant, Req, undefined),
        principal => maps:get(principal, Req, St#st.owner),
        binding => maps:get(binding, Req, unknown)
    }).

task_for_ctx(_, initial) -> undefined;
task_for_ctx(#st{materialized = true, task = T}, follow_up) -> T;
task_for_ctx(_, follow_up) -> undefined.

stop_worker(#st{worker = undefined} = St) ->
    St;
stop_worker(#st{worker = {Pid, _Ref, Message}} = St) ->
    Handler = maps:get(handler, St#st.cfg),
    Ctx = make_ctx(St, Message, St#st.req),
    %% This blocks the task process for up to ?CANCEL_GRACE_MS, so
    %% `handle_cancel/1' must never call back into `barrel_a2a_ctx':
    %% the ctx action would sit in a mailbox nobody is reading and time
    %% out (invariants.md, T4).
    {CPid, CRef} = spawn_monitor(fun() -> barrel_a2a_handler:invoke_cancel(Handler, Ctx) end),
    receive
        {'DOWN', CRef, process, CPid, _} -> ok
    after ?CANCEL_GRACE_MS ->
        exit(CPid, kill)
    end,
    %% Unlink before kill. The worker is linked, so killing it while
    %% still linked would deliver an exit signal here and turn a
    %% deliberate cancel into a failed task (invariants.md, T5).
    unlink(Pid),
    exit(Pid, kill),
    St#st{worker = undefined}.

%% Follow-ups pile up here while a worker runs, one task at a time, so
%% a client that sends faster than the handler works would grow this
%% list without limit. Refuse rather than drop: a dropped message is a
%% message the client believes was accepted.
queue_message(#st{queue = Q, cfg = Cfg} = St, Message, Req) ->
    case length(Q) >= maps:get(max_task_queue, Cfg, ?DEFAULT_MAX_QUEUE) of
        true ->
            {reply,
                {error,
                    barrel_a2a_error:new(
                        rate_limited, <<"Too many messages queued on this task">>
                    )},
                St};
        false ->
            St1 = do_materialize(St),
            Task = barrel_a2a_task:add_history(St1#st.task, Message),
            St2 = store(St1#st{task = Task, last_message = Message}),
            {reply, ok, maybe_start_worker(St2#st{queue = Q ++ [{Message, Req}]})}
    end.

maybe_start_worker(#st{worker = undefined, queue = [{Msg, Req} | Rest]} = St) ->
    State = barrel_a2a_task:state(St#st.task),
    St1 =
        case barrel_a2a_task_state:transition(State, working) of
            ok when State =/= working -> transition(St, working, undefined);
            _ -> St
        end,
    start_worker(St1#st{queue = Rest}, Msg, Req);
maybe_start_worker(St) ->
    St.

%%--------------------------------------------------------------------
%% Results
%%--------------------------------------------------------------------

handle_result({message, Message}, #st{materialized = false} = St) ->
    Msg = decorate(Message, St),
    St1 = publish(St, barrel_a2a_event:message(Msg)),
    finish(St1#st{done = true});
handle_result({message, Message}, St) ->
    complete(St, decorate(Message, St));
handle_result({ok, Result}, St) ->
    St1 = do_materialize(St),
    Artifact = to_artifact(Result),
    Task = barrel_a2a_task:put_artifact(St1#st.task, Artifact, false),
    St2 = store(St1#st{task = Task}),
    Ev = barrel_a2a_event:artifact_update(St2#st.task_id, St2#st.context_id, Artifact, #{
        last_chunk => true
    }),
    complete(publish(St2, Ev), undefined);
handle_result({input_required, M}, St) ->
    interrupt(St, input_required, M);
handle_result({auth_required, M}, St) ->
    interrupt(St, auth_required, M);
handle_result({reject, M}, St) ->
    St1 = do_materialize(St),
    after_result(transition(St1, rejected, to_message(M, St1)));
handle_result(ok, St) ->
    St1 = do_materialize(St),
    case barrel_a2a_task:state(St1#st.task) of
        S when S =:= working; S =:= submitted -> complete(St1, undefined);
        _ -> after_result(St1)
    end;
handle_result({error, #{type := _} = Err}, #st{materialized = false} = St) ->
    send_all(St, {a2a_task_error, St#st.task_id, Err}),
    finish(St#st{done = true});
handle_result({error, #{type := _, message := Text}}, St) ->
    fail(St, barrel_a2a_message:agent(Text));
handle_result({error, Reason}, St) ->
    fail(St, to_message(Reason, St));
handle_result({crash, Class, Reason, Stack}, St) ->
    logger:error("a2a task ~s handler crashed: ~0p:~0p~n~p", [St#st.task_id, Class, Reason, Stack]),
    fail(St, barrel_a2a_message:agent(<<"Handler crashed">>));
handle_result(Other, St) ->
    logger:error("a2a task ~s handler returned ~0p", [St#st.task_id, Other]),
    fail(St, barrel_a2a_message:agent(<<"Invalid handler result">>)).

complete(St, Message) ->
    St1 = do_materialize(St),
    case barrel_a2a_task:is_terminal(St1#st.task) of
        true -> after_result(St1);
        false -> after_result(transition(St1, completed, Message))
    end.

fail(St, Message) ->
    St1 = do_materialize(St),
    case barrel_a2a_task:is_terminal(St1#st.task) of
        true -> after_result(St1);
        false -> after_result(transition(St1, failed, Message))
    end.

interrupt(St, State, M) ->
    St1 = do_materialize(St),
    case barrel_a2a_task:is_terminal(St1#st.task) of
        true -> after_result(St1);
        false -> after_result(transition(St1, State, to_message(M, St1)))
    end.

%% After a handler returns: run the next queued message, or finish.
after_result(St) ->
    case barrel_a2a_task:is_terminal(St#st.task) of
        true -> finish(St#st{queue = []});
        false -> maybe_start_worker(St)
    end.

%% Terminal: stop, but not immediately. A blocking caller reads the
%% final snapshot from this process after it has already seen the
%% terminal event, so exiting at once turns a completed task into
%% `task_process_down' whenever the caller is descheduled
%% (invariants.md, T3).
finish(St) ->
    St1 = St#st{done = true},
    erlang:send_after(?LINGER_MS, self(), linger_done),
    St1.

to_artifact(#{<<"artifactId">> := _} = A) -> A;
to_artifact(Content) -> barrel_a2a_artifact:new(Content).

to_message(undefined, _) ->
    undefined;
to_message(M, St) when is_map(M) -> decorate(M, St);
to_message(Text, St) when is_binary(Text); is_list(Text) ->
    decorate(barrel_a2a_message:agent(Text), St);
to_message(Other, St) ->
    decorate(barrel_a2a_message:agent(io_lib:format("~0p", [Other])), St).

%% Agent messages carry the task and context ids (4.1.4).
decorate(Message, #st{materialized = true, task_id = Id, context_id = Ctx}) ->
    Message#{<<"taskId">> => Id, <<"contextId">> => Ctx};
decorate(Message, #st{context_id = Ctx}) ->
    maps:remove(<<"taskId">>, Message#{<<"contextId">> => Ctx}).

cancel_message(Metadata) when map_size(Metadata) =:= 0 ->
    barrel_a2a_message:agent(<<"Task canceled">>);
cancel_message(Metadata) ->
    barrel_a2a_message:agent(<<"Task canceled">>, #{metadata => Metadata}).

%%--------------------------------------------------------------------
%% State changes
%%--------------------------------------------------------------------

do_materialize(#st{materialized = true} = St) ->
    St;
do_materialize(St) ->
    St1 = St#st{materialized = true},
    %% Row first, event second: a client that reacts to an event by
    %% calling GetTask must not read a staler state than the event it
    %% just saw (invariants.md, T2).
    registry_update(St1, self()),
    publish(St1, barrel_a2a_event:task(St1#st.task)).

transition(St, State, Message) ->
    Msg =
        case Message of
            undefined -> undefined;
            _ -> decorate(Message, St)
        end,
    Task0 = barrel_a2a_task:set_status(St#st.task, State, Msg),
    Task =
        case Msg of
            undefined -> Task0;
            _ -> barrel_a2a_task:add_history(Task0, Msg)
        end,
    %% Row before event, as in do_materialize/1 (invariants.md, T2).
    St1 = store(St#st{task = Task}),
    Ev = barrel_a2a_event:status_update(
        St1#st.task_id, St1#st.context_id, barrel_a2a_task:status(Task)
    ),
    publish(St1, Ev).

store(#st{materialized = true} = St) ->
    registry_update(St, self()),
    St;
store(St) ->
    St.

registry_update(St, Pid) ->
    Tab = maps:get(registry, St#st.cfg),
    barrel_a2a_task_registry:update(Tab, #{
        id => St#st.task_id,
        pid => Pid,
        task => St#st.task,
        owner => St#st.owner,
        state => barrel_a2a_task:state(St#st.task)
    }).

publish(St, Event) ->
    send_all(St, {a2a_task_event, St#st.task_id, Event}),
    case maps:get(push_notify, St#st.cfg, undefined) of
        undefined ->
            ok;
        Fun ->
            %% Runs inside the task process: the hook must only hand the
            %% event off (it casts to a push worker), never do the HTTP
            %% call itself, or a slow webhook stalls the task
            %% (invariants.md, T10).
            Fun(St#st.task_id, Event)
    end,
    St.

send_all(#st{subscribers = Subs}, Msg) ->
    maps:foreach(fun(Pid, _) -> Pid ! Msg end, Subs).
