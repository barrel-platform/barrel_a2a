%%%-------------------------------------------------------------------
%%% @doc Agent Card signing and verification (8.4).
%%%
%%% A signature is a detached JWS (RFC 7515) over the RFC 8785
%%% canonical form of the card, with the `signatures' member and the
%%% default-valued optional members left out (see
%%% `barrel_a2a_canonical'). {@link sign/3} appends an
%%% `AgentCardSignature' object to the card's `signatures' list;
%%% {@link verify/2} checks that at least one of them verifies
%%% against a known JWK, looked up by `kid' in a local key set or
%%% fetched from the `jku' URL the protected header names.
%%%
%%% Supported algorithms: `ES256' (P-256, raw `R || S' signature),
%%% `RS256' (RSASSA-PKCS1-v1_5) and `PS256' (RSASSA-PSS, MGF1
%%% SHA-256, 32-byte salt). Only `public_key' and `crypto' are used.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_card_sign).

-include_lib("public_key/include/public_key.hrl").

-export([sign/3, verify/2, canonical_payload/1, signing_input/2]).
-export([generate_key/1, jwk/1, jwk/2, decode_pem/1]).

-type alg() :: 'ES256' | 'RS256' | 'PS256'.
%% A private key record, or a PEM binary holding one.
-type key() :: public_key:private_key() | binary().
%% A JSON Web Key as a map with binary keys.
-type jwk() :: map().
-type sign_opts() :: #{
    alg := alg(),
    kid := binary(),
    jku => binary(),
    header => map()
}.
-type verify_opts() :: #{
    keys => [jwk()] | #{binary() => jwk()},
    jwks_fetch => fun((binary()) -> {ok, [jwk()]} | {error, term()}),
    required => boolean(),
    allowed_algs => [alg()],
    now => integer()
}.
-type verify_error() ::
    unsigned
    | malformed_signature
    | {unsupported_alg, term()}
    | {unknown_key, binary()}
    | {key_expired, binary()}
    | {invalid_signature, binary()}.

-export_type([alg/0, key/0, jwk/0, sign_opts/0, verify_opts/0, verify_error/0]).

-define(ALGS, ['ES256', 'RS256', 'PS256']).
-define(PSS_OPTS, [
    {rsa_padding, rsa_pkcs1_pss_padding},
    {rsa_pss_saltlen, 32},
    {rsa_mgf1_md, sha256}
]).

%%--------------------------------------------------------------------
%% Signing
%%--------------------------------------------------------------------

%% @doc The card with a new signature appended to `signatures'.
%%
%% The protected header carries `alg', `typ' (`JOSE'), `kid' and, when
%% given, `jku'. `header' becomes the unprotected `header' member of
%% the signature object and is omitted when absent.
-spec sign(barrel_a2a:object(), key(), sign_opts()) -> barrel_a2a:object().
sign(Card, Key, #{alg := Alg, kid := Kid} = Opts) when is_map(Card) ->
    PrivKey = private_key(Key),
    Protected0 = #{
        <<"alg">> => atom_to_binary(Alg),
        <<"typ">> => <<"JOSE">>,
        <<"kid">> => Kid
    },
    Protected =
        case Opts of
            #{jku := Jku} -> Protected0#{<<"jku">> => Jku};
            _ -> Protected0
        end,
    ProtectedB64 = b64url(barrel_a2a_json:encode(Protected)),
    Input = signing_input(ProtectedB64, canonical_payload(Card)),
    Sig = #{
        <<"protected">> => ProtectedB64,
        <<"signature">> => b64url(raw_signature(Input, PrivKey, Alg))
    },
    Sig1 =
        case Opts of
            #{header := Header} when is_map(Header) -> Sig#{<<"header">> => Header};
            _ -> Sig
        end,
    Existing =
        case maps:get(<<"signatures">>, Card, []) of
            L when is_list(L) -> L;
            _ -> []
        end,
    Card#{<<"signatures">> => Existing ++ [Sig1]}.

%% @doc The RFC 8785 bytes of the card's signing payload.
-spec canonical_payload(barrel_a2a:object()) -> binary().
canonical_payload(Card) ->
    barrel_a2a_canonical:encode(barrel_a2a_canonical:agent_card_payload(Card)).

