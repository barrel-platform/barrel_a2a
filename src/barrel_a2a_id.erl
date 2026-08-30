%%%-------------------------------------------------------------------
%%% @doc Identifier generation.
%%%
%%% Task, context, message, artifact and push-configuration ids are
%%% random UUID v4 strings. Cursor tokens for pagination are opaque
%%% base64url blobs built here so that they never look like ids.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_id).

-export([uuid/0, is_uuid/1, cursor_encode/1, cursor_decode/1]).

-spec uuid() -> binary().
uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, D:30, E:32>> = crypto:strong_rand_bytes(16),
    V = 4,
    R = 2,
    Bin = <<A:32, B:16, V:4, C:12, R:2, D:30, E:32>>,
    <<P1:32, P2:16, P3:16, P4:16, P5:48>> = Bin,
    iolist_to_binary(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [P1, P2, P3, P4, P5])
    ).

-spec is_uuid(term()) -> boolean().
is_uuid(<<_:8/binary, $-, _:4/binary, $-, _:4/binary, $-, _:4/binary, $-, _:12/binary>> = B) ->
    lists:all(fun(C) -> C =:= $- orelse is_hex(C) end, binary_to_list(B));
is_uuid(_) ->
    false.

is_hex(C) when C >= $0, C =< $9 -> true;
is_hex(C) when C >= $a, C =< $f -> true;
is_hex(C) when C >= $A, C =< $F -> true;
is_hex(_) -> false.

%% @doc Encode a pagination cursor. The term is `term_to_binary'
%% encoded and base64url wrapped; callers treat it as opaque.
-spec cursor_encode(term()) -> binary().
cursor_encode(Term) ->
    base64:encode(term_to_binary(Term), #{mode => urlsafe, padding => false}).

-spec cursor_decode(binary()) -> {ok, term()} | error.
cursor_decode(Bin) when is_binary(Bin) ->
    try
        {ok, binary_to_term(base64:decode(Bin, #{mode => urlsafe, padding => false}), [safe])}
    catch
        _:_ -> error
    end;
cursor_decode(_) ->
    error.
