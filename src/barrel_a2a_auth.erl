%%%-------------------------------------------------------------------
%%% @doc Server-side authentication hook (specification 7.3 to 7.5).
%%%
%%% The hook is binding-neutral: it sees the request headers (gRPC
%%% metadata for that binding), the operation and the binding, and
%%% returns a principal. Configured as:
%%%
%%% - `none': every request is `anonymous'.
%%% - `{bearer, Fun}': `Fun(Token) -> {ok, Principal} | {error, Reason}'
%%%   on the `Authorization: Bearer' value.
%%% - `{api_key, HeaderName, Fun}': `Fun(Key)' on that header.
%%% - `{basic, Fun}': `Fun(User, Password)'.
%%% - `{Module, State}': `Module:authenticate(Request, State)' with
%%%   `Request = #{headers, op, binding, peer}'.
%%% - a `fun((Request) -> {ok, Principal} | {error, Reason})'.
%%%
%%% Errors: `unauthenticated' (401) or `forbidden' (403); any other
%%% reason is treated as unauthenticated and logged.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_auth).

-export([normalize/1, authenticate/3, challenge_headers/2, header/2]).

-type request() :: #{
    headers := [{binary(), binary()}],
    op := barrel_a2a:op() | atom(),
    binding := atom(),
    peer => term()
}.
-type result() :: {ok, barrel_a2a:principal()} | {error, unauthenticated | forbidden | term()}.
-type config() ::
    none
    | {bearer, fun((binary()) -> result())}
    | {api_key, binary(), fun((binary()) -> result())}
    | {basic, fun((binary(), binary()) -> result())}
    | {module(), term()}
    | fun((request()) -> result()).

-export_type([request/0, result/0, config/0]).

-callback authenticate(request(), term()) -> result().

-spec normalize(term()) -> {ok, config()} | {error, term()}.
normalize(none) ->
    {ok, none};
normalize(undefined) ->
    {ok, none};
normalize({bearer, F} = C) when is_function(F, 1) -> {ok, C};
normalize({api_key, H, F} = C) when is_binary(H), is_function(F, 1) -> {ok, C};
normalize({basic, F} = C) when is_function(F, 2) -> {ok, C};
normalize(F) when is_function(F, 1) -> {ok, F};
normalize({Mod, _} = C) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, _} ->
            case erlang:function_exported(Mod, authenticate, 2) of
                true -> {ok, C};
                false -> {error, {auth_missing_callback, Mod}}
            end;
        {error, R} ->
            {error, {auth_not_loaded, Mod, R}}
    end;
normalize(Other) ->
    {error, {invalid_auth, Other}}.

-spec authenticate(config(), request(), map()) -> result().
authenticate(none, _Request, _Opts) ->
    {ok, anonymous};
authenticate({bearer, Fun}, #{headers := Headers}, _Opts) ->
    case bearer_token(Headers) of
        undefined -> {error, unauthenticated};
        Token -> guard(fun() -> Fun(Token) end)
    end;
authenticate({api_key, Name, Fun}, #{headers := Headers}, _Opts) ->
    case header(string:lowercase(Name), Headers) of
        undefined -> {error, unauthenticated};
        Key -> guard(fun() -> Fun(Key) end)
    end;
authenticate({basic, Fun}, #{headers := Headers}, _Opts) ->
    case basic_credentials(Headers) of
        undefined -> {error, unauthenticated};
        {User, Pass} -> guard(fun() -> Fun(User, Pass) end)
    end;
authenticate(Fun, Request, _Opts) when is_function(Fun, 1) ->
    guard(fun() -> Fun(Request) end);
authenticate({Mod, State}, Request, _Opts) ->
    guard(fun() -> Mod:authenticate(Request, State) end).

guard(Fun) ->
    try Fun() of
        {ok, _} = Ok ->
            Ok;
        {error, unauthenticated} = E ->
            E;
        {error, forbidden} = E ->
            E;
        {error, Other} ->
            logger:notice("a2a auth hook rejected request: ~0p", [Other]),
            {error, unauthenticated};
        Other ->
            logger:warning("a2a auth hook returned ~0p", [Other]),
            {error, unauthenticated}
    catch
        Class:Reason ->
            logger:warning("a2a auth hook crashed: ~0p:~0p", [Class, Reason]),
            {error, unauthenticated}
    end.

%% @doc `WWW-Authenticate' challenges for a 401, from the configured
%% hook and the card's declared security schemes (13.3).
-spec challenge_headers(config(), barrel_a2a:agent_card()) -> [{binary(), binary()}].
challenge_headers(Config, Card) ->
    Schemes = maps:values(barrel_a2a_agent_card:security_schemes(Card)),
    FromCard = lists:usort(lists:filtermap(fun challenge_for_scheme/1, Schemes)),
    FromConfig =
        case Config of
            {bearer, _} -> [<<"Bearer">>];
            {basic, _} -> [<<"Basic realm=\"a2a\"">>];
            _ -> []
        end,
    case lists:usort(FromCard ++ FromConfig) of
        [] -> [];
        Challenges -> [{<<"www-authenticate">>, iolist_to_binary(lists:join(<<", ">>, Challenges))}]
    end.

challenge_for_scheme(#{<<"httpAuthSecurityScheme">> := #{<<"scheme">> := S}}) when is_binary(S) ->
    {true, capitalize(S)};
challenge_for_scheme(#{<<"oauth2SecurityScheme">> := _}) ->
    {true, <<"Bearer">>};
challenge_for_scheme(#{<<"openIdConnectSecurityScheme">> := _}) ->
    {true, <<"Bearer">>};
challenge_for_scheme(_) ->
    false.

capitalize(<<C, Rest/binary>>) when C >= $a, C =< $z -> <<(C - 32), Rest/binary>>;
capitalize(B) -> B.

-spec header(binary(), [{binary(), binary()}]) -> binary() | undefined.
header(Name, Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(K) =:= Name] of
        [V | _] -> V;
        [] -> undefined
    end.

bearer_token(Headers) ->
    case header(<<"authorization">>, Headers) of
        undefined ->
            undefined;
        Value ->
            case binary:split(string:trim(Value), <<" ">>) of
                [Scheme, Token] ->
                    case string:lowercase(Scheme) of
                        <<"bearer">> -> string:trim(Token);
                        _ -> undefined
                    end;
                _ ->
                    undefined
            end
    end.

basic_credentials(Headers) ->
    case header(<<"authorization">>, Headers) of
        undefined ->
            undefined;
        Value ->
            case binary:split(string:trim(Value), <<" ">>) of
                [Scheme, Encoded] ->
                    case string:lowercase(Scheme) of
                        <<"basic">> -> decode_basic(string:trim(Encoded));
                        _ -> undefined
                    end;
                _ ->
                    undefined
            end
    end.

decode_basic(Encoded) ->
    try base64:decode(Encoded) of
        Decoded ->
            case binary:split(Decoded, <<":">>) of
                [User, Pass] -> {User, Pass};
                _ -> undefined
            end
    catch
        _:_ -> undefined
    end.
