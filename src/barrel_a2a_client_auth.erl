%%%-------------------------------------------------------------------
%%% @doc Client-side credentials (specification 7.3).
%%%
%%% Credentials are obtained out of band; this module only knows how
%%% to put them on a request:
%%%
%%% - `{bearer, Token}' or `{bearer, fun(() -> Token)}' (fresh token
%%%   per request, for rotating credentials).
%%% - `{api_key, HeaderName, Value}'.
%%% - `{basic, User, Password}'.
%%% - `fun((Op) -> [{Header, Value}])' for anything else.
%%% - `none'.
%%%
%%% {@link select/2} picks a scheme from the card's `securitySchemes'
%%% when the caller passes a map of credentials keyed by scheme name.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_client_auth).

-export([normalize/1, headers/2, select/2]).

-type config() ::
    none
    | {bearer, binary() | fun(() -> binary())}
    | {api_key, binary(), binary()}
    | {basic, binary(), binary()}
    | fun((barrel_a2a:op() | atom()) -> [{binary(), binary()}]).

-export_type([config/0]).

-spec normalize(term()) -> {ok, config()} | {error, term()}.
normalize(none) -> {ok, none};
normalize(undefined) -> {ok, none};
normalize({bearer, T} = C) when is_binary(T); is_function(T, 0) -> {ok, C};
normalize({api_key, H, V} = C) when is_binary(H), is_binary(V) -> {ok, C};
normalize({basic, U, P} = C) when is_binary(U), is_binary(P) -> {ok, C};
normalize(F) when is_function(F, 1) -> {ok, F};
normalize(Other) -> {error, {invalid_auth, Other}}.

-spec headers(config(), barrel_a2a:op() | atom()) -> [{binary(), binary()}].
headers(none, _) ->
    [];
headers({bearer, Fun}, _) when is_function(Fun, 0) ->
    [{<<"authorization">>, <<"Bearer ", (Fun())/binary>>}];
headers({bearer, Token}, _) ->
    [{<<"authorization">>, <<"Bearer ", Token/binary>>}];
headers({api_key, Name, Value}, _) ->
    [{Name, Value}];
headers({basic, User, Pass}, _) ->
    [
        {<<"authorization">>,
            <<"Basic ", (base64:encode(<<User/binary, ":", Pass/binary>>))/binary>>}
    ];
headers(Fun, Op) when is_function(Fun, 1) ->
    Fun(Op).

%% @doc Given credentials keyed by security scheme name
%% (`#{<<"google">> => {bearer, T}}') and a card, pick the first
%% scheme the card's `securityRequirements' (or `securitySchemes')
%% names for which credentials exist.
-spec select(#{binary() => config()}, barrel_a2a:agent_card()) -> {ok, config()} | error.
select(Credentials, Card) ->
    Required = [
        Name
     || Req <- barrel_a2a_agent_card:security_requirements(Card),
        Name <- requirement_names(Req)
    ],
    Declared = maps:keys(barrel_a2a_agent_card:security_schemes(Card)),
    Candidates = Required ++ Declared,
    case [C || N <- Candidates, C <- [maps:get(N, Credentials, undefined)], C =/= undefined] of
        [C | _] -> {ok, C};
        [] -> error
    end.

requirement_names(#{<<"schemes">> := Schemes}) when is_map(Schemes) -> maps:keys(Schemes);
requirement_names(Req) when is_map(Req) -> maps:keys(Req).
