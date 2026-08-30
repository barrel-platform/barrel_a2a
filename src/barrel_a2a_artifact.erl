%%%-------------------------------------------------------------------
%%% @doc `Artifact' objects (specification 4.1.7).
%%%
%%% Artifacts are the outputs of a task: `artifactId', non-empty
%%% `parts', optional `name', `description', `metadata', `extensions'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_artifact).

-export([new/1, new/2, id/1, name/1, description/1, parts/1, text/1, metadata/1, extensions/1]).
-export([append_parts/2]).

-type artifact() :: barrel_a2a:artifact().
-type opts() :: #{
    artifact_id => binary(),
    name => binary(),
    description => binary(),
    metadata => map(),
    extensions => [binary()]
}.

-export_type([artifact/0, opts/0]).

-spec new(barrel_a2a_message:content()) -> artifact().
new(Content) -> new(Content, #{}).

-spec new(barrel_a2a_message:content(), opts()) -> artifact().
new(Content, Opts) ->
    Base = #{
        <<"artifactId">> => maps:get(artifact_id, Opts, barrel_a2a_id:uuid()),
        <<"parts">> => to_parts(Content)
    },
    maps:fold(
        fun
            (name, V, Acc) -> Acc#{<<"name">> => V};
            (description, V, Acc) -> Acc#{<<"description">> => V};
            (metadata, V, Acc) -> Acc#{<<"metadata">> => V};
            (extensions, V, Acc) -> Acc#{<<"extensions">> => V};
            (_, _, Acc) -> Acc
        end,
        Base,
        Opts
    ).

to_parts(Parts) when is_list(Parts), Parts =/= [] ->
    case lists:all(fun barrel_a2a_part:is_part/1, Parts) of
        true -> Parts;
        false -> [barrel_a2a_part:text(Parts)]
    end;
to_parts(Part) when is_map(Part) ->
    [Part];
to_parts(Text) ->
    [barrel_a2a_part:text(Text)].

-spec id(artifact()) -> binary() | undefined.
id(#{<<"artifactId">> := Id}) when is_binary(Id) -> Id;
id(_) -> undefined.

-spec name(artifact()) -> binary() | undefined.
name(#{<<"name">> := N}) when is_binary(N) -> N;
name(_) -> undefined.

-spec description(artifact()) -> binary() | undefined.
description(#{<<"description">> := D}) when is_binary(D) -> D;
description(_) -> undefined.

-spec parts(artifact()) -> [barrel_a2a:part()].
parts(#{<<"parts">> := P}) when is_list(P) -> P;
parts(_) -> [].

-spec text(artifact()) -> binary().
text(Artifact) ->
    Texts = [T || P <- parts(Artifact), T <- [barrel_a2a_part:text_of(P)], T =/= undefined],
    iolist_to_binary(Texts).

-spec metadata(artifact()) -> map().
metadata(#{<<"metadata">> := M}) when is_map(M) -> M;
metadata(_) -> #{}.

-spec extensions(artifact()) -> [binary()].
extensions(#{<<"extensions">> := E}) when is_list(E) -> E;
extensions(_) -> [].

%% @doc Merge a chunk into an existing artifact (`append = true' in a
%% `TaskArtifactUpdateEvent'): parts are concatenated, other fields of
%% the chunk override when present.
-spec append_parts(artifact(), artifact()) -> artifact().
append_parts(Existing, Chunk) ->
    Merged = maps:merge(Existing, maps:without([<<"parts">>], Chunk)),
    Merged#{<<"parts">> => parts(Existing) ++ parts(Chunk)}.
