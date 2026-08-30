%%%-------------------------------------------------------------------
%%% @doc The spec's own wire-shape vectors, checked with our validator.
%%%
%%% `a2a.json' is the protocol's JSON Schema bundle and
%%% `examples/<Type>/' holds instances of each `$defs' entry: the
%%% specification's JSON examples as `NN.json', and instances written
%%% from the proto definition as `hand_NN.json' where the specification
%%% has none.
%%%
%%% What is proved: the bundle we ship is the vendored one, every
%%% vector is accepted, and every wire type has at least one vector.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_schema_vectors_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([every_vector_validates/1, priv_schema_matches_vendored/1]).
-export([all_defs_have_a_vector/1, unknown_type_is_refused/1, our_responses_validate/1]).

-define(VERSION, "1.0.1").

all() ->
    [
        every_vector_validates,
        priv_schema_matches_vendored,
        all_defs_have_a_vector,
        unknown_type_is_refused,
        our_responses_validate
    ].

init_per_suite(Config) ->
    ok = barrel_a2a_schema:load(),
    Config.

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Cases
%%====================================================================

%% Each example directory is named for the `$defs' entry it instantiates.
every_vector_validates(_Config) ->
    Dirs = filelib:wildcard(filename:join([vectors_dir(), "examples", "*"])),
    ?assert(length(Dirs) >= 12),
    All = lists:append([validate_dir(Dir) || Dir <- Dirs]),
    ?assert(length(All) >= 25),
    Failures = [F || {_, _, {error, _}} = F <- All],
    {Skipped, Unexpected} = lists:partition(fun is_skipped/1, Failures),
    ct:pal("~B vectors, ~B skipped, ~B failures", [
        length(All), length(Skipped), length(Unexpected)
    ]),
    %% A skip that stops failing is stale: the list is what the spec
    %% and the schema disagree on, not a place for old entries.
    Stale = [S || S <- skips(), not lists:any(fun(F) -> matches_skip(F, S) end, Failures)],
    case {Unexpected, Stale} of
        {[], []} ->
            ok;
        {[], _} ->
            ct:fail({stale_skips, Stale});
        _ ->
            ct:pal("~B failures:~n~s", [length(Unexpected), format(Unexpected)]),
            ct:fail({vectors_rejected, length(Unexpected)})
    end.

%% Specification examples the bundle does not accept, and why. Kept as
%% vectors so the disagreement stays visible.
skips() ->
    [
        {<<"AgentCard">>, "03.json",
            "8.5 sample card uses `security' with `{name: [scopes]}'; "
            "the bundle names it `securityRequirements' with "
            "`{schemes: {name: {list: [scopes]}}}'"}
    ].

is_skipped({Type, File, _}) ->
    lists:any(fun({T, F, _}) -> T =:= Type andalso F =:= File end, skips()).

matches_skip({Type, File, _}, {T, F, _}) ->
    Type =:= T andalso File =:= F.

validate_dir(Dir) ->
    Type = list_to_binary(filename:basename(Dir)),
    [
        {Type, filename:basename(File), barrel_a2a_schema:validate(Type, decode(File))}
     || File <- filelib:wildcard(filename:join(Dir, "*.json"))
    ].

%% What the runtime validates against is the vendored bundle, byte for
%% byte, so a change to either is a deliberate change to both.
priv_schema_matches_vendored(_Config) ->
    Priv = filename:join([code:priv_dir(barrel_a2a), "schema", "a2a.json"]),
    Vendored = filename:join(vectors_dir(), "a2a.json"),
    ?assertEqual(sha256(Vendored), sha256(Priv)),
    ?assertEqual(<<"v1">>, barrel_a2a_schema:version()),
    ?assertEqual(
        <<"https://json-schema.org/draft/2020-12/schema">>,
        maps:get(<<"$schema">>, barrel_a2a_schema:schema())
    ).

%% Every wire object has at least one vector, so a type nobody
%% exercised cannot hide a schema we never ran.
all_defs_have_a_vector(_Config) ->
    Types = barrel_a2a_schema:types(),
    ?assertEqual(47, length(Types)),
    Present = [
        list_to_binary(filename:basename(D))
     || D <- filelib:wildcard(filename:join([vectors_dir(), "examples", "*"])),
        filelib:wildcard(filename:join(D, "*.json")) =/= []
    ],
    Missing = [T || T <- Types, not lists:member(T, Present), not lists:member(T, helpers())],
    ?assertEqual([], Missing),
    %% And no directory names a type the bundle does not have.
    ?assertEqual([], [P || P <- Present, not lists:member(P, Types)]).

%% Types never sent on their own: protobuf well-known types, the
%% wrapper the schema generator makes for a `map<string, repeated>',
%% and the OAuth flow objects that only appear inside an
%% `OAuth2SecurityScheme'.
helpers() ->
    [
        <<"Struct">>,
        <<"Value">>,
        <<"Timestamp">>,
        <<"StringList">>,
        <<"SecurityRequirement">>,
        <<"OAuthFlows">>,
        <<"AuthorizationCodeOAuthFlow">>,
        <<"ClientCredentialsOAuthFlow">>,
        <<"DeviceCodeOAuthFlow">>,
        <<"ImplicitOAuthFlow">>,
        <<"PasswordOAuthFlow">>
    ].

