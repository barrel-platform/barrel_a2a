%%%-------------------------------------------------------------------
%%% @doc JSON-RPC 2.0 envelopes for the JSON-RPC binding (spec 9).
%%%
%%% Shared by client and server: request construction, response and
%%% error construction, envelope classification, and the method table
%%% mapping A2A operations to their PascalCase method names.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_jsonrpc).

-export([request/3, response/2, error_response/2, classify/1]).
-export([method_name/1, op_for_method/1, methods/0, is_streaming/1]).

-type id() :: binary() | integer() | null.

-export_type([id/0]).

-spec request(id(), binary(), barrel_a2a:object() | undefined) -> barrel_a2a:object().
request(Id, Method, undefined) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => Method};
request(Id, Method, Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => Method, <<"params">> => Params}.

-spec response(id(), barrel_a2a:json()) -> barrel_a2a:object().
response(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result}.

-spec error_response(id(), barrel_a2a_error:error()) -> barrel_a2a:object().
error_response(Id, Error) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => barrel_a2a_error:to_jsonrpc(Error)
    }.

%% @doc Classify a decoded envelope. Batches are not part of the A2A
%% binding and are reported as invalid.
-spec classify(term()) ->
    {request, id(), binary(), barrel_a2a:object()}
    | {response, id(), barrel_a2a:json()}
    | {error, id(), barrel_a2a_error:error()}
    | {invalid, id(), binary()}.
classify(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method} = Msg) when is_binary(Method) ->
    Id = id_of(Msg),
    case maps:get(<<"params">>, Msg, #{}) of
        Params when is_map(Params) ->
            case Id of
                undefined -> {invalid, null, <<"notifications are not supported">>};
                _ -> {request, Id, Method, Params}
            end;
        _ ->
            {invalid, id_or_null(Id), <<"params must be an object">>}
    end;
classify(#{<<"jsonrpc">> := <<"2.0">>, <<"error">> := Err} = Msg) when is_map(Err) ->
    {error, id_or_null(id_of(Msg)), barrel_a2a_error:from_jsonrpc(Err)};
classify(#{<<"jsonrpc">> := <<"2.0">>, <<"result">> := Result} = Msg) ->
    {response, id_or_null(id_of(Msg)), Result};
classify(Msg) when is_list(Msg) ->
    {invalid, null, <<"batch requests are not supported">>};
classify(Msg) when is_map(Msg) ->
    {invalid, id_or_null(id_of(Msg)), <<"not a JSON-RPC 2.0 message">>};
classify(_) ->
    {invalid, null, <<"not a JSON-RPC 2.0 message">>}.

id_of(Msg) ->
    case maps:get(<<"id">>, Msg, undefined) of
        Id when is_binary(Id); is_integer(Id); Id =:= null -> Id;
        _ -> undefined
    end.

id_or_null(undefined) -> null;
id_or_null(Id) -> Id.

-spec method_name(barrel_a2a:op()) -> binary().
method_name(send_message) -> <<"SendMessage">>;
method_name(send_streaming_message) -> <<"SendStreamingMessage">>;
method_name(get_task) -> <<"GetTask">>;
method_name(list_tasks) -> <<"ListTasks">>;
method_name(cancel_task) -> <<"CancelTask">>;
method_name(subscribe_to_task) -> <<"SubscribeToTask">>;
method_name(create_push_config) -> <<"CreateTaskPushNotificationConfig">>;
method_name(get_push_config) -> <<"GetTaskPushNotificationConfig">>;
method_name(list_push_configs) -> <<"ListTaskPushNotificationConfigs">>;
method_name(delete_push_config) -> <<"DeleteTaskPushNotificationConfig">>;
method_name(get_extended_agent_card) -> <<"GetExtendedAgentCard">>.

-spec op_for_method(binary()) -> {ok, barrel_a2a:op()} | error.
op_for_method(Method) ->
    case [Op || Op <- methods(), method_name(Op) =:= Method] of
        [Op] -> {ok, Op};
        [] -> error
    end.

-spec methods() -> [barrel_a2a:op()].
methods() ->
    [
        send_message,
        send_streaming_message,
        get_task,
        list_tasks,
        cancel_task,
        subscribe_to_task,
        create_push_config,
        get_push_config,
        list_push_configs,
        delete_push_config,
        get_extended_agent_card
    ].

-spec is_streaming(barrel_a2a:op()) -> boolean().
is_streaming(send_streaming_message) -> true;
is_streaming(subscribe_to_task) -> true;
is_streaming(_) -> false.