%% @doc The JWS signing input `BASE64URL(protected) . BASE64URL(payload)'.
-spec signing_input(binary(), binary()) -> binary().
signing_input(ProtectedB64, Payload) ->
    <<ProtectedB64/binary, ".", (b64url(Payload))/binary>>.

raw_signature(Input, #'ECPrivateKey'{} = Key, 'ES256') ->
    #'ECDSA-Sig-Value'{r = R, s = S} =
        public_key:der_decode('ECDSA-Sig-Value', public_key:sign(Input, sha256, Key)),
    <<R:256, S:256>>;
raw_signature(Input, #'RSAPrivateKey'{} = Key, 'RS256') ->
    public_key:sign(Input, sha256, Key);
raw_signature(Input, #'RSAPrivateKey'{} = Key, 'PS256') ->
    public_key:sign(Input, sha256, Key, ?PSS_OPTS);
raw_signature(_Input, Key, Alg) ->
    error({key_alg_mismatch, Alg, element(1, Key)}).

private_key(Pem) when is_binary(Pem) -> decode_pem(Pem);
private_key(#'ECPrivateKey'{} = Key) -> Key;
private_key(#'RSAPrivateKey'{} = Key) -> Key;
private_key(Other) -> error({bad_key, Other}).

%%--------------------------------------------------------------------
%% Verification
%%--------------------------------------------------------------------

%% @doc `ok' when at least one signature on the card verifies.
%%
%% An unsigned card is `ok' unless `required' is true. Keys are found
%% by `kid' in `keys', then through `jwks_fetch' on the header's
%% `jku' (https only). A JWK with a numeric `exp' in the past is
%% refused. On failure the error of the first signature that did not
%% verify is returned.
-spec verify(barrel_a2a:object(), verify_opts()) -> ok | {error, verify_error()}.
verify(Card, Opts) when is_map(Card), is_map(Opts) ->
    case maps:get(<<"signatures">>, Card, []) of
        [] ->
            case maps:get(required, Opts, false) of
                true -> {error, unsigned};
                false -> ok
            end;
        Sigs when is_list(Sigs) ->
            Payload = canonical_payload(maps:remove(<<"signatures">>, Card)),
            verify_any(Sigs, Payload, Opts, undefined);
        _ ->
            {error, malformed_signature}
    end.

verify_any([], _Payload, _Opts, First) ->
    {error, First};
verify_any([Sig | Rest], Payload, Opts, First) ->
    case verify_one(Sig, Payload, Opts) of
        ok -> ok;
        {error, Reason} when First =:= undefined -> verify_any(Rest, Payload, Opts, Reason);
        {error, _} -> verify_any(Rest, Payload, Opts, First)
    end.

