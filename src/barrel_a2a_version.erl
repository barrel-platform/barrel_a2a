%%%-------------------------------------------------------------------
%%% @doc Protocol version negotiation (specification 3.6).
%%%
%%% Versions are `Major.Minor'. A patch element is tolerated on input
%%% and ignored. An absent or empty version means `0.3'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_version).

-export([parse/1, normalize/1, negotiate/2, requested/1]).

%% @doc Parse `<<"1.0">>' or `<<"1.0.3">>' into `{1, 0}'.
-spec parse(binary() | undefined) -> {ok, {non_neg_integer(), non_neg_integer()}} | error.
parse(undefined) ->
    parse(barrel_a2a:legacy_version());
parse(<<>>) ->
    parse(barrel_a2a:legacy_version());
parse(Bin) when is_binary(Bin) ->
    case binary:split(string:trim(Bin), <<".">>, [global]) of
        [Maj, Min | _] ->
            try
                {ok, {binary_to_integer(Maj), binary_to_integer(Min)}}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end;
parse(_) ->
    error.

%% @doc `Major.Minor' text for a parsed or raw version.
-spec normalize(binary() | undefined | {non_neg_integer(), non_neg_integer()}) ->
    binary() | undefined.
normalize({Maj, Min}) ->
    <<(integer_to_binary(Maj))/binary, ".", (integer_to_binary(Min))/binary>>;
normalize(Raw) ->
    case parse(Raw) of
        {ok, V} -> normalize(V);
        error -> undefined
    end.

%% @doc The version a request asked for, as `Major.Minor', given the
%% raw `A2A-Version' value (header or query parameter).
-spec requested(binary() | undefined) -> binary() | undefined.
requested(Raw) -> normalize(Raw).

%% @doc Check the requested version against what the server supports.
-spec negotiate(binary() | undefined, [binary()]) -> {ok, binary()} | {error, unsupported}.
negotiate(Raw, Supported) ->
    case normalize(Raw) of
        undefined ->
            {error, unsupported};
        Version ->
            Norm = [normalize(S) || S <- Supported],
            case lists:member(Version, Norm) of
                true -> {ok, Version};
                false -> {error, unsupported}
            end
    end.
