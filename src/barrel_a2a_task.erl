%%%-------------------------------------------------------------------
%%% @doc `Task' objects (specification 4.1.1 to 4.1.3).
%%%
%%% Accessors over the wire map, plus the constructors the server uses
%%% to build and update a task. States are exposed as the short atoms
%%% of `barrel_a2a_task_state'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task).

-export([new/2, new/3]).

-export_type([task/0]).
-export([
    id/1,
    context_id/1,
    state/1,
    status/1,
    status_message/1,
    status_timestamp/1,
    artifacts/1,
    history/1,
    metadata/1
]).
-export([is_terminal/1, is_interrupted/1]).
-export([
    set_status/3,
    set_status/4,
    add_history/2,
    put_artifact/3,
    with_history_length/2,
    without_artifacts/1,
    status_object/3
]).

-type task() :: barrel_a2a:task().

%% @doc A new task in `submitted' state.
-spec new(binary(), binary()) -> task().
new(TaskId, ContextId) -> new(TaskId, ContextId, #{}).

-spec new(binary(), binary(), #{metadata => map(), history => [barrel_a2a:message()]}) -> task().
new(TaskId, ContextId, Opts) ->
    Base = #{
        <<"id">> => TaskId,
        <<"contextId">> => ContextId,
        <<"status">> => status_object(submitted, undefined, barrel_a2a_time:now_iso()),
        <<"artifacts">> => [],
        <<"history">> => maps:get(history, Opts, [])
    },
    case maps:get(metadata, Opts, undefined) of
        undefined -> Base;
        Meta -> Base#{<<"metadata">> => Meta}
    end.

-spec id(task()) -> binary() | undefined.
id(#{<<"id">> := Id}) when is_binary(Id) -> Id;
id(_) -> undefined.

-spec context_id(task()) -> binary() | undefined.
context_id(#{<<"contextId">> := C}) when is_binary(C), C =/= <<>> -> C;
context_id(_) -> undefined.

-spec status(task()) -> barrel_a2a:task_status().
status(#{<<"status">> := S}) when is_map(S) -> S;
status(_) -> #{}.

-spec state(task()) -> barrel_a2a:state().
state(Task) ->
    case barrel_a2a_task_state:from_wire(maps:get(<<"state">>, status(Task), undefined)) of
        {ok, State} -> State;
        error -> unspecified
    end.

-spec status_message(task()) -> barrel_a2a:message() | undefined.
status_message(Task) ->
    case maps:get(<<"message">>, status(Task), undefined) of
        M when is_map(M) -> M;
        _ -> undefined
    end.

-spec status_timestamp(task()) -> binary() | undefined.
status_timestamp(Task) ->
    case maps:get(<<"timestamp">>, status(Task), undefined) of
        T when is_binary(T) -> T;
        _ -> undefined
    end.

-spec artifacts(task()) -> [barrel_a2a:artifact()].
artifacts(#{<<"artifacts">> := A}) when is_list(A) -> A;
artifacts(_) -> [].

-spec history(task()) -> [barrel_a2a:message()].
history(#{<<"history">> := H}) when is_list(H) -> H;
history(_) -> [].

-spec metadata(task()) -> map().
metadata(#{<<"metadata">> := M}) when is_map(M) -> M;
metadata(_) -> #{}.

-spec is_terminal(task()) -> boolean().
is_terminal(Task) -> barrel_a2a_task_state:is_terminal(state(Task)).

-spec is_interrupted(task()) -> boolean().
is_interrupted(Task) -> barrel_a2a_task_state:is_interrupted(state(Task)).

%% @doc A `TaskStatus' object.
-spec status_object(barrel_a2a:state(), barrel_a2a:message() | undefined, binary()) ->
    barrel_a2a:task_status().
status_object(State, undefined, Timestamp) ->
    #{<<"state">> => barrel_a2a_task_state:to_wire(State), <<"timestamp">> => Timestamp};
status_object(State, Message, Timestamp) ->
    #{
        <<"state">> => barrel_a2a_task_state:to_wire(State),
        <<"message">> => Message,
        <<"timestamp">> => Timestamp
    }.

-spec set_status(task(), barrel_a2a:state(), barrel_a2a:message() | undefined) -> task().
set_status(Task, State, Message) ->
    set_status(Task, State, Message, barrel_a2a_time:now_iso()).

-spec set_status(task(), barrel_a2a:state(), barrel_a2a:message() | undefined, binary()) ->
    task().
set_status(Task, State, Message, Timestamp) ->
    Task#{<<"status">> => status_object(State, Message, Timestamp)}.

-spec add_history(task(), barrel_a2a:message()) -> task().
add_history(Task, Message) ->
    Task#{<<"history">> => history(Task) ++ [Message]}.

%% @doc Store an artifact. With `Append = true' and an existing
%% artifact of the same id, parts are concatenated.
-spec put_artifact(task(), barrel_a2a:artifact(), boolean()) -> task().
put_artifact(Task, Artifact, Append) ->
    Id = barrel_a2a_artifact:id(Artifact),
    Existing = artifacts(Task),
    case lists:partition(fun(A) -> barrel_a2a_artifact:id(A) =:= Id end, Existing) of
        {[Old | _], _} when Append ->
            Merged = barrel_a2a_artifact:append_parts(Old, Artifact),
            Task#{<<"artifacts">> => replace(Existing, Id, Merged)};
        {[_ | _], _} ->
            Task#{<<"artifacts">> => replace(Existing, Id, Artifact)};
        {[], _} ->
            Task#{<<"artifacts">> => Existing ++ [Artifact]}
    end.

replace(List, Id, New) ->
    [
        case barrel_a2a_artifact:id(A) =:= Id of
            true -> New;
            false -> A
        end
     || A <- List
    ].

%% @doc Apply `historyLength' semantics (specification 3.2.4):
%% `undefined' keeps everything, `0' omits the field, `N' keeps the
%% last N messages.
-spec with_history_length(task(), non_neg_integer() | undefined) -> task().
with_history_length(Task, undefined) ->
    Task;
with_history_length(Task, 0) ->
    maps:remove(<<"history">>, Task);
with_history_length(Task, N) when is_integer(N), N > 0 ->
    H = history(Task),
    Task#{<<"history">> => lists:nthtail(max(0, length(H) - N), H)}.

%% @doc Drop the artifacts field entirely (ListTasks with
%% `includeArtifacts = false').
-spec without_artifacts(task()) -> task().
without_artifacts(Task) -> maps:remove(<<"artifacts">>, Task).
