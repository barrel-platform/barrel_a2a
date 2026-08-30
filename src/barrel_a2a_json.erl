%%%-------------------------------------------------------------------
%%% @doc JSON encode and decode over the OTP `json' module.
%%%
%%% Decoding is bounded: a document nested deeper than
%%% `max_json_depth' (default 64) is refused before the stack grows,
%%% and trailing bytes after the value are an error. Duplicate keys
%%% keep the first occurrence, as the default decoder does.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_json).

-export([encode/1, decode/1, decode/2]).
-export([is_json_media_type/1, is_a2a_media_type/1]).

-define(DEFAULT_MAX_DEPTH, 64).

-spec encode(barrel_a2a:json()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(Term)).

-spec decode(binary()) -> {ok, barrel_a2a:json()} | {error, parse_error | too_deep}.
decode(Binary) ->
    decode(Binary, #{}).

-spec decode(binary(), #{max_depth => pos_integer()}) ->
    {ok, barrel_a2a:json()} | {error, parse_error | too_deep}.
decode(Binary, Opts) when is_binary(Binary) ->
    Max = maps:get(max_depth, Opts, ?DEFAULT_MAX_DEPTH),
    Depth = counters:new(1, []),
    try json:decode(Binary, ok, depth_counting_decoders(Depth, Max)) of
        {Term, _Acc, <<>>} -> {ok, Term};
        {Term, _Acc, Trailing} -> trailing(Term, Trailing)
    catch
        error:too_deep -> {error, too_deep};
        _:_ -> {error, parse_error}
    end;
decode(_, _) ->
    {error, parse_error}.

trailing(Term, Trailing) ->
    case string:trim(Trailing) of
        <<>> -> {ok, Term};
        _ -> {error, parse_error}
    end.

%% Every container start bumps the depth, every finish drops it. The
%% object accumulator is left unreversed so `maps:from_list/1' keeps
%% the first duplicate key, matching the default decoder.
depth_counting_decoders(Depth, Max) ->
    Enter = fun() ->
        counters:add(Depth, 1, 1),
        case counters:get(Depth, 1) > Max of
            true -> error(too_deep);
            false -> ok
        end
    end,
    Leave = fun() -> counters:sub(Depth, 1, 1) end,
    #{
        object_start => fun(_) ->
            Enter(),
            []
        end,
        object_push => fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
        object_finish => fun(Acc, OldAcc) ->
            Leave(),
            {maps:from_list(Acc), OldAcc}
        end,
        array_start => fun(_) ->
            Enter(),
            []
        end,
        array_push => fun(Value, Acc) -> [Value | Acc] end,
        array_finish => fun(Acc, OldAcc) ->
            Leave(),
            {lists:reverse(Acc), OldAcc}
        end
    }.

%% @doc True for `application/json', `application/a2a+json' and any
%% `+json' structured syntax, ignoring parameters and case.
-spec is_json_media_type(binary() | undefined) -> boolean().
is_json_media_type(undefined) ->
    false;
is_json_media_type(ContentType) ->
    Type = media_type_only(ContentType),
    Type =:= <<"application/json">> orelse
        binary:longest_common_suffix([Type, <<"+json">>]) =:= 5.

-spec is_a2a_media_type(binary() | undefined) -> boolean().
is_a2a_media_type(undefined) -> false;
is_a2a_media_type(ContentType) -> media_type_only(ContentType) =:= barrel_a2a:media_type().

media_type_only(ContentType) ->
    [Type | _] = binary:split(ContentType, <<";">>),
    string:lowercase(string:trim(Type)).
