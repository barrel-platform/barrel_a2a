%%%-------------------------------------------------------------------
%%% @doc Timestamps.
%%%
%%% The wire carries ISO 8601 UTC text with millisecond precision and
%%% a `Z' suffix (specification 5.6.1). Internally milliseconds since
%%% the Unix epoch are used.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_time).

-export([now_ms/0, now_iso/0, to_iso/1, from_iso/1, is_iso/1]).

-spec now_ms() -> integer().
now_ms() -> erlang:system_time(millisecond).

-spec now_iso() -> binary().
now_iso() -> to_iso(now_ms()).

-spec to_iso(integer()) -> binary().
to_iso(Ms) when is_integer(Ms) ->
    Seconds = Ms div 1000,
    Millis = Ms rem 1000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(
        io_lib:format("~4.10.0b-~2.10.0b-~2.10.0bT~2.10.0b:~2.10.0b:~2.10.0b.~3.10.0bZ", [
            Y, Mo, D, H, Mi, S, Millis
        ])
    ).

%% @doc Parse an RFC 3339 timestamp. Offsets other than `Z' are
%% accepted on input and normalized to UTC; fractional seconds of any
%% length are truncated to milliseconds.
-spec from_iso(binary()) -> {ok, integer()} | error.
from_iso(Bin) when is_binary(Bin) ->
    try
        Str = binary_to_list(Bin),
        Sys = calendar:rfc3339_to_system_time(Str, [{unit, millisecond}]),
        {ok, Sys}
    catch
        _:_ -> error
    end;
from_iso(_) ->
    error.

-spec is_iso(term()) -> boolean().
is_iso(Bin) ->
    case from_iso(Bin) of
        {ok, _} -> true;
        error -> false
    end.
