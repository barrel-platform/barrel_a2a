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
%%% `{barrel_a2a_schema, Type}'.
%%%
%%% {@link validate/2} checks a decoded JSON value against
%%% `#/$defs/Type'. The bundle has no `required' lists, so a missing
%%% field passes; a wrongly typed or unknown field does not.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_schema).

-export([load/0, types/0, validate/2, schema/0, version/0]).

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

%% @doc Validate `Value' against `#/$defs/Type'.
-spec validate(binary(), term()) -> ok | {error, [barrel_a2a_jsonschema:error()]}.
validate(Type, Value) when is_binary(Type) ->
    case compiled(Type) of
        {ok, Compiled} -> barrel_a2a_jsonschema:validate(Value, Compiled, #{});
        {error, Reason} -> {error, [{[], Reason}]}
    end.

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

compiled(Type) ->
    Key = {?MODULE, Type},
    case persistent_term:get(Key, undefined) of
        undefined ->
            case compile_type(Type) of
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
compile_type(Type) ->
    Bundle = bundle(),
    Defs = defs(Bundle),
    case maps:is_key(Type, Defs) of
        false ->
            {error, {unknown_type, Type}};
        true ->
            Doc = #{
                <<"$schema">> => maps:get(<<"$schema">>, Bundle),
                <<"$defs">> => Defs,
                <<"$ref">> => <<"#/$defs/", Type/binary>>
            },
            barrel_a2a_jsonschema:compile(Doc)
    end.
