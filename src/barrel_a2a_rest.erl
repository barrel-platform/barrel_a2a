%%%-------------------------------------------------------------------
%%% @doc HTTP+JSON binding routes and parameter mapping (spec 11).
%%%
%%% Paths follow the proto `google.api.http' annotations, optionally
%%% prefixed by `/{tenant}'. {@link match/3} turns a method and path
%%% into an operation plus the request object built from path
%%% segments, query parameters (camelCase, 11.5) and the body.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_rest).

-export([routes/1, match/3, build_request/4, path_for/3, query_for/2]).

-type route() :: {Method :: binary(), Pattern :: binary(), Op :: barrel_a2a:op()}.

-export_type([route/0]).

%% @doc Route table under a base path such as `<<"/a2a/v1">>'.
%% Patterns use `:name' for a segment binding.
-spec routes(binary()) -> [route()].
routes(Base) ->
    [
        {M, <<Base/binary, P/binary>>, Op}
     || {M, P, Op} <- [
            {<<"POST">>, <<"/message:send">>, send_message},
            {<<"POST">>, <<"/message:stream">>, send_streaming_message},
            {<<"GET">>, <<"/tasks/:id">>, get_task},
            {<<"GET">>, <<"/tasks">>, list_tasks},
            {<<"POST">>, <<"/tasks/:id:cancel">>, cancel_task},
            {<<"POST">>, <<"/tasks/:id:subscribe">>, subscribe_to_task},
            {<<"POST">>, <<"/tasks/:id/pushNotificationConfigs">>, create_push_config},
            {<<"GET">>, <<"/tasks/:id/pushNotificationConfigs/:configId">>, get_push_config},
            {<<"GET">>, <<"/tasks/:id/pushNotificationConfigs">>, list_push_configs},
            {<<"DELETE">>, <<"/tasks/:id/pushNotificationConfigs/:configId">>, delete_push_config},
            {<<"GET">>, <<"/extendedAgentCard">>, get_extended_agent_card}
        ]
    ].

