%%%-------------------------------------------------------------------
%%% @doc Runtime access to the A2A wire schema.
%%%
%%% `priv/schema/a2a.json' is the JSON Schema 2020-12 bundle the A2A
%%% project generates from `a2a.proto': one `$defs' entry per protocol
%%% object, camelCase properties with `patternProperties' for the
%%% snake_case aliases, and `additionalProperties: false' throughout.
%%%
%%% Nothing is read at application start. The first call to any
%%% function here loads the bundle into `persistent_term'; each type
%%% is compiled on first use and cached under
%%% `{barrel_a2a_schema, Type, Mode}'.
%%%
%%% {@link validate/2} checks a decoded JSON value against
%%% `#/$defs/Type'. The bundle has no `required' lists, so a missing
%%% field passes; a wrongly typed or unknown field does not.
%%% {@link validate/3} takes the same check with `lenient', which
%%% tolerates a field the bundle does not declare.
%%%
%%% {@link request_type/1} and {@link reply_type/1} map an operation to
%%% the `$defs' name each side validates against. They live here, next
%%% to their only consumer, so the server core, the HTTP engine and the
%%% client cannot drift apart.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_schema).

-export([load/0, types/0, validate/2, validate/3, schema/0, version/0]).
-export([request_type/1, reply_type/1]).

-define(BUNDLE_KEY, {?MODULE, bundle}).

%% @doc Read and compile the bundle once. Idempotent.
-spec load() -> ok | {error, term()}.
load() ->
    case persistent_term:get(?BUNDLE_KEY, undefined) of
        undefined -> load_bundle();
        _ -> ok
    end.

%% @doc The `$defs' names, sorted.
-spec types() -> [binary()].
types() ->
    lists:sort(maps:keys(defs(bundle()))).

%% @doc The raw bundle, as decoded.
-spec schema() -> map().
schema() ->
    bundle().

%% @doc The bundle's `version' field.
-spec version() -> binary().
version() ->
    maps:get(<<"version">>, bundle()).

%% @doc Validate `Value' against `#/$defs/Type', rejecting fields the
%% bundle does not declare.
-spec validate(binary(), term()) -> ok | {error, [barrel_a2a_jsonschema:error()]}.
validate(Type, Value) ->
    validate(Type, Value, strict).

%% @doc Validate `Value' against `#/$defs/Type'.
%%
%% `strict' uses the bundle as written, so an undeclared field is an
%% error. `lenient' drops every `additionalProperties: false' first, so
%% a field this version does not know about passes: that is what A2A
%% asks of a server reading a request written against a later minor
%% version (5.7), and it is the mode the server uses by default.
%% Everything else is checked identically.
-spec validate(binary(), term(), strict | lenient) ->
    ok | {error, [barrel_a2a_jsonschema:error()]}.
validate(Type, Value, strict) when is_binary(Type) ->
    do_validate(Type, Value, strict);
validate(Type, Value, lenient) when is_binary(Type) ->
    do_validate(Type, Value, lenient).

