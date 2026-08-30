%%%-------------------------------------------------------------------
%%% @doc `Part' objects (specification 4.1.6).
%%%
%%% A part carries exactly one of `text', `raw' (base64 bytes), `url'
%%% or `data' (any JSON value), plus optional `mediaType', `filename'
%%% and `metadata'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_part).

-export([text/1, text/2, data/1, data/2, file_url/2, file_url/3, file_bytes/2, file_bytes/3]).
-export([kind/1, text_of/1, data_of/1, url_of/1, bytes_of/1, media_type/1, filename/1, metadata/1]).
-export([is_part/1]).

-type part() :: barrel_a2a:part().
-type kind() :: text | raw | url | data | unknown.

-export_type([part/0, kind/0]).

-spec text(iodata()) -> part().
text(Text) -> #{<<"text">> => iolist_to_binary(Text)}.

%% @doc Text with a media type (default `text/plain' is implied when
%% absent) or metadata: `#{media_type => _, metadata => _}'.
-spec text(iodata(), map()) -> part().
text(Text, Opts) -> with_opts(text(Text), Opts).

-spec data(barrel_a2a:json()) -> part().
data(Value) -> #{<<"data">> => Value}.

-spec data(barrel_a2a:json(), map()) -> part().
data(Value, Opts) -> with_opts(data(Value), Opts).

-spec file_url(binary(), binary()) -> part().
file_url(Url, MediaType) -> file_url(Url, MediaType, #{}).

-spec file_url(binary(), binary(), map()) -> part().
file_url(Url, MediaType, Opts) ->
    with_opts(#{<<"url">> => Url, <<"mediaType">> => MediaType}, Opts).

-spec file_bytes(binary(), binary()) -> part().
file_bytes(Bytes, MediaType) -> file_bytes(Bytes, MediaType, #{}).

%% @doc Raw bytes; encoded as base64 on the wire.
-spec file_bytes(binary(), binary(), map()) -> part().
file_bytes(Bytes, MediaType, Opts) ->
    with_opts(#{<<"raw">> => base64:encode(Bytes), <<"mediaType">> => MediaType}, Opts).

with_opts(Part, Opts) ->
    maps:fold(
        fun
            (media_type, V, Acc) -> Acc#{<<"mediaType">> => V};
            (filename, V, Acc) -> Acc#{<<"filename">> => V};
            (metadata, V, Acc) -> Acc#{<<"metadata">> => V};
            (_, _, Acc) -> Acc
        end,
        Part,
        Opts
    ).

-spec kind(part()) -> kind().
kind(#{<<"text">> := _}) -> text;
kind(#{<<"raw">> := _}) -> raw;
kind(#{<<"url">> := _}) -> url;
kind(#{<<"data">> := _}) -> data;
kind(_) -> unknown.

-spec text_of(part()) -> binary() | undefined.
text_of(#{<<"text">> := T}) when is_binary(T) -> T;
text_of(_) -> undefined.

-spec data_of(part()) -> barrel_a2a:json() | undefined.
data_of(#{<<"data">> := D}) -> D;
data_of(_) -> undefined.

-spec url_of(part()) -> binary() | undefined.
url_of(#{<<"url">> := U}) when is_binary(U) -> U;
url_of(_) -> undefined.

%% @doc Decoded bytes of a `raw' part.
-spec bytes_of(part()) -> binary() | undefined.
bytes_of(#{<<"raw">> := R}) when is_binary(R) ->
    try
        base64:decode(R)
    catch
        _:_ -> undefined
    end;
bytes_of(_) ->
    undefined.

-spec media_type(part()) -> binary() | undefined.
media_type(#{<<"mediaType">> := M}) when is_binary(M) -> M;
media_type(#{<<"text">> := _}) -> <<"text/plain">>;
media_type(#{<<"data">> := _}) -> <<"application/json">>;
media_type(_) -> undefined.

-spec filename(part()) -> binary() | undefined.
filename(#{<<"filename">> := F}) when is_binary(F) -> F;
filename(_) -> undefined.

-spec metadata(part()) -> map().
metadata(#{<<"metadata">> := M}) when is_map(M) -> M;
metadata(_) -> #{}.

-spec is_part(term()) -> boolean().
is_part(P) when is_map(P) -> kind(P) =/= unknown;
is_part(_) -> false.