%% @doc Match a request path against the routes. Returns the
%% operation and path bindings, `{error, not_found}' or
%% `{error, {method_not_allowed, [Method]}}'.
-spec match(binary(), binary(), [route()]) ->
    {ok, barrel_a2a:op(), #{binary() => binary()}}
    | {error, not_found}
    | {error, {method_not_allowed, [binary()]}}.
match(Method, Path, Routes) ->
    Segments = split(Path),
    Matches = [
        {M, Bindings, Op}
     || {M, Pattern, Op} <- Routes,
        {true, Bindings} <- [match_segments(split(Pattern), Segments, #{})]
    ],
    case [{B, Op} || {M, B, Op} <- Matches, M =:= Method] of
        [{Bindings, Op} | _] ->
            {ok, Op, Bindings};
        [] ->
            case Matches of
                [] -> {error, not_found};
                _ -> {error, {method_not_allowed, lists:usort([M || {M, _, _} <- Matches])}}
            end
    end.

split(Path) ->
    [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>].

match_segments([], [], Acc) ->
    {true, Acc};
match_segments([<<$:, Rest/binary>> | Ps], [S | Ss], Acc) ->
    %% A binding segment may carry a literal `:verb' suffix, as in
    %% `:id:cancel'. Split the pattern on the verb colon.
    case binary:split(Rest, <<":">>) of
        [Name] ->
            match_segments(Ps, Ss, Acc#{Name => uri_decode(S)});
        [Name, Verb] ->
            Suffix = <<":", Verb/binary>>,
            SLen = byte_size(S),
            VLen = byte_size(Suffix),
            case SLen > VLen andalso binary:part(S, SLen - VLen, VLen) =:= Suffix of
                true ->
                    Value = binary:part(S, 0, SLen - VLen),
                    match_segments(Ps, Ss, Acc#{Name => uri_decode(Value)});
                false ->
                    false
            end
    end;
match_segments([P | Ps], [P | Ss], Acc) ->
    match_segments(Ps, Ss, Acc);
match_segments(_, _, _) ->
    false.

uri_decode(S) ->
    try uri_string:percent_decode(S) of
        {error, _, _} -> S;
        D when is_binary(D) -> D;
        _ -> S
    catch
        _:_ -> S
    end.

%% @doc Build the operation request object from path bindings, query
%% parameters and the decoded body.
-spec build_request(
    barrel_a2a:op(),
    #{binary() => binary()},
    [{binary(), binary()}],
    barrel_a2a:json() | undefined
) -> barrel_a2a:object().
build_request(Op, Bindings, Query, Body) ->
    %% `tenant' may travel as a query parameter on GET and DELETE
    %% (11.5); the body carries it otherwise.
    with_query(build_request_op(Op, Bindings, Query, Body), Query, [{<<"tenant">>, string}]).

build_request_op(Op, _Bindings, _Query, Body) when
    Op =:= send_message; Op =:= send_streaming_message
->
    body_object(Body);
build_request_op(get_task, #{<<"id">> := Id}, Query, _) ->
    with_query(#{<<"id">> => Id}, Query, [{<<"historyLength">>, int}]);
build_request_op(list_tasks, _, Query, _) ->
    with_query(#{}, Query, [
        {<<"contextId">>, string},
        {<<"status">>, string},
        {<<"pageSize">>, int},
        {<<"pageToken">>, string},
        {<<"historyLength">>, int},
        {<<"statusTimestampAfter">>, string},
        {<<"includeArtifacts">>, bool}
    ]);
build_request_op(cancel_task, #{<<"id">> := Id}, _, Body) ->
    (body_object(Body))#{<<"id">> => Id};
build_request_op(subscribe_to_task, #{<<"id">> := Id}, _, _) ->
    #{<<"id">> => Id};
build_request_op(create_push_config, #{<<"id">> := TaskId}, _, Body) ->
    (body_object(Body))#{<<"taskId">> => TaskId};
build_request_op(get_push_config, #{<<"id">> := TaskId, <<"configId">> := ConfigId}, _, _) ->
    #{<<"taskId">> => TaskId, <<"id">> => ConfigId};
build_request_op(delete_push_config, #{<<"id">> := TaskId, <<"configId">> := ConfigId}, _, _) ->
    #{<<"taskId">> => TaskId, <<"id">> => ConfigId};
build_request_op(list_push_configs, #{<<"id">> := TaskId}, Query, _) ->
    with_query(#{<<"taskId">> => TaskId}, Query, [
        {<<"pageSize">>, int}, {<<"pageToken">>, string}
    ]);
build_request_op(get_extended_agent_card, _, _, _) ->
    #{}.

body_object(Body) when is_map(Body) -> Body;
body_object(_) -> #{}.

with_query(Req, Query, Spec) ->
    lists:foldl(
        fun({Key, Type}, Acc) ->
            case lists:keyfind(Key, 1, Query) of
                {_, Raw} -> put_typed(Acc, Key, Type, Raw);
                false -> Acc
            end
        end,
        Req,
        Spec
    ).

put_typed(Acc, Key, string, Raw) ->
    Acc#{Key => Raw};
put_typed(Acc, Key, int, Raw) ->
    try
        Acc#{Key => binary_to_integer(Raw)}
    catch
        _:_ -> Acc#{Key => Raw}
    end;
put_typed(Acc, Key, bool, <<"true">>) ->
    Acc#{Key => true};
put_typed(Acc, Key, bool, <<"false">>) ->
    Acc#{Key => false};
put_typed(Acc, Key, bool, Raw) ->
    Acc#{Key => Raw}.

%% @doc The request path for an operation (client side), given the
%% base path and the request object.
-spec path_for(barrel_a2a:op(), binary(), barrel_a2a:object()) -> {binary(), binary()}.
path_for(send_message, Base, _) ->
    {<<"POST">>, <<Base/binary, "/message:send">>};
path_for(send_streaming_message, Base, _) ->
    {<<"POST">>, <<Base/binary, "/message:stream">>};
path_for(get_task, Base, #{<<"id">> := Id}) ->
    {<<"GET">>, <<Base/binary, "/tasks/", (enc(Id))/binary>>};
path_for(list_tasks, Base, _) ->
    {<<"GET">>, <<Base/binary, "/tasks">>};
path_for(cancel_task, Base, #{<<"id">> := Id}) ->
    {<<"POST">>, <<Base/binary, "/tasks/", (enc(Id))/binary, ":cancel">>};
path_for(subscribe_to_task, Base, #{<<"id">> := Id}) ->
    {<<"POST">>, <<Base/binary, "/tasks/", (enc(Id))/binary, ":subscribe">>};
path_for(create_push_config, Base, #{<<"taskId">> := Id}) ->
    {<<"POST">>, <<Base/binary, "/tasks/", (enc(Id))/binary, "/pushNotificationConfigs">>};
path_for(get_push_config, Base, #{<<"taskId">> := T, <<"id">> := C}) ->
    {<<"GET">>,
        <<Base/binary, "/tasks/", (enc(T))/binary, "/pushNotificationConfigs/", (enc(C))/binary>>};
path_for(delete_push_config, Base, #{<<"taskId">> := T, <<"id">> := C}) ->
    {<<"DELETE">>,
        <<Base/binary, "/tasks/", (enc(T))/binary, "/pushNotificationConfigs/", (enc(C))/binary>>};
path_for(list_push_configs, Base, #{<<"taskId">> := Id}) ->
    {<<"GET">>, <<Base/binary, "/tasks/", (enc(Id))/binary, "/pushNotificationConfigs">>};
path_for(get_extended_agent_card, Base, _) ->
    {<<"GET">>, <<Base/binary, "/extendedAgentCard">>}.

enc(Bin) -> uri_string:quote(Bin).

%% @doc Query string for GET operations (client side), from the
%% request object minus path fields.
-spec query_for(barrel_a2a:op(), barrel_a2a:object()) -> binary().
query_for(Op, Req) ->
    Skip =
        case Op of
            get_task -> [<<"id">>];
            list_push_configs -> [<<"taskId">>];
            _ -> []
        end,
    Pairs = [
        {K, to_query_value(V)}
     || {K, V} <- lists:sort(maps:to_list(maps:without(Skip, Req))),
        V =/= undefined,
        not is_map(V),
        not is_list(V)
    ],
    case Pairs of
        [] -> <<>>;
        _ -> iolist_to_binary(uri_string:compose_query(Pairs))
    end.

to_query_value(true) -> <<"true">>;
to_query_value(false) -> <<"false">>;
to_query_value(I) when is_integer(I) -> integer_to_binary(I);
to_query_value(B) when is_binary(B) -> B;
to_query_value(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
