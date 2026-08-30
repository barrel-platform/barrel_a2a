%%%-------------------------------------------------------------------
%%% @doc `AgentCard' objects (specification 4.4, 8).
%%%
%%% {@link new/1} builds a card from a friendly map and fills the
%%% required defaults; the accessors read the wire shape. Interface
%%% selection (8.3.2) and the security scheme builders (4.5) live
%%% here too.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_agent_card).

-export([new/1]).
-export([
    name/1,
    description/1,
    version/1,
    skills/1,
    skill/2,
    interfaces/1,
    capabilities/1,
    supports/2,
    extensions/1,
    required_extensions/1,
    security_schemes/1,
    security_requirements/1,
    default_input_modes/1,
    default_output_modes/1,
    signatures/1
]).
-export([select_interface/2, select_interface/3, with_interfaces/2, interface/3, interface/4]).
-export([skill/1, security_scheme/2, etag/1]).

-type card() :: barrel_a2a:agent_card().
%% `#{<<"url">>, <<"protocolBinding">>, <<"protocolVersion">>, <<"tenant">>?}'.
-type interface() :: #{binary() => binary()}.

-export_type([card/0, interface/0]).

%% @doc Build a card. Keys may be atoms (snake_case) or the wire
%% binaries; required fields get defaults: `description' `<<>>',
%% `version' `<<"0.1.0">>', modes `["text/plain"]', empty skills,
%% empty interfaces, capabilities `#{}'.
-spec new(map()) -> card().
new(Spec) ->
    Wire = deep_keys_to_wire(Spec),
    Defaults = #{
        <<"description">> => <<>>,
        <<"version">> => <<"0.1.0">>,
        <<"supportedInterfaces">> => [],
        <<"capabilities">> => #{},
        <<"defaultInputModes">> => [<<"text/plain">>],
        <<"defaultOutputModes">> => [<<"text/plain">>],
        <<"skills">> => []
    },
    Card = maps:merge(Defaults, Wire),
    Card#{
        <<"skills">> => [skill(S) || S <- maps:get(<<"skills">>, Card)],
        <<"capabilities">> => keys_to_wire(maps:get(<<"capabilities">>, Card)),
        <<"supportedInterfaces">> => [
            keys_to_wire(I)
         || I <- maps:get(<<"supportedInterfaces">>, Card)
        ]
    }.

%% @doc Normalize a skill spec (atom or binary keys) into wire form.
-spec skill(map()) -> barrel_a2a:object().
skill(Spec) ->
    S = keys_to_wire(Spec),
    maps:merge(#{<<"description">> => <<>>, <<"tags">> => []}, S).

keys_to_wire(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) -> Acc#{key(K) => V} end, #{}, Map);
keys_to_wire(Other) ->
    Other.

%% Atom keys anywhere in the spec become camelCase wire keys; values
%% under `metadata' and `params' are opaque JSON and left alone.
deep_keys_to_wire(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = key(K),
            case Key of
                <<"metadata">> -> Acc#{Key => V};
                <<"params">> -> Acc#{Key => V};
                _ -> Acc#{Key => deep_keys_to_wire(V)}
            end
        end,
        #{},
        Map
    );
deep_keys_to_wire(List) when is_list(List) ->
    [deep_keys_to_wire(V) || V <- List];
deep_keys_to_wire(Other) ->
    Other.

key(K) when is_binary(K) -> K;
key(K) when is_atom(K) -> camel(atom_to_binary(K, utf8)).

camel(Bin) ->
    [First | Rest] = binary:split(Bin, <<"_">>, [global]),
    iolist_to_binary([First | [capitalize(R) || R <- Rest]]).

capitalize(<<C, Rest/binary>>) when C >= $a, C =< $z -> <<(C - 32), Rest/binary>>;
capitalize(B) -> B.

