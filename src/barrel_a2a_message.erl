%%%-------------------------------------------------------------------
%%% @doc `Message' objects (specification 4.1.4).
%%%
%%% A message is one unit of communication: `messageId', `role',
%%% non-empty `parts', and optionally `contextId', `taskId',
%%% `metadata', `extensions' and `referenceTaskIds'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_message).

-export([new/1, new/2, agent/1, agent/2]).
-export([
    id/1,
    role/1,
    parts/1,
    text/1,
    context_id/1,
    task_id/1,
    metadata/1,
    extensions/1,
    reference_task_ids/1
]).
-export([with_context/2, with_task/2, with_metadata/2, with_extensions/2, with_id/2]).
-export([role_to_wire/1, role_from_wire/1]).

-type message() :: barrel_a2a:message().
-type content() :: iodata() | barrel_a2a:part() | [barrel_a2a:part()].
-type opts() :: #{
    role => barrel_a2a:role(),
    message_id => binary(),
    context_id => binary(),
    task_id => binary(),
    metadata => map(),
    extensions => [binary()],
    reference_task_ids => [binary()]
}.

-export_type([message/0, content/0, opts/0]).

%% @doc A user message from text, one part or a list of parts.
-spec new(content()) -> message().
new(Content) -> new(Content, #{}).

-spec new(content(), opts()) -> message().
new(Content, Opts) ->
    Role = maps:get(role, Opts, user),
    Base = #{
        <<"messageId">> => maps:get(message_id, Opts, barrel_a2a_id:uuid()),
        <<"role">> => role_to_wire(Role),
        <<"parts">> => to_parts(Content)
    },
    maps:fold(
        fun
            (context_id, V, Acc) -> Acc#{<<"contextId">> => V};
            (task_id, V, Acc) -> Acc#{<<"taskId">> => V};
            (metadata, V, Acc) -> Acc#{<<"metadata">> => V};
            (extensions, V, Acc) -> Acc#{<<"extensions">> => V};
            (reference_task_ids, V, Acc) -> Acc#{<<"referenceTaskIds">> => V};
            (_, _, Acc) -> Acc
        end,
        Base,
        Opts
    ).

%% @doc An agent message (role `ROLE_AGENT').
-spec agent(content()) -> message().
agent(Content) -> agent(Content, #{}).

-spec agent(content(), opts()) -> message().
agent(Content, Opts) -> new(Content, Opts#{role => agent}).

to_parts(Parts) when is_list(Parts), Parts =/= [] ->
    case lists:all(fun barrel_a2a_part:is_part/1, Parts) of
        true -> Parts;
        false -> [barrel_a2a_part:text(Parts)]
    end;
to_parts(Part) when is_map(Part) ->
    [Part];
to_parts(Text) ->
    [barrel_a2a_part:text(Text)].

-spec id(message()) -> binary() | undefined.
id(#{<<"messageId">> := Id}) when is_binary(Id) -> Id;
id(_) -> undefined.

-spec role(message()) -> barrel_a2a:role().
role(#{<<"role">> := R}) ->
    case role_from_wire(R) of
        {ok, Role} -> Role;
        error -> unspecified
    end;
role(_) ->
    unspecified.

-spec parts(message()) -> [barrel_a2a:part()].
parts(#{<<"parts">> := Parts}) when is_list(Parts) -> Parts;
parts(_) -> [].

%% @doc All text parts joined with newlines; `<<>>' when none.
-spec text(message()) -> binary().
text(Message) ->
    Texts = [T || P <- parts(Message), T <- [barrel_a2a_part:text_of(P)], T =/= undefined],
    iolist_to_binary(lists:join(<<"\n">>, Texts)).

-spec context_id(message()) -> binary() | undefined.
context_id(#{<<"contextId">> := C}) when is_binary(C), C =/= <<>> -> C;
context_id(_) -> undefined.

-spec task_id(message()) -> binary() | undefined.
task_id(#{<<"taskId">> := T}) when is_binary(T), T =/= <<>> -> T;
task_id(_) -> undefined.

-spec metadata(message()) -> map().
metadata(#{<<"metadata">> := M}) when is_map(M) -> M;
metadata(_) -> #{}.

-spec extensions(message()) -> [binary()].
extensions(#{<<"extensions">> := E}) when is_list(E) -> [X || X <- E, is_binary(X)];
extensions(_) -> [].

-spec reference_task_ids(message()) -> [binary()].
reference_task_ids(#{<<"referenceTaskIds">> := R}) when is_list(R) -> [X || X <- R, is_binary(X)];
reference_task_ids(_) -> [].

-spec with_context(binary(), message()) -> message().
with_context(ContextId, M) -> M#{<<"contextId">> => ContextId}.

-spec with_task(binary(), message()) -> message().
with_task(TaskId, M) -> M#{<<"taskId">> => TaskId}.

-spec with_metadata(map(), message()) -> message().
with_metadata(Metadata, M) -> M#{<<"metadata">> => Metadata}.

-spec with_extensions([binary()], message()) -> message().
with_extensions(Ext, M) -> M#{<<"extensions">> => Ext}.

-spec with_id(binary(), message()) -> message().
with_id(Id, M) -> M#{<<"messageId">> => Id}.

-spec role_to_wire(barrel_a2a:role()) -> binary().
role_to_wire(user) -> <<"ROLE_USER">>;
role_to_wire(agent) -> <<"ROLE_AGENT">>;
role_to_wire(unspecified) -> <<"ROLE_UNSPECIFIED">>.

-spec role_from_wire(term()) -> {ok, barrel_a2a:role()} | error.
role_from_wire(<<"ROLE_USER">>) -> {ok, user};
role_from_wire(<<"ROLE_AGENT">>) -> {ok, agent};
role_from_wire(<<"ROLE_UNSPECIFIED">>) -> {ok, unspecified};
role_from_wire(1) -> {ok, user};
role_from_wire(2) -> {ok, agent};
role_from_wire(0) -> {ok, unspecified};
role_from_wire(user) -> {ok, user};
role_from_wire(agent) -> {ok, agent};
role_from_wire(_) -> error.