unknown_type_is_refused(_Config) ->
    ?assertEqual(
        {error, [{[], {unknown_type, <<"Nope">>}}]},
        barrel_a2a_schema:validate(<<"Nope">>, #{})
    ),
    ?assertNot(lists:member(<<"Nope">>, barrel_a2a_schema:types())).

%% Everything the server emits validates against the bundle: replies of
%% every unary operation, every streamed event, and the published card.
our_responses_validate(_Config) ->
    {ok, _} = application:ensure_all_started(barrel_a2a),
    {ok, Server} = barrel_a2a_server:start(barrel_a2a_test_agent:card(), #{
        handler => barrel_a2a_test_agent,
        listen => false,
        push_notifications => #{ssrf_guard => false},
        extended_card => barrel_a2a_test_agent:card(#{name => <<"Extended">>})
    }),
    try
        Ctx = #{
            binding => grpc,
            headers => [],
            version => <<"1.0">>,
            extensions => [],
            principal => <<"vectors">>
        },
        Call = fun(Op, Req) ->
            {ok, Reply} = barrel_a2a_server_core:call(Server, Op, Req, Ctx),
            Reply
        end,
        Send = fun(Text, Conf) ->
            Call(send_message, #{
                <<"message">> => barrel_a2a_message:new(Text), <<"configuration">> => Conf
            })
        end,
        Done = Send(<<"stream">>, #{}),
        #{<<"task">> := DoneTask} = Done,
        Paused = Send(<<"ask">>, #{<<"returnImmediately">> => true}),
        #{<<"task">> := PausedTask} = Paused,
        PausedId = barrel_a2a_task:id(PausedTask),
        Direct = Send(<<"direct">>, #{}),
        {stream, Subscribe} = barrel_a2a_server_core:call(
            Server,
            send_streaming_message,
            #{<<"message">> => barrel_a2a_message:new(<<"stream">>)},
            Ctx
        ),
        {ok, Initial} = Subscribe(self()),
        Events = Initial ++ collect_events(),
        PushCfg = Call(create_push_config, #{
            <<"taskId">> => PausedId, <<"url">> => <<"http://127.0.0.1:9/hook">>
        }),
        Cases =
            [
                {<<"SendMessageResponse">>, Done},
                {<<"SendMessageResponse">>, Paused},
                {<<"SendMessageResponse">>, Direct},
                {<<"Task">>, DoneTask},
                {<<"Task">>, Call(get_task, #{<<"id">> => barrel_a2a_task:id(DoneTask)})},
                {<<"ListTasksResponse">>, Call(list_tasks, #{<<"includeArtifacts">> => true})},
                {<<"ListTasksResponse">>, Call(list_tasks, #{<<"pageSize">> => 1})},
                {<<"TaskPushNotificationConfig">>, PushCfg},
                {<<"TaskPushNotificationConfig">>,
                    Call(get_push_config, #{
                        <<"taskId">> => PausedId, <<"id">> => maps:get(<<"id">>, PushCfg)
                    })},
                {<<"ListTaskPushNotificationConfigsResponse">>,
                    Call(list_push_configs, #{<<"taskId">> => PausedId})},
                {<<"Task">>, Call(cancel_task, #{<<"id">> => PausedId})},
                {<<"AgentCard">>, barrel_a2a_server:card(Server)},
                {<<"AgentCard">>, Call(get_extended_agent_card, #{})}
            ] ++ [{<<"StreamResponse">>, E} || E <- Events],
        ?assert(length(Events) >= 4),
        Failures = lists:filtermap(
            fun({Type, Value}) ->
                case barrel_a2a_schema:validate(Type, Value) of
                    ok -> false;
                    {error, Errors} -> {true, {Type, Errors, Value}}
                end
            end,
            Cases
        ),
        ?assertEqual([], Failures)
    after
        barrel_a2a_server:stop(Server)
    end.

collect_events() ->
    receive
        {a2a_task_event, _, Ev} ->
            case barrel_a2a_event:is_final(Ev) of
                true -> [Ev];
                false -> [Ev | collect_events()]
            end
    after 5000 -> []
    end.

%%====================================================================
%% Helpers
%%====================================================================

decode(File) ->
    {ok, Bin} = file:read_file(File),
    {ok, Json} = barrel_a2a_json:decode(Bin),
    Json.

sha256(Path) ->
    {ok, Bin} = file:read_file(Path),
    binary:encode_hex(crypto:hash(sha256, Bin)).

format(Failures) ->
    [
        io_lib:format("  ~ts / ~ts: ~p~n", [T, F, R])
     || {T, F, R} <- Failures
    ].

vectors_dir() ->
    Under = filename:join([
        code:lib_dir(barrel_a2a), "..", "..", "..", "..", "test", "schema_vectors", ?VERSION
    ]),
    case filelib:is_dir(Under) of
        true -> Under;
        false -> filename:join(["test", "schema_vectors", ?VERSION])
    end.