-spec name(card()) -> binary().
name(#{<<"name">> := N}) when is_binary(N) -> N;
name(_) -> <<>>.

-spec description(card()) -> binary().
description(#{<<"description">> := D}) when is_binary(D) -> D;
description(_) -> <<>>.

-spec version(card()) -> binary().
version(#{<<"version">> := V}) when is_binary(V) -> V;
version(_) -> <<>>.

-spec skills(card()) -> [barrel_a2a:object()].
skills(#{<<"skills">> := S}) when is_list(S) -> S;
skills(_) -> [].

-spec skill(card(), binary()) -> barrel_a2a:object() | undefined.
skill(Card, Id) ->
    case [S || S <- skills(Card), maps:get(<<"id">>, S, undefined) =:= Id] of
        [S | _] -> S;
        [] -> undefined
    end.

-spec interfaces(card()) -> [interface()].
interfaces(#{<<"supportedInterfaces">> := I}) when is_list(I) -> I;
interfaces(_) -> [].

-spec capabilities(card()) -> map().
capabilities(#{<<"capabilities">> := C}) when is_map(C) -> C;
capabilities(_) -> #{}.

-spec supports(card(), streaming | push_notifications | extended_agent_card) -> boolean().
supports(Card, streaming) ->
    maps:get(<<"streaming">>, capabilities(Card), false) =:= true;
supports(Card, push_notifications) ->
    maps:get(<<"pushNotifications">>, capabilities(Card), false) =:= true;
supports(Card, extended_agent_card) ->
    maps:get(<<"extendedAgentCard">>, capabilities(Card), false) =:= true.

-spec extensions(card()) -> [barrel_a2a:object()].
extensions(Card) ->
    case maps:get(<<"extensions">>, capabilities(Card), []) of
        L when is_list(L) -> [E || E <- L, is_map(E)];
        _ -> []
    end.

%% @doc URIs of extensions declared `required: true'.
-spec required_extensions(card()) -> [binary()].
required_extensions(Card) ->
    [
        U
     || #{<<"uri">> := U} = E <- extensions(Card),
        maps:get(<<"required">>, E, false) =:= true,
        is_binary(U)
    ].

-spec security_schemes(card()) -> map().
security_schemes(#{<<"securitySchemes">> := S}) when is_map(S) -> S;
security_schemes(_) -> #{}.

-spec security_requirements(card()) -> [map()].
security_requirements(#{<<"securityRequirements">> := R}) when is_list(R) -> R;
security_requirements(_) -> [].

-spec default_input_modes(card()) -> [binary()].
default_input_modes(#{<<"defaultInputModes">> := M}) when is_list(M) -> M;
default_input_modes(_) -> [].

-spec default_output_modes(card()) -> [binary()].
default_output_modes(#{<<"defaultOutputModes">> := M}) when is_list(M) -> M;
default_output_modes(_) -> [].

-spec signatures(card()) -> [map()].
signatures(#{<<"signatures">> := S}) when is_list(S) -> S;
signatures(_) -> [].

%% @doc An interface entry.
-spec interface(binary(), binary(), binary()) -> interface().
interface(Url, Binding, Version) ->
    #{<<"url">> => Url, <<"protocolBinding">> => Binding, <<"protocolVersion">> => Version}.

-spec interface(binary(), binary(), binary(), binary() | undefined) -> interface().
interface(Url, Binding, Version, undefined) ->
    interface(Url, Binding, Version);
interface(Url, Binding, Version, Tenant) ->
    (interface(Url, Binding, Version))#{<<"tenant">> => Tenant}.

-spec with_interfaces([interface()], card()) -> card().
with_interfaces(Interfaces, Card) -> Card#{<<"supportedInterfaces">> => Interfaces}.

%% @doc Pick the first interface whose binding the caller supports,
%% in card order (specification 8.3.2).
-spec select_interface(card(), [binary()]) -> {ok, interface()} | error.
select_interface(Card, SupportedBindings) ->
    select_interface(Card, SupportedBindings, []).

%% @doc As `select_interface/2', but `Prefer' (bindings in preference
%% order) is consulted first; the card order breaks ties among the
%% preferred ones and decides for the rest.
-spec select_interface(card(), [binary()], [binary()]) -> {ok, interface()} | error.
select_interface(Card, SupportedBindings, Prefer) ->
    Candidates = [
        I
     || #{<<"protocolBinding">> := B} = I <- interfaces(Card),
        lists:member(B, SupportedBindings),
        is_binary(maps:get(<<"url">>, I, undefined))
    ],
    Preferred = [
        I
     || P <- Prefer, #{<<"protocolBinding">> := B} = I <- Candidates, B =:= P
    ],
    case Preferred ++ Candidates of
        [I | _] -> {ok, I};
        [] -> error
    end.

%% @doc Security scheme objects (specification 4.5). Each returns the
%% `SecurityScheme' wrapper with the right oneof member.
-spec security_scheme(
    api_key | http | oauth2 | openid_connect | mtls,
    map()
) -> barrel_a2a:object().
security_scheme(api_key, #{location := Loc, name := Name} = O) ->
    #{
        <<"apiKeySecurityScheme">> => with_desc(
            #{<<"location">> => to_bin(Loc), <<"name">> => Name}, O
        )
    };
security_scheme(http, #{scheme := Scheme} = O) ->
    Base = #{<<"scheme">> => Scheme},
    WithFormat =
        case maps:get(bearer_format, O, undefined) of
            undefined -> Base;
            F -> Base#{<<"bearerFormat">> => F}
        end,
    #{<<"httpAuthSecurityScheme">> => with_desc(WithFormat, O)};
security_scheme(oauth2, #{flows := Flows} = O) ->
    Base = #{<<"flows">> => Flows},
    WithMeta =
        case maps:get(oauth2_metadata_url, O, undefined) of
            undefined -> Base;
            U -> Base#{<<"oauth2MetadataUrl">> => U}
        end,
    #{<<"oauth2SecurityScheme">> => with_desc(WithMeta, O)};
security_scheme(openid_connect, #{open_id_connect_url := Url} = O) ->
    #{<<"openIdConnectSecurityScheme">> => with_desc(#{<<"openIdConnectUrl">> => Url}, O)};
security_scheme(mtls, O) ->
    #{<<"mtlsSecurityScheme">> => with_desc(#{}, O)}.

with_desc(Map, #{description := D}) -> Map#{<<"description">> => D};
with_desc(Map, _) -> Map.

to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(B) -> B.

%% @doc A strong ETag derived from the card content (8.6.1).
-spec etag(card()) -> binary().
etag(Card) ->
    Hash = crypto:hash(sha256, barrel_a2a_json:encode(Card)),
    <<$", (binary:encode_hex(binary:part(Hash, 0, 16), lowercase))/binary, $">>.
