%%%-------------------------------------------------------------------
%%% @doc Structural validation of protocol objects and requests.
%%%
%%% The JSON Schema bundle (`barrel_a2a_schema') checks types and
%%% unknown properties but, being generated from proto3, knows nothing
%%% about `REQUIRED' fields, oneof exclusivity or enum membership.
%%% This module checks those (specification 5.7, 4.1): required
%%% fields present, arrays marked required non-empty, exactly one
%%% part content, enum strings known, timestamps parseable.
%%%
%%% Errors are `{invalid, Path, Reason}' where `Path' is the dotted
%%% JSON path (`<<"message.parts">>') suitable for a
%%% `google.rpc.BadRequest' field violation.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_validate).

-export([
    message/1,
    part/1,
    artifact/1,
    task/1,
    task_status/1,
    agent_card/1,
    send_message_request/1,
    get_task_request/1,
    list_tasks_request/1,
    cancel_task_request/1,
    subscribe_request/1,
    push_config/1,
    push_config_ref/1,
    list_push_configs_request/1
]).
-export([to_error/1]).

-type reason() :: {invalid, binary(), binary()}.

-export_type([reason/0]).

%% @doc Convert a validation failure into a protocol error.
-spec to_error(reason()) -> barrel_a2a_error:error().
to_error({invalid, Path, Why}) ->
    barrel_a2a_error:invalid(Path, Why).

%%--------------------------------------------------------------------
%% Objects
%%--------------------------------------------------------------------

-spec message(term()) -> ok | {error, reason()}.
message(M) -> message(M, <<"message">>).

message(M, Path) when is_map(M) ->
    check([
        fun() -> required_string(M, <<"messageId">>, Path) end,
        fun() -> enum(M, <<"role">>, Path, fun barrel_a2a_message:role_from_wire/1) end,
        fun() -> required_list(M, <<"parts">>, Path) end,
        fun() -> each(maps:get(<<"parts">>, M, []), fun part/2, join(Path, <<"parts">>)) end,
        fun() -> optional_string(M, <<"contextId">>, Path) end,
        fun() -> optional_string(M, <<"taskId">>, Path) end,
        fun() -> optional_object(M, <<"metadata">>, Path) end,
        fun() -> optional_string_list(M, <<"extensions">>, Path) end,
        fun() -> optional_string_list(M, <<"referenceTaskIds">>, Path) end
    ]);
message(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

-spec part(term()) -> ok | {error, reason()}.
part(P) -> part(P, <<"part">>).

part(P, Path) when is_map(P) ->
    Contents = [K || K <- [<<"text">>, <<"raw">>, <<"url">>, <<"data">>], maps:is_key(K, P)],
    case Contents of
        [<<"text">>] -> string_field(P, <<"text">>, Path);
        [<<"raw">>] -> base64_field(P, <<"raw">>, Path);
        [<<"url">>] -> string_field(P, <<"url">>, Path);
        [<<"data">>] -> ok;
        [] -> {error, {invalid, Path, <<"one of text, raw, url or data is required">>}};
        _ -> {error, {invalid, Path, <<"only one of text, raw, url or data may be set">>}}
    end;
part(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

-spec artifact(term()) -> ok | {error, reason()}.
artifact(A) -> artifact(A, <<"artifact">>).

artifact(A, Path) when is_map(A) ->
    check([
        fun() -> required_string(A, <<"artifactId">>, Path) end,
        fun() -> required_list(A, <<"parts">>, Path) end,
        fun() -> each(maps:get(<<"parts">>, A, []), fun part/2, join(Path, <<"parts">>)) end,
        fun() -> optional_string(A, <<"name">>, Path) end,
        fun() -> optional_string(A, <<"description">>, Path) end,
        fun() -> optional_object(A, <<"metadata">>, Path) end,
        fun() -> optional_string_list(A, <<"extensions">>, Path) end
    ]);
artifact(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

-spec task_status(term()) -> ok | {error, reason()}.
task_status(S) -> task_status(S, <<"status">>).

task_status(S, Path) when is_map(S) ->
    check([
        fun() -> enum(S, <<"state">>, Path, fun barrel_a2a_task_state:from_wire/1) end,
        fun() ->
            case maps:get(<<"message">>, S, undefined) of
                undefined -> ok;
                M -> message(M, join(Path, <<"message">>))
            end
        end,
        fun() -> optional_timestamp(S, <<"timestamp">>, Path) end
    ]);
task_status(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

-spec task(term()) -> ok | {error, reason()}.
task(T) when is_map(T) ->
    Path = <<"task">>,
    check([
        fun() -> required_string(T, <<"id">>, Path) end,
        fun() -> required_field(T, <<"status">>, Path) end,
        fun() -> task_status(maps:get(<<"status">>, T, undefined), join(Path, <<"status">>)) end,
        fun() ->
            each(maps:get(<<"artifacts">>, T, []), fun artifact/2, join(Path, <<"artifacts">>))
        end,
        fun() -> each(maps:get(<<"history">>, T, []), fun message/2, join(Path, <<"history">>)) end,
        fun() -> optional_object(T, <<"metadata">>, Path) end
    ]);
task(_) ->
    {error, {invalid, <<"task">>, <<"must be an object">>}}.

-spec agent_card(term()) -> ok | {error, reason()}.
agent_card(C) when is_map(C) ->
    Path = <<"agentCard">>,
    check([
        fun() -> required_string(C, <<"name">>, Path) end,
        fun() -> required_field(C, <<"description">>, Path) end,
        fun() -> string_field(C, <<"description">>, Path) end,
        fun() -> required_string(C, <<"version">>, Path) end,
        fun() -> required_list(C, <<"supportedInterfaces">>, Path) end,
        fun() ->
            each(
                maps:get(<<"supportedInterfaces">>, C, []),
                fun interface/2,
                join(Path, <<"supportedInterfaces">>)
            )
        end,
        fun() -> required_field(C, <<"capabilities">>, Path) end,
        fun() -> optional_object(C, <<"capabilities">>, Path) end,
        fun() -> required_list(C, <<"defaultInputModes">>, Path) end,
        fun() -> required_list(C, <<"defaultOutputModes">>, Path) end,
        fun() -> required_field(C, <<"skills">>, Path) end,
        fun() -> list_field(C, <<"skills">>, Path) end,
        fun() -> each(maps:get(<<"skills">>, C, []), fun skill/2, join(Path, <<"skills">>)) end,
        fun() ->
            case maps:get(<<"provider">>, C, undefined) of
                undefined -> ok;
                P -> provider(P, join(Path, <<"provider">>))
            end
        end
    ]);
agent_card(_) ->
    {error, {invalid, <<"agentCard">>, <<"must be an object">>}}.

interface(I, Path) when is_map(I) ->
    check([
        fun() -> required_string(I, <<"url">>, Path) end,
        fun() -> required_string(I, <<"protocolBinding">>, Path) end,
        fun() -> required_string(I, <<"protocolVersion">>, Path) end,
        fun() -> optional_string(I, <<"tenant">>, Path) end
    ]);
interface(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

skill(S, Path) when is_map(S) ->
    check([
        fun() -> required_string(S, <<"id">>, Path) end,
        fun() -> required_string(S, <<"name">>, Path) end,
        fun() -> required_field(S, <<"description">>, Path) end,
        fun() -> required_field(S, <<"tags">>, Path) end,
        fun() -> list_field(S, <<"tags">>, Path) end
    ]);
skill(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

provider(P, Path) when is_map(P) ->
    check([
        fun() -> required_string(P, <<"url">>, Path) end,
        fun() -> required_string(P, <<"organization">>, Path) end
    ]);
provider(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

%%--------------------------------------------------------------------
%% Requests
%%--------------------------------------------------------------------

-spec send_message_request(term()) -> ok | {error, reason()}.
send_message_request(R) when is_map(R) ->
    check([
        fun() -> required_field(R, <<"message">>, <<>>) end,
        fun() -> message(maps:get(<<"message">>, R, undefined), <<"message">>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end,
        fun() -> optional_object(R, <<"metadata">>, <<>>) end,
        fun() ->
            case maps:get(<<"configuration">>, R, undefined) of
                undefined -> ok;
                Conf -> configuration(Conf, <<"configuration">>)
            end
        end
    ]);
send_message_request(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

configuration(C, Path) when is_map(C) ->
    check([
        fun() -> optional_string_list(C, <<"acceptedOutputModes">>, Path) end,
        fun() -> optional_non_neg_int(C, <<"historyLength">>, Path) end,
        fun() -> optional_bool(C, <<"returnImmediately">>, Path) end,
        fun() ->
            case maps:get(<<"taskPushNotificationConfig">>, C, undefined) of
                undefined -> ok;
                P -> push_config(P, join(Path, <<"taskPushNotificationConfig">>))
            end
        end
    ]);
configuration(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

-spec get_task_request(term()) -> ok | {error, reason()}.
get_task_request(R) when is_map(R) ->
    check([
        fun() -> required_string(R, <<"id">>, <<>>) end,
        fun() -> optional_non_neg_int(R, <<"historyLength">>, <<>>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end
    ]);
get_task_request(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

-spec list_tasks_request(term()) -> ok | {error, reason()}.
list_tasks_request(R) when is_map(R) ->
    check([
        fun() -> optional_string(R, <<"contextId">>, <<>>) end,
        fun() ->
            case maps:get(<<"status">>, R, undefined) of
                undefined -> ok;
                _ -> enum(R, <<"status">>, <<>>, fun barrel_a2a_task_state:from_wire/1)
            end
        end,
        fun() -> optional_int_range(R, <<"pageSize">>, <<>>, 1, 100) end,
        fun() -> optional_string(R, <<"pageToken">>, <<>>) end,
        fun() -> optional_non_neg_int(R, <<"historyLength">>, <<>>) end,
        fun() -> optional_timestamp(R, <<"statusTimestampAfter">>, <<>>) end,
        fun() -> optional_bool(R, <<"includeArtifacts">>, <<>>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end
    ]);
list_tasks_request(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

-spec cancel_task_request(term()) -> ok | {error, reason()}.
cancel_task_request(R) when is_map(R) ->
    check([
        fun() -> required_string(R, <<"id">>, <<>>) end,
        fun() -> optional_object(R, <<"metadata">>, <<>>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end
    ]);
cancel_task_request(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

-spec subscribe_request(term()) -> ok | {error, reason()}.
subscribe_request(R) when is_map(R) ->
    check([
        fun() -> required_string(R, <<"id">>, <<>>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end
    ]);
subscribe_request(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

%% @doc A `TaskPushNotificationConfig' as sent by a client: `url' is
%% required, `id' is server-assigned and ignored when present.
-spec push_config(term()) -> ok | {error, reason()}.
push_config(P) -> push_config(P, <<>>).

push_config(P, Path) when is_map(P) ->
    check([
        fun() -> required_string(P, <<"url">>, Path) end,
        fun() -> optional_string(P, <<"id">>, Path) end,
        fun() -> optional_string(P, <<"taskId">>, Path) end,
        fun() -> optional_string(P, <<"token">>, Path) end,
        fun() -> optional_string(P, <<"tenant">>, Path) end,
        fun() ->
            case maps:get(<<"authentication">>, P, undefined) of
                undefined ->
                    ok;
                A when is_map(A) ->
                    check([
                        fun() ->
                            required_string(A, <<"scheme">>, join(Path, <<"authentication">>))
                        end,
                        fun() ->
                            optional_string(A, <<"credentials">>, join(Path, <<"authentication">>))
                        end
                    ]);
                _ ->
                    {error, {invalid, join(Path, <<"authentication">>), <<"must be an object">>}}
            end
        end
    ]);
push_config(_, Path) ->
    {error, {invalid, Path, <<"must be an object">>}}.

%% @doc Get/Delete push config requests: `taskId' and `id'.
-spec push_config_ref(term()) -> ok | {error, reason()}.
push_config_ref(R) when is_map(R) ->
    check([
        fun() -> required_string(R, <<"taskId">>, <<>>) end,
        fun() -> required_string(R, <<"id">>, <<>>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end
    ]);
push_config_ref(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

-spec list_push_configs_request(term()) -> ok | {error, reason()}.
list_push_configs_request(R) when is_map(R) ->
    check([
        fun() -> required_string(R, <<"taskId">>, <<>>) end,
        %% Not the 1..100 of ListTasks: the specification states no
        %% bounds for ListTaskPushNotificationConfigs (a2a.proto,
        %% page_size = 2). Do not merge the two.
        fun() -> optional_non_neg_int(R, <<"pageSize">>, <<>>) end,
        fun() -> optional_string(R, <<"pageToken">>, <<>>) end,
        fun() -> optional_string(R, <<"tenant">>, <<>>) end
    ]);
list_push_configs_request(_) ->
    {error, {invalid, <<>>, <<"request must be an object">>}}.

%%--------------------------------------------------------------------
%% Primitives
%%--------------------------------------------------------------------

check([]) ->
    ok;
check([F | Rest]) ->
    case F() of
        ok -> check(Rest);
        {error, _} = E -> E
    end.

each(List, Fun, Path) when is_list(List) ->
    each(List, Fun, Path, 0);
each(_, _, Path) ->
    {error, {invalid, Path, <<"must be an array">>}}.

each([], _, _, _) ->
    ok;
each([X | Rest], Fun, Path, N) ->
    case Fun(X, <<Path/binary, "[", (integer_to_binary(N))/binary, "]">>) of
        ok -> each(Rest, Fun, Path, N + 1);
        {error, _} = E -> E
    end.

join(<<>>, Key) -> Key;
join(Path, Key) -> <<Path/binary, ".", Key/binary>>.

required_field(M, Key, Path) ->
    case maps:is_key(Key, M) of
        true -> ok;
        false -> {error, {invalid, join(Path, Key), <<"is required">>}}
    end.

required_string(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        B when is_binary(B), B =/= <<>> -> ok;
        <<>> -> {error, {invalid, join(Path, Key), <<"must not be empty">>}};
        undefined -> {error, {invalid, join(Path, Key), <<"is required">>}};
        _ -> {error, {invalid, join(Path, Key), <<"must be a string">>}}
    end.

string_field(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined -> ok;
        B when is_binary(B) -> ok;
        _ -> {error, {invalid, join(Path, Key), <<"must be a string">>}}
    end.

optional_string(M, Key, Path) -> string_field(M, Key, Path).

base64_field(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        B when is_binary(B) ->
            try
                _ = base64:decode(B),
                ok
            catch
                _:_ -> {error, {invalid, join(Path, Key), <<"must be base64">>}}
            end;
        _ ->
            {error, {invalid, join(Path, Key), <<"must be a base64 string">>}}
    end.

required_list(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        [_ | _] -> ok;
        [] -> {error, {invalid, join(Path, Key), <<"must not be empty">>}};
        undefined -> {error, {invalid, join(Path, Key), <<"is required">>}};
        _ -> {error, {invalid, join(Path, Key), <<"must be an array">>}}
    end.

list_field(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined -> ok;
        L when is_list(L) -> ok;
        _ -> {error, {invalid, join(Path, Key), <<"must be an array">>}}
    end.

optional_string_list(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined ->
            ok;
        L when is_list(L) ->
            case lists:all(fun is_binary/1, L) of
                true -> ok;
                false -> {error, {invalid, join(Path, Key), <<"must be an array of strings">>}}
            end;
        _ ->
            {error, {invalid, join(Path, Key), <<"must be an array of strings">>}}
    end.

optional_object(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined -> ok;
        O when is_map(O) -> ok;
        _ -> {error, {invalid, join(Path, Key), <<"must be an object">>}}
    end.

optional_non_neg_int(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined -> ok;
        I when is_integer(I), I >= 0 -> ok;
        _ -> {error, {invalid, join(Path, Key), <<"must be a non-negative integer">>}}
    end.

%% The specification fixes this range: "The minimum value is 1. The
%% maximum value is 100." An absent value means unspecified and the
%% service picks its default; an explicit one outside the range is a
%% bad request, not something to quietly clamp.
optional_int_range(M, Key, Path, Min, Max) ->
    case maps:get(Key, M, undefined) of
        undefined ->
            ok;
        I when is_integer(I), I >= Min, I =< Max ->
            ok;
        _ ->
            {error,
                {invalid, join(Path, Key),
                    iolist_to_binary([
                        <<"must be an integer between ">>,
                        integer_to_binary(Min),
                        <<" and ">>,
                        integer_to_binary(Max)
                    ])}}
    end.

optional_bool(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined -> ok;
        B when is_boolean(B) -> ok;
        _ -> {error, {invalid, join(Path, Key), <<"must be a boolean">>}}
    end.

optional_timestamp(M, Key, Path) ->
    case maps:get(Key, M, undefined) of
        undefined ->
            ok;
        T when is_binary(T) ->
            case barrel_a2a_time:is_iso(T) of
                true -> ok;
                false -> {error, {invalid, join(Path, Key), <<"must be an ISO 8601 timestamp">>}}
            end;
        _ ->
            {error, {invalid, join(Path, Key), <<"must be an ISO 8601 timestamp">>}}
    end.

enum(M, Key, Path, FromWire) ->
    case maps:get(Key, M, undefined) of
        undefined ->
            {error, {invalid, join(Path, Key), <<"is required">>}};
        V ->
            case FromWire(V) of
                {ok, _} -> ok;
                error -> {error, {invalid, join(Path, Key), <<"is not a known value">>}}
            end
    end.
