%%%-------------------------------------------------------------------
%%% @doc The request context handed to a handler.
%%%
%%% Accessors describe the incoming request; the action functions
%%% publish task updates through the task process, which validates
%%% every state transition and fans events out to streams and
%%% webhooks. The context is a plain map and may be passed to other
%%% processes: every action is a call to the task process.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_ctx).

-export([
    message/1,
    task/1,
    task_id/1,
    context_id/1,
    configuration/1,
    accepted_output_modes/1,
    metadata/1,
    extensions/1,
    tenant/1,
    principal/1,
    binding/1,
    is_follow_up/1
]).
-export([status/2, status/3, artifact/2, artifact/3, message/2, cancelled/1, resume/1, resume/2]).
-export([new/2]).

-type ctx() :: #{
    task_pid := pid(),
    task_id := binary(),
    context_id := binary(),
    message := barrel_a2a:message(),
    task := barrel_a2a:task() | undefined,
    configuration := map(),
    metadata := map(),
    extensions := [binary()],
    tenant := binary() | undefined,
    principal := barrel_a2a:principal(),
    binding := atom(),
    _ => _
}.

-export_type([ctx/0]).

%% @private
-spec new(pid(), map()) -> ctx().
new(TaskPid, Fields) ->
    maps:merge(
        #{
            task_pid => TaskPid,
            task => undefined,
            configuration => #{},
            metadata => #{},
            extensions => [],
            tenant => undefined,
            principal => anonymous,
            binding => unknown
        },
        Fields
    ).

%% @doc The incoming message.
-spec message(ctx()) -> barrel_a2a:message().
message(#{message := M}) -> M.

%% @doc The task as it was when the handler was invoked: `undefined'
%% for a brand new task, the current snapshot for a follow-up.
-spec task(ctx()) -> barrel_a2a:task() | undefined.
task(#{task := T}) -> T.

-spec is_follow_up(ctx()) -> boolean().
is_follow_up(#{task := T}) -> T =/= undefined.

-spec task_id(ctx()) -> binary().
task_id(#{task_id := Id}) -> Id.

-spec context_id(ctx()) -> binary().
context_id(#{context_id := Id}) -> Id.

%% @doc The `SendMessageConfiguration' of the request (wire keys).
-spec configuration(ctx()) -> map().
configuration(#{configuration := C}) -> C.

-spec accepted_output_modes(ctx()) -> [binary()].
accepted_output_modes(#{configuration := C}) ->
    case maps:get(<<"acceptedOutputModes">>, C, []) of
        L when is_list(L) -> L;
        _ -> []
    end.

%% @doc Request-level metadata (`SendMessageRequest.metadata').
-spec metadata(ctx()) -> map().
metadata(#{metadata := M}) -> M.

%% @doc Extensions active for this request (declared by the card and
%% requested by the client).
-spec extensions(ctx()) -> [binary()].
extensions(#{extensions := E}) -> E.

-spec tenant(ctx()) -> binary() | undefined.
tenant(#{tenant := T}) -> T.

-spec principal(ctx()) -> barrel_a2a:principal().
principal(#{principal := P}) -> P.

-spec binding(ctx()) -> atom().
binding(#{binding := B}) -> B.

%%--------------------------------------------------------------------
%% Actions
%%--------------------------------------------------------------------

%% @doc Publish a state change. `working' may be repeated to attach a
%% progress message.
-spec status(ctx(), barrel_a2a:state()) -> ok | {error, term()}.
status(Ctx, State) -> status(Ctx, State, #{}).

-spec status(ctx(), barrel_a2a:state(), #{message => barrel_a2a:message() | iodata()}) ->
    ok | {error, term()}.
status(#{task_pid := Pid}, State, Opts) ->
    barrel_a2a_task_proc:ctx_status(Pid, State, to_message(maps:get(message, Opts, undefined))).

%% @doc Publish an artifact (or a chunk of one).
-spec artifact(ctx(), barrel_a2a_message:content() | barrel_a2a:artifact()) -> ok | {error, term()}.
artifact(Ctx, Content) -> artifact(Ctx, Content, #{}).

-spec artifact(
    ctx(),
    barrel_a2a_message:content() | barrel_a2a:artifact(),
    #{append => boolean(), last_chunk => boolean(), name => binary(), artifact_id => binary()}
) -> ok | {error, term()}.
artifact(#{task_pid := Pid}, Content, Opts) ->
    Artifact = to_artifact(Content, Opts),
    Flags = #{
        append => maps:get(append, Opts, false),
        last_chunk => maps:get(last_chunk, Opts, false)
    },
    barrel_a2a_task_proc:ctx_artifact(Pid, Artifact, Flags).

%% @doc A progress message without a state change (the task stays
%% `working').
-spec message(ctx(), barrel_a2a:message() | iodata()) -> ok | {error, term()}.
message(Ctx, Content) -> status(Ctx, working, #{message => Content}).

%% @doc True once a cancel request arrived for this task.
-spec cancelled(ctx()) -> boolean().
cancelled(#{task_pid := Pid}) -> barrel_a2a_task_proc:ctx_cancelled(Pid).

%% @doc Continue a task that is `auth_required' without a client
%% message (specification 7.6.1): the handler is invoked again with
%% the original message.
-spec resume(ctx()) -> ok | {error, term()}.
resume(Ctx) -> resume(Ctx, undefined).

-spec resume(ctx(), barrel_a2a:message() | undefined) -> ok | {error, term()}.
resume(#{task_pid := Pid}, Message) -> barrel_a2a_task_proc:ctx_resume(Pid, Message).

to_message(undefined) -> undefined;
to_message(M) when is_map(M) -> M;
to_message(Text) -> barrel_a2a_message:agent(Text).

to_artifact(#{<<"artifactId">> := _} = Artifact, _) ->
    Artifact;
to_artifact(Content, Opts) ->
    Opts1 = maps:with([artifact_id, name, description, metadata, extensions], Opts),
    barrel_a2a_artifact:new(Content, Opts1).
