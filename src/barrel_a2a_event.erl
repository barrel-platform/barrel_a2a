%%%-------------------------------------------------------------------
%%% @doc `StreamResponse' objects (specification 3.2.3, 4.2).
%%%
%%% A stream response wraps exactly one of `task', `message',
%%% `statusUpdate' or `artifactUpdate'. The same shape is the push
%%% notification payload (4.3.3).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_event).

-export([task/1, message/1, status_update/3, status_update/4]).
-export([artifact_update/4, artifact_update/5]).
-export([kind/1, payload/1, task_id/1, context_id/1, is_final/1]).

-type event() :: barrel_a2a:stream_response().
-type kind() :: task | message | status_update | artifact_update | unknown.

-export_type([event/0, kind/0]).

-spec task(barrel_a2a:task()) -> event().
task(Task) -> #{<<"task">> => Task}.

-spec message(barrel_a2a:message()) -> event().
message(Message) -> #{<<"message">> => Message}.

-spec status_update(binary(), binary(), barrel_a2a:task_status()) -> event().
status_update(TaskId, ContextId, Status) ->
    status_update(TaskId, ContextId, Status, #{}).

-spec status_update(binary(), binary(), barrel_a2a:task_status(), map()) -> event().
status_update(TaskId, ContextId, Status, Metadata) ->
    Ev = #{
        <<"taskId">> => TaskId,
        <<"contextId">> => ContextId,
        <<"status">> => Status
    },
    #{<<"statusUpdate">> => with_metadata(Ev, Metadata)}.

-spec artifact_update(binary(), binary(), barrel_a2a:artifact(), #{
    append => boolean(), last_chunk => boolean()
}) -> event().
artifact_update(TaskId, ContextId, Artifact, Flags) ->
    artifact_update(TaskId, ContextId, Artifact, Flags, #{}).

-spec artifact_update(
    binary(),
    binary(),
    barrel_a2a:artifact(),
    #{append => boolean(), last_chunk => boolean()},
    map()
) -> event().
artifact_update(TaskId, ContextId, Artifact, Flags, Metadata) ->
    Ev = #{
        <<"taskId">> => TaskId,
        <<"contextId">> => ContextId,
        <<"artifact">> => Artifact,
        <<"append">> => maps:get(append, Flags, false),
        <<"lastChunk">> => maps:get(last_chunk, Flags, false)
    },
    #{<<"artifactUpdate">> => with_metadata(Ev, Metadata)}.

with_metadata(Ev, Metadata) when map_size(Metadata) =:= 0 -> Ev;
with_metadata(Ev, Metadata) -> Ev#{<<"metadata">> => Metadata}.

-spec kind(event()) -> kind().
kind(#{<<"task">> := _}) -> task;
kind(#{<<"message">> := _}) -> message;
kind(#{<<"statusUpdate">> := _}) -> status_update;
kind(#{<<"artifactUpdate">> := _}) -> artifact_update;
kind(_) -> unknown.

-spec payload(event()) -> barrel_a2a:object() | undefined.
payload(#{<<"task">> := T}) -> T;
payload(#{<<"message">> := M}) -> M;
payload(#{<<"statusUpdate">> := S}) -> S;
payload(#{<<"artifactUpdate">> := A}) -> A;
payload(_) -> undefined.

-spec task_id(event()) -> binary() | undefined.
task_id(#{<<"task">> := T}) -> barrel_a2a_task:id(T);
task_id(#{<<"message">> := M}) -> barrel_a2a_message:task_id(M);
task_id(#{<<"statusUpdate">> := #{<<"taskId">> := Id}}) -> Id;
task_id(#{<<"artifactUpdate">> := #{<<"taskId">> := Id}}) -> Id;
task_id(_) -> undefined.

-spec context_id(event()) -> binary() | undefined.
context_id(#{<<"task">> := T}) -> barrel_a2a_task:context_id(T);
context_id(#{<<"message">> := M}) -> barrel_a2a_message:context_id(M);
context_id(#{<<"statusUpdate">> := #{<<"contextId">> := Id}}) -> Id;
context_id(#{<<"artifactUpdate">> := #{<<"contextId">> := Id}}) -> Id;
context_id(_) -> undefined.

%% @doc True when the event carries a terminal task state, meaning
%% the stream it belongs to closes after it.
-spec is_final(event()) -> boolean().
is_final(#{<<"message">> := _}) ->
    true;
is_final(#{<<"task">> := T}) ->
    barrel_a2a_task:is_terminal(T);
is_final(#{<<"statusUpdate">> := #{<<"status">> := #{<<"state">> := S}}}) ->
    case barrel_a2a_task_state:from_wire(S) of
        {ok, State} -> barrel_a2a_task_state:is_terminal(State);
        error -> false
    end;
is_final(_) ->
    false.
