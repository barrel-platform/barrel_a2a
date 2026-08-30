%%%-------------------------------------------------------------------
%%% @doc The task state machine (specification 4.1.3, 3.1.x).
%%%
%%% Every transition a server performs goes through {@link transition/2}
%%% so the rules live in one place:
%%%
%%% ```
%%% submitted      -> working | input_required | auth_required
%%%                 | completed | failed | canceled | rejected
%%% working        -> working | input_required | auth_required
%%%                 | completed | failed | canceled
%%% input_required -> working | canceled | failed
%%% auth_required  -> working | canceled | failed
%%% terminal       -> nothing
%%% '''
%%%
%%% `working -> working' is allowed so a status message can be
%%% published without changing state.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_task_state).

-export([transition/2, is_terminal/1, is_interrupted/1, cancelable/1, accepts_messages/1]).
-export([to_wire/1, from_wire/1, states/0]).

-type state() :: barrel_a2a:state().

-export_type([state/0]).

-spec states() -> [state()].
states() ->
    [submitted, working, completed, failed, canceled, input_required, rejected, auth_required].

-spec transition(state(), state()) -> ok | {error, {invalid_transition, state(), state()}}.
transition(From, To) ->
    case allowed(From, To) of
        true -> ok;
        false -> {error, {invalid_transition, From, To}}
    end.

allowed(submitted, To) ->
    lists:member(To, [
        working, input_required, auth_required, completed, failed, canceled, rejected
    ]);
allowed(working, To) ->
    lists:member(To, [working, input_required, auth_required, completed, failed, canceled]);
allowed(input_required, To) ->
    lists:member(To, [working, canceled, failed]);
allowed(auth_required, To) ->
    lists:member(To, [working, canceled, failed]);
allowed(_, _) ->
    false.

-spec is_terminal(state()) -> boolean().
is_terminal(completed) -> true;
is_terminal(failed) -> true;
is_terminal(canceled) -> true;
is_terminal(rejected) -> true;
is_terminal(_) -> false.

-spec is_interrupted(state()) -> boolean().
is_interrupted(input_required) -> true;
is_interrupted(auth_required) -> true;
is_interrupted(_) -> false.

%% @doc A task can be canceled while it is not terminal.
-spec cancelable(state()) -> boolean().
cancelable(State) -> not is_terminal(State).

%% @doc Follow-up messages are accepted while the task is not terminal
%% (specification 3.3.3, 7.6.1).
-spec accepts_messages(state()) -> boolean().
accepts_messages(State) -> not is_terminal(State).

-spec to_wire(state()) -> binary().
to_wire(submitted) -> <<"TASK_STATE_SUBMITTED">>;
to_wire(working) -> <<"TASK_STATE_WORKING">>;
to_wire(completed) -> <<"TASK_STATE_COMPLETED">>;
to_wire(failed) -> <<"TASK_STATE_FAILED">>;
to_wire(canceled) -> <<"TASK_STATE_CANCELED">>;
to_wire(input_required) -> <<"TASK_STATE_INPUT_REQUIRED">>;
to_wire(rejected) -> <<"TASK_STATE_REJECTED">>;
to_wire(auth_required) -> <<"TASK_STATE_AUTH_REQUIRED">>;
to_wire(unspecified) -> <<"TASK_STATE_UNSPECIFIED">>.

%% @doc Accepts the wire string, the short atom, or the proto integer
%% (ProtoJSON allows enum numbers).
-spec from_wire(term()) -> {ok, state()} | error.
from_wire(<<"TASK_STATE_SUBMITTED">>) ->
    {ok, submitted};
from_wire(<<"TASK_STATE_WORKING">>) ->
    {ok, working};
from_wire(<<"TASK_STATE_COMPLETED">>) ->
    {ok, completed};
from_wire(<<"TASK_STATE_FAILED">>) ->
    {ok, failed};
from_wire(<<"TASK_STATE_CANCELED">>) ->
    {ok, canceled};
from_wire(<<"TASK_STATE_INPUT_REQUIRED">>) ->
    {ok, input_required};
from_wire(<<"TASK_STATE_REJECTED">>) ->
    {ok, rejected};
from_wire(<<"TASK_STATE_AUTH_REQUIRED">>) ->
    {ok, auth_required};
from_wire(<<"TASK_STATE_UNSPECIFIED">>) ->
    {ok, unspecified};
from_wire(0) ->
    {ok, unspecified};
from_wire(1) ->
    {ok, submitted};
from_wire(2) ->
    {ok, working};
from_wire(3) ->
    {ok, completed};
from_wire(4) ->
    {ok, failed};
from_wire(5) ->
    {ok, canceled};
from_wire(6) ->
    {ok, input_required};
from_wire(7) ->
    {ok, rejected};
from_wire(8) ->
    {ok, auth_required};
from_wire(A) when is_atom(A) ->
    case lists:member(A, [unspecified | states()]) of
        true -> {ok, A};
        false -> error
    end;
from_wire(_) ->
    error.
