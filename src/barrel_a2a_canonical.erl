%%%-------------------------------------------------------------------
%%% @doc RFC 8785 JSON Canonicalization Scheme (JCS) for Agent Card
%%% signing (8.4.1).
%%%
%%% {@link encode/1} serializes a decoded JSON term to the unique JCS
%%% byte string: object members sorted by the UTF-16 code units of
%%% their keys, no whitespace, minimal string escaping, and numbers
%%% printed as ECMAScript `Number.prototype.toString' does.
%%%
%%% {@link agent_card_payload/1} applies the A2A presence rules to an
%%% Agent Card before it is canonicalized: the `signatures' member is
%%% removed and proto3 default values are dropped unless the field is
%%% required or marked `optional' in the protobuf definition.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_canonical).

-export([encode/1, agent_card_payload/1]).

%%--------------------------------------------------------------------
%% Canonical encoding
%%--------------------------------------------------------------------

-spec encode(barrel_a2a:json()) -> binary().
encode(Term) ->
    iolist_to_binary(enc(Term)).

enc(null) ->
    <<"null">>;
enc(true) ->
    <<"true">>;
enc(false) ->
    <<"false">>;
enc(I) when is_integer(I) ->
    integer_to_binary(I);
enc(F) when is_float(F) ->
    number(F);
enc(B) when is_binary(B) ->
    string(B);
enc(L) when is_list(L) ->
    [$[, join([enc(E) || E <- L]), $]];
enc(M) when is_map(M) ->
    Members = lists:keysort(1, [{sort_key(K), K, V} || K := V <- M]),
    [${, join([[string(K), $:, enc(V)] || {_, K, V} <- Members]), $}];
enc(Other) ->
    error({not_json, Other}).

join([]) -> [];
join([H | T]) -> [H | [[$,, E] || E <- T]].

%% Keys compare by UTF-16 code unit, which is the byte order of the
%% big-endian UTF-16 encoding.
sort_key(Key) when is_binary(Key) ->
    case unicode:characters_to_binary(Key, utf8, utf16) of
        Utf16 when is_binary(Utf16) -> Utf16;
        _ -> error({not_json, Key})
    end;
sort_key(Key) ->
    error({not_json, Key}).

%% RFC 8785 3.2.2.2: escape only the quote, the backslash and the
%% control characters; everything else is emitted as literal UTF-8.
string(Bin) ->
    [$", escape(Bin), $"].

escape(<<>>) ->
    [];
escape(<<C, Rest/binary>>) when C < 16#20; C =:= $"; C =:= $\\ ->
    [escape_char(C) | escape(Rest)];
escape(Bin) ->
    Len = literal_run(Bin, 0),
    <<Run:Len/binary, Rest/binary>> = Bin,
    [Run | escape(Rest)].

literal_run(<<C, _/binary>>, N) when C < 16#20; C =:= $"; C =:= $\\ -> N;
literal_run(<<_, Rest/binary>>, N) -> literal_run(Rest, N + 1);
literal_run(<<>>, N) -> N.

escape_char($") -> <<"\\\"">>;
escape_char($\\) -> <<"\\\\">>;
escape_char($\b) -> <<"\\b">>;
escape_char($\f) -> <<"\\f">>;
escape_char($\n) -> <<"\\n">>;
escape_char($\r) -> <<"\\r">>;
escape_char($\t) -> <<"\\t">>;
escape_char(C) -> io_lib:format("\\u~4.16.0b", [C]).

%% RFC 8785 3.2.2.3: ECMAScript `Number.prototype.toString'. The
%% shortest round-trip digits come from `float_to_binary/2' and are
%% re-laid-out following ECMA-262 Number::toString.
number(F) when F == 0 ->
    <<"0">>;
number(F) ->
    {Digits, N} = decimal(float_to_binary(abs(F), [short])),
    Sign =
        case F < 0 of
            true -> <<"-">>;
            false -> <<>>
        end,
    [Sign, es_number(Digits, byte_size(Digits), N)].

%% Splits the printed float into its significant digits D and the
%% exponent N such that the value is 0.D * 10^N.
decimal(Bin) ->
    {Mant, Exp} =
        case binary:split(Bin, <<"e">>) of
            [M] -> {M, 0};
            [M, E] -> {M, binary_to_integer(E)}
        end,
    [Int, Frac] = binary:split(Mant, <<".">>),
    strip_zeros(<<Int/binary, Frac/binary>>, byte_size(Int) + Exp).

strip_zeros(<<$0, Rest/binary>>, N) ->
    strip_zeros(Rest, N - 1);
strip_zeros(Digits, N) ->
    {string:trim(Digits, trailing, "0"), N}.

es_number(Digits, K, N) when N >= K, N =< 21 ->
    [Digits, binary:copy(<<"0">>, N - K)];
es_number(Digits, _K, N) when N > 0, N =< 21 ->
    <<Int:N/binary, Frac/binary>> = Digits,
    [Int, $., Frac];
es_number(Digits, _K, N) when N > -6, N =< 0 ->
    [<<"0.">>, binary:copy(<<"0">>, -N), Digits];
es_number(<<D, Rest/binary>>, K, N) ->
    Exp = N - 1,
    Mantissa =
        case K of
            1 -> [D];
            _ -> [D, $., Rest]
        end,
    ExpSign =
        case Exp < 0 of
            true -> $-;
            false -> $+
        end,
    [Mantissa, $e, ExpSign, integer_to_binary(abs(Exp))].

%%--------------------------------------------------------------------
%% Agent Card presence rules (8.4.1)
%%--------------------------------------------------------------------

%% @doc The Agent Card members that are covered by a signature.
%%
%% Drops `signatures' and walks the card with the protobuf field
%% presence in mind: a member holding a proto3 default (empty string,
%% zero, false, empty list, empty object, null) is removed unless the
%% field is required or declared `optional'. Struct-typed fields, map
%% values and list elements are kept as they are since they always
%% have presence.
-spec agent_card_payload(barrel_a2a:object()) -> barrel_a2a:object().
agent_card_payload(Card) when is_map(Card) ->
    prune_object(agent_card, maps:remove(<<"signatures">>, Card)).

prune_object(Kind, Obj) ->
    {Required, Optional, Children} = spec(Kind),
    maps:filtermap(
        fun(Key, Value) ->
            Pruned = prune_value(maps:get(Key, Children, unknown), Value),
            Keep =
                lists:member(Key, Required) orelse
                    lists:member(Key, Optional) orelse
                    not is_default(Pruned),
            case Keep of
                true -> {true, Pruned};
                false -> false
            end
        end,
        Obj
    ).

prune_value(opaque, Value) ->
    Value;
prune_value({list, Kind}, List) when is_list(List) ->
    [prune_value(Kind, E) || E <- List];
prune_value({map, Kind}, Map) when is_map(Map) ->
    maps:map(fun(_, V) -> prune_value(Kind, V) end, Map);
prune_value(Kind, Obj) when is_map(Obj), is_atom(Kind) ->
    prune_object(Kind, Obj);
prune_value(_, List) when is_list(List) ->
    [prune_value(unknown, E) || E <- List];
prune_value(_, Obj) when is_map(Obj) ->
    prune_object(unknown, Obj);
prune_value(_, Value) ->
    Value.

is_default(<<>>) -> true;
is_default(N) when is_number(N) -> N == 0;
is_default(false) -> true;
is_default(null) -> true;
is_default([]) -> true;
is_default(M) when is_map(M) -> map_size(M) =:= 0;
is_default(_) -> false.

%% {Required, Optional, Children}: fields kept even when they hold a
%% default, and the kind used to walk each known member.
spec(agent_card) ->
    {
        [
            <<"name">>,
            <<"description">>,
            <<"supportedInterfaces">>,
            <<"version">>,
            <<"capabilities">>,
            <<"defaultInputModes">>,
            <<"defaultOutputModes">>,
            <<"skills">>
        ],
        [<<"documentationUrl">>, <<"iconUrl">>],
        #{
            <<"capabilities">> => capabilities,
            <<"supportedInterfaces">> => {list, interface},
            <<"provider">> => provider,
            <<"skills">> => {list, skill},
            <<"securitySchemes">> => {map, security_scheme},
            <<"securityRequirements">> => opaque,
            <<"security">> => opaque,
            <<"metadata">> => opaque
        }
    };
spec(capabilities) ->
    {[], [<<"streaming">>, <<"pushNotifications">>, <<"extendedAgentCard">>], #{
        <<"extensions">> => {list, extension}
    }};
spec(extension) ->
    {[], [], #{<<"params">> => opaque}};
spec(interface) ->
    {[<<"url">>, <<"protocolBinding">>, <<"protocolVersion">>], [], #{}};
spec(provider) ->
    {[<<"url">>, <<"organization">>], [], #{}};
spec(skill) ->
    {[<<"id">>, <<"name">>, <<"description">>, <<"tags">>], [], #{
        <<"security">> => opaque
    }};
spec(signature) ->
    {[<<"protected">>, <<"signature">>], [], #{<<"header">> => opaque}};
%% The scheme wrapper is a oneof: the set member has presence.
spec(security_scheme) ->
    {
        [],
        [
            <<"apiKeySecurityScheme">>,
            <<"httpAuthSecurityScheme">>,
            <<"oauth2SecurityScheme">>,
            <<"openIdConnectSecurityScheme">>,
            <<"mtlsSecurityScheme">>
        ],
        #{
            <<"apiKeySecurityScheme">> => api_key_scheme,
            <<"httpAuthSecurityScheme">> => http_auth_scheme,
            <<"oauth2SecurityScheme">> => oauth2_scheme,
            <<"openIdConnectSecurityScheme">> => oidc_scheme,
            <<"mtlsSecurityScheme">> => mtls_scheme
        }
    };
spec(api_key_scheme) ->
    {[<<"location">>, <<"name">>], [], #{}};
spec(http_auth_scheme) ->
    {[<<"scheme">>], [], #{}};
spec(oauth2_scheme) ->
    {[<<"flows">>], [], #{<<"flows">> => oauth_flows}};
spec(oidc_scheme) ->
    {[<<"openIdConnectUrl">>], [], #{}};
spec(mtls_scheme) ->
    {[], [], #{}};
spec(oauth_flows) ->
    {
        [],
        [
            <<"authorizationCode">>,
            <<"clientCredentials">>,
            <<"implicit">>,
            <<"password">>,
            <<"deviceCode">>
        ],
        #{
            <<"authorizationCode">> => authorization_code_flow,
            <<"clientCredentials">> => client_credentials_flow,
            <<"implicit">> => implicit_flow,
            <<"password">> => password_flow,
            <<"deviceCode">> => device_code_flow
        }
    };
spec(authorization_code_flow) ->
    {[<<"authorizationUrl">>, <<"tokenUrl">>, <<"scopes">>], [], #{<<"scopes">> => opaque}};
spec(client_credentials_flow) ->
    {[<<"tokenUrl">>, <<"scopes">>], [], #{<<"scopes">> => opaque}};
spec(implicit_flow) ->
    {[<<"authorizationUrl">>, <<"scopes">>], [], #{<<"scopes">> => opaque}};
spec(password_flow) ->
    {[<<"tokenUrl">>, <<"scopes">>], [], #{<<"scopes">> => opaque}};
spec(device_code_flow) ->
    {[<<"deviceAuthorizationUrl">>, <<"tokenUrl">>, <<"scopes">>], [], #{<<"scopes">> => opaque}};
spec(unknown) ->
    {[], [], #{}}.
