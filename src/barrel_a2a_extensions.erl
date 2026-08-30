%%%-------------------------------------------------------------------
%%% @doc Extension negotiation (specification 4.6, 3.2.6).
%%%
%%% The client lists the extension URIs it wants in `A2A-Extensions';
%%% the server intersects that with what its card declares. An
%%% extension the card marks `required' that the client did not
%%% request is an `ExtensionSupportRequiredError'. Unknown requested
%%% extensions are ignored, never version-matched (4.6.3).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_extensions).

-export([parse_header/1, format_header/1, negotiate/2, declared/1]).

-spec parse_header(binary() | undefined) -> [binary()].
parse_header(undefined) ->
    [];
parse_header(Bin) ->
    [
        U
     || U <- [string:trim(X) || X <- binary:split(Bin, <<",">>, [global])],
        U =/= <<>>
    ].

-spec format_header([binary()]) -> binary() | undefined.
format_header([]) -> undefined;
format_header(Uris) -> iolist_to_binary(lists:join(<<",">>, Uris)).

-spec declared(barrel_a2a:agent_card()) -> [binary()].
declared(Card) ->
    [U || #{<<"uri">> := U} <- barrel_a2a_agent_card:extensions(Card), is_binary(U)].

%% @doc Returns the active set, or the first required extension the
%% client did not opt into.
-spec negotiate([binary()], barrel_a2a:agent_card()) ->
    {ok, [binary()]} | {error, {required, binary()}}.
negotiate(Requested, Card) ->
    Declared = declared(Card),
    Required = barrel_a2a_agent_card:required_extensions(Card),
    case [R || R <- Required, not lists:member(R, Requested)] of
        [Missing | _] -> {error, {required, Missing}};
        [] -> {ok, [U || U <- Requested, lists:member(U, Declared)]}
    end.