verify_one(#{<<"protected">> := ProtectedB64, <<"signature">> := SigB64}, Payload, Opts) when
    is_binary(ProtectedB64), is_binary(SigB64)
->
    with_header(ProtectedB64, fun(Header) ->
        with_alg(Header, Opts, fun(Alg, Kid) ->
            case find_key(Kid, Header, Opts) of
                {ok, Jwk} ->
                    check_and_verify(Jwk, Alg, Kid, ProtectedB64, SigB64, Payload, Opts);
                {error, _} = Error ->
                    Error
            end
        end)
    end);
verify_one(_, _, _) ->
    {error, malformed_signature}.

with_header(ProtectedB64, Fun) ->
    case decode_header(ProtectedB64) of
        {ok, Header} -> Fun(Header);
        error -> {error, malformed_signature}
    end.

with_alg(#{<<"alg">> := AlgBin, <<"kid">> := Kid} = _Header, Opts, Fun) when
    is_binary(AlgBin), is_binary(Kid)
->
    Allowed = maps:get(allowed_algs, Opts, ?ALGS),
    case alg_from_binary(AlgBin) of
        {ok, Alg} ->
            case lists:member(Alg, Allowed) of
                true -> Fun(Alg, Kid);
                false -> {error, {unsupported_alg, Alg}}
            end;
        error ->
            {error, {unsupported_alg, AlgBin}}
    end;
with_alg(_, _, _) ->
    {error, malformed_signature}.

check_and_verify(Jwk, Alg, Kid, ProtectedB64, SigB64, Payload, Opts) ->
    Now = maps:get(now, Opts, erlang:system_time(second)),
    case key_expired(Jwk, Now) of
        true ->
            {error, {key_expired, Kid}};
        false ->
            case {public_key_from_jwk(Jwk, Alg), b64url_decode(SigB64)} of
                {{ok, PubKey}, {ok, RawSig}} ->
                    Input = signing_input(ProtectedB64, Payload),
                    case verify_raw(Input, RawSig, PubKey, Alg) of
                        true -> ok;
                        false -> {error, {invalid_signature, Kid}}
                    end;
                {{error, _}, _} ->
                    {error, {invalid_signature, Kid}};
                {_, error} ->
                    {error, malformed_signature}
            end
    end.

verify_raw(Input, RawSig, {#'ECPoint'{}, _} = Key, 'ES256') ->
    case raw_to_der_sig(RawSig) of
        {ok, Der} -> public_key:verify(Input, sha256, Der, Key);
        error -> false
    end;
verify_raw(Input, Sig, #'RSAPublicKey'{} = Key, 'RS256') ->
    public_key:verify(Input, sha256, Sig, Key);
verify_raw(Input, Sig, #'RSAPublicKey'{} = Key, 'PS256') ->
    public_key:verify(Input, sha256, Sig, Key, ?PSS_OPTS);
verify_raw(_, _, _, _) ->
    false.

%% JWS ECDSA signatures are the raw R || S pair (RFC 7518 3.4);
%% public_key:verify wants a DER ECDSA-Sig-Value.
raw_to_der_sig(<<R:256, S:256>>) ->
    {ok, public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{r = R, s = S})};
raw_to_der_sig(_) ->
    error.

decode_header(ProtectedB64) ->
    case b64url_decode(ProtectedB64) of
        {ok, Json} ->
            case barrel_a2a_json:decode(Json) of
                {ok, Header} when is_map(Header) -> {ok, Header};
                _ -> error
            end;
        error ->
            error
    end.

alg_from_binary(<<"ES256">>) -> {ok, 'ES256'};
alg_from_binary(<<"RS256">>) -> {ok, 'RS256'};
alg_from_binary(<<"PS256">>) -> {ok, 'PS256'};
alg_from_binary(_) -> error.

key_expired(#{<<"exp">> := Exp}, Now) when is_integer(Exp) -> Exp =< Now;
key_expired(#{<<"exp">> := Exp}, Now) when is_float(Exp) -> Exp =< Now;
key_expired(_, _) -> false.

%% Key lookup: local set first, then the header's jku via the fetcher.
find_key(Kid, Header, Opts) ->
    case lookup_kid(Kid, maps:get(keys, Opts, [])) of
        {ok, Jwk} ->
            {ok, Jwk};
        error ->
            case {Header, Opts} of
                {#{<<"jku">> := Jku}, #{jwks_fetch := Fetch}} when
                    is_binary(Jku), is_function(Fetch, 1)
                ->
                    fetch_key(Kid, Jku, Fetch);
                _ ->
                    {error, {unknown_key, Kid}}
            end
    end.

fetch_key(Kid, <<"https://", _/binary>> = Jku, Fetch) ->
    case Fetch(Jku) of
        {ok, Keys} when is_list(Keys) ->
            case lookup_kid(Kid, Keys) of
                {ok, Jwk} -> {ok, Jwk};
                error -> {error, {unknown_key, Kid}}
            end;
        {ok, #{<<"keys">> := Keys}} when is_list(Keys) ->
            fetch_key(Kid, Jku, fun(_) -> {ok, Keys} end);
        _ ->
            {error, {unknown_key, Kid}}
    end;
fetch_key(Kid, _Jku, _Fetch) ->
    {error, {unknown_key, Kid}}.

lookup_kid(Kid, Keys) when is_map(Keys) ->
    case Keys of
        #{Kid := Jwk} when is_map(Jwk) -> {ok, Jwk};
        _ -> error
    end;
lookup_kid(Kid, Keys) when is_list(Keys) ->
    case [K || #{<<"kid">> := Id} = K <- Keys, Id =:= Kid] of
        [Jwk | _] -> {ok, Jwk};
        [] -> error
    end;
lookup_kid(_, _) ->
    error.

public_key_from_jwk(
    #{<<"kty">> := <<"EC">>, <<"crv">> := <<"P-256">>, <<"x">> := X64, <<"y">> := Y64}, 'ES256'
) ->
    case {b64url_decode(X64), b64url_decode(Y64)} of
        {{ok, X}, {ok, Y}} when byte_size(X) =:= 32, byte_size(Y) =:= 32 ->
            {ok, {#'ECPoint'{point = <<4, X/binary, Y/binary>>}, {namedCurve, ?'secp256r1'}}};
        _ ->
            {error, bad_jwk}
    end;
public_key_from_jwk(#{<<"kty">> := <<"RSA">>, <<"n">> := N64, <<"e">> := E64}, Alg) when
    Alg =:= 'RS256'; Alg =:= 'PS256'
->
    case {b64url_decode(N64), b64url_decode(E64)} of
        {{ok, N}, {ok, E}} ->
            {ok, #'RSAPublicKey'{
                modulus = binary:decode_unsigned(N),
                publicExponent = binary:decode_unsigned(E)
            }};
        _ ->
            {error, bad_jwk}
    end;
public_key_from_jwk(_, _) ->
    {error, bad_jwk}.

%%--------------------------------------------------------------------
%% Keys
%%--------------------------------------------------------------------

%% @doc A fresh private key for `Alg': P-256 for ES256, RSA 2048 for
%% RS256 and PS256.
-spec generate_key(alg()) -> public_key:private_key().
generate_key('ES256') ->
    public_key:generate_key({namedCurve, secp256r1});
generate_key(Alg) when Alg =:= 'RS256'; Alg =:= 'PS256' ->
    public_key:generate_key({rsa, 2048, 65537}).

%% @doc The public JWK of a private key, with `kid' set to its
%% RFC 7638 thumbprint.
-spec jwk(key()) -> jwk().
jwk(Key) ->
    Jwk = public_jwk(private_key(Key)),
    Jwk#{<<"kid">> => thumbprint(Jwk)}.

%% @doc The public JWK of a private key with an explicit `kid'.
-spec jwk(key(), binary()) -> jwk().
jwk(Key, Kid) when is_binary(Kid) ->
    Jwk = public_jwk(private_key(Key)),
    Jwk#{<<"kid">> => Kid}.

public_jwk(#'ECPrivateKey'{publicKey = <<4, X:32/binary, Y:32/binary>>}) ->
    #{
        <<"kty">> => <<"EC">>,
        <<"crv">> => <<"P-256">>,
        <<"x">> => b64url(X),
        <<"y">> => b64url(Y)
    };
public_jwk(#'RSAPrivateKey'{modulus = N, publicExponent = E}) ->
    #{
        <<"kty">> => <<"RSA">>,
        <<"n">> => b64url(binary:encode_unsigned(N)),
        <<"e">> => b64url(binary:encode_unsigned(E))
    }.

%% RFC 7638: SHA-256 over the required members in lexical order,
%% serialised without whitespace.
thumbprint(#{<<"kty">> := <<"EC">>, <<"crv">> := Crv, <<"x">> := X, <<"y">> := Y}) ->
    Canonical =
        <<"{\"crv\":\"", Crv/binary, "\",\"kty\":\"EC\",\"x\":\"", X/binary, "\",\"y\":\"",
            Y/binary, "\"}">>,
    b64url(crypto:hash(sha256, Canonical));
thumbprint(#{<<"kty">> := <<"RSA">>, <<"n">> := N, <<"e">> := E}) ->
    Canonical = <<"{\"e\":\"", E/binary, "\",\"kty\":\"RSA\",\"n\":\"", N/binary, "\"}">>,
    b64url(crypto:hash(sha256, Canonical)).

%% @doc The private key in a PEM: `EC PRIVATE KEY', `RSA PRIVATE KEY'
%% or PKCS#8 `PRIVATE KEY'.
-spec decode_pem(binary()) -> public_key:private_key().
decode_pem(Pem) when is_binary(Pem) ->
    case public_key:pem_decode(Pem) of
        [] ->
            error(no_pem_entry);
        [Entry | _] ->
            case public_key:pem_entry_decode(Entry) of
                #'PrivateKeyInfo'{} = Info -> unwrap_pkcs8(Info);
                #'ECPrivateKey'{} = Key -> Key;
                #'RSAPrivateKey'{} = Key -> Key;
                Other -> error({unsupported_pem_entry, element(1, Other)})
            end
    end.

%% Older releases hand back the PKCS#8 wrapper rather than the key.
unwrap_pkcs8(#'PrivateKeyInfo'{privateKeyAlgorithm = Algorithm, privateKey = Der}) ->
    #'PrivateKeyInfo_privateKeyAlgorithm'{algorithm = Oid, parameters = Params} = Algorithm,
    case Oid of
        ?'id-ecPublicKey' ->
            Key = public_key:der_decode('ECPrivateKey', iolist_to_binary(Der)),
            Curve =
                case Params of
                    {asn1_OPENTYPE, Bin} -> public_key:der_decode('EcpkParameters', Bin);
                    Other -> Other
                end,
            Key#'ECPrivateKey'{parameters = Curve};
        ?'rsaEncryption' ->
            public_key:der_decode('RSAPrivateKey', iolist_to_binary(Der))
    end.

%%--------------------------------------------------------------------
%% base64url
%%--------------------------------------------------------------------

b64url(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).

b64url_decode(Bin) when is_binary(Bin) ->
    try
        {ok, base64:decode(Bin, #{mode => urlsafe, padding => false})}
    catch
        _:_ -> error
    end;
b64url_decode(_) ->
    error.