do_validate(Type, Value, Mode) ->
    case compiled(Type, Mode) of
        {ok, Compiled} -> barrel_a2a_jsonschema:validate(Value, Compiled, #{});
        {error, Reason} -> {error, [{[], Reason}]}
    end.

%% @doc The `$defs' name a request for `Op' is validated against.
%%
%% Server side, before the operation runs. Every operation has an entry:
%% an unknown op is a bug in the dispatcher, so this deliberately has no
%% catch-all clause and crashes instead.
-spec request_type(barrel_a2a:op()) -> binary().
request_type(send_message) -> <<"SendMessageRequest">>;
request_type(send_streaming_message) -> <<"SendMessageRequest">>;
request_type(get_task) -> <<"GetTaskRequest">>;
request_type(list_tasks) -> <<"ListTasksRequest">>;
request_type(cancel_task) -> <<"CancelTaskRequest">>;
request_type(subscribe_to_task) -> <<"SubscribeToTaskRequest">>;
request_type(create_push_config) -> <<"TaskPushNotificationConfig">>;
request_type(get_push_config) -> <<"GetTaskPushNotificationConfigRequest">>;
request_type(delete_push_config) -> <<"DeleteTaskPushNotificationConfigRequest">>;
request_type(list_push_configs) -> <<"ListTaskPushNotificationConfigsRequest">>;
request_type(get_extended_agent_card) -> <<"GetExtendedAgentCardRequest">>.

%% @doc The `$defs' name a reply to `Op' is validated against.
%%
%% Used on both sides: by the server under `validate_schema => all' and
%% by the client under `validate_schema => true'. Operations whose reply
%% carries no body of its own fall back to `Struct', which accepts
%% anything; that is why this one has a catch-all clause and
%% {@link request_type/1} does not.
-spec reply_type(barrel_a2a:op()) -> binary().
reply_type(send_message) -> <<"SendMessageResponse">>;
reply_type(get_task) -> <<"Task">>;
reply_type(cancel_task) -> <<"Task">>;
reply_type(list_tasks) -> <<"ListTasksResponse">>;
reply_type(create_push_config) -> <<"TaskPushNotificationConfig">>;
reply_type(get_push_config) -> <<"TaskPushNotificationConfig">>;
reply_type(list_push_configs) -> <<"ListTaskPushNotificationConfigsResponse">>;
reply_type(get_extended_agent_card) -> <<"AgentCard">>;
reply_type(_) -> <<"Struct">>.

%%====================================================================
%% Internal
%%====================================================================

bundle() ->
    case persistent_term:get(?BUNDLE_KEY, undefined) of
        undefined ->
            case load_bundle() of
                ok -> persistent_term:get(?BUNDLE_KEY);
                {error, Reason} -> error({schema_bundle, Reason})
            end;
        Bundle ->
            Bundle
    end.

defs(Bundle) ->
    maps:get(<<"$defs">>, Bundle, #{}).

load_bundle() ->
    Path = filename:join([code:priv_dir(barrel_a2a), "schema", "a2a.json"]),
    case file:read_file(Path) of
        {ok, Bin} ->
            case barrel_a2a_json:decode(Bin) of
                {ok, Bundle} when is_map(Bundle) -> check_and_store(Bundle);
                {ok, _} -> {error, not_an_object};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {read, Path, Reason}}
    end.

%% The bundle root is compiled once to prove every `$ref' in it
%% resolves; per-type schemas are then derived from a known-good
%% document.
check_and_store(Bundle) ->
    case barrel_a2a_jsonschema:compile(Bundle) of
        {ok, _} ->
            persistent_term:put(?BUNDLE_KEY, Bundle),
            ok;
        {error, Reason} ->
            {error, {invalid_bundle, Reason}}
    end.

compiled(Type, Mode) ->
    Key = {?MODULE, Type, Mode},
    case persistent_term:get(Key, undefined) of
        undefined ->
            case compile_type(Type, Mode) of
                {ok, Compiled} ->
                    persistent_term:put(Key, Compiled),
                    {ok, Compiled};
                Error ->
                    Error
            end;
        Compiled ->
            {ok, Compiled}
    end.

%% A document whose root is one definition, with every other
%% definition still reachable by `$ref'.
compile_type(Type, Mode) ->
    Bundle = bundle(),
    Defs = defs(Bundle),
    case maps:is_key(Type, Defs) of
        false ->
            {error, {unknown_type, Type}};
        true ->
            Doc = #{
                <<"$schema">> => maps:get(<<"$schema">>, Bundle),
                <<"$defs">> => relax(Mode, Defs),
                <<"$ref">> => <<"#/$defs/", Type/binary>>
            },
            barrel_a2a_jsonschema:compile(Doc)
    end.

%% Drop `additionalProperties: false' wherever it appears. Only the
%% literal `false' goes: the bundle also uses `additionalProperties'
%% with a subschema, to type the values of an open map, and that is a
%% constraint worth keeping. The bundle declares no property actually
%% named `additionalProperties', so no property schema is harmed.
relax(strict, Node) ->
    Node;
relax(lenient, Node) when is_map(Node) ->
    maps:from_list([
        {K, relax(lenient, V)}
     || {K, V} <- maps:to_list(Node), not (K =:= <<"additionalProperties">> andalso V =:= false)
    ]);
relax(lenient, Node) when is_list(Node) ->
    [relax(lenient, N) || N <- Node];
relax(lenient, Node) ->
    Node.
