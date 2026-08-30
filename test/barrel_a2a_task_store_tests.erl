-module(barrel_a2a_task_store_tests).

-include_lib("eunit/include/eunit.hrl").

dets_file() ->
    filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "barrel_a2a_store_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"
    ).

entry(Id, State) ->
    Task0 = barrel_a2a_task:new(Id, <<"ctx">>),
    Task = barrel_a2a_task:set_status(Task0, State, undefined),
    #{id => Id, pid => self(), task => Task, owner => alice, state => State}.

dets_round_trip_test() ->
    File = dets_file(),
    {ok, Store} = barrel_a2a_task_registry:new({barrel_a2a_task_store_dets, #{file => File}}),
    ok = barrel_a2a_task_registry:insert(Store, entry(<<"t1">>, completed)),
    ok = barrel_a2a_task_registry:insert(Store, entry(<<"t2">>, working)),
    {ok, #{task := T1}} = barrel_a2a_task_registry:lookup(Store, <<"t1">>),
    ?assertEqual(completed, barrel_a2a_task:state(T1)),
    {ok, Entries, <<>>, 2} = barrel_a2a_task_registry:list(Store, #{owner => alice}),
    ?assertEqual(2, length(Entries)),
    ok = barrel_a2a_task_registry:close(Store),
    %% Reopen: the completed task is intact, the running one is failed.
    {ok, Store2} = barrel_a2a_task_registry:new({barrel_a2a_task_store_dets, #{file => File}}),
    {ok, #{task := T1b, pid := undefined}} = barrel_a2a_task_registry:lookup(Store2, <<"t1">>),
    ?assertEqual(completed, barrel_a2a_task:state(T1b)),
    {ok, #{task := T2b, pid := undefined, owner := alice}} = barrel_a2a_task_registry:lookup(
        Store2, <<"t2">>
    ),
    ?assertEqual(failed, barrel_a2a_task:state(T2b)),
    ?assertEqual(
        <<"Task interrupted by a server restart">>,
        barrel_a2a_message:text(barrel_a2a_task:status_message(T2b))
    ),
    ok = barrel_a2a_task_registry:delete(Store2, <<"t1">>),
    ?assertEqual(error, barrel_a2a_task_registry:lookup(Store2, <<"t1">>)),
    ok = barrel_a2a_task_registry:close(Store2),
    file:delete(File).

dets_missing_file_option_test() ->
    ?assertMatch({error, {missing_option, file}}, barrel_a2a_task_store_dets:open(#{})).

server_survives_restart_test() ->
    File = dets_file(),
    Opts = #{
        handler => fun(_Ctx, M) -> {ok, barrel_a2a_message:text(M)} end,
        http => #{port => 0},
        task_store => {barrel_a2a_task_store_dets, #{file => File}}
    },
    Card = barrel_a2a_agent_card:new(#{name => <<"P">>}),
    {ok, S1} = barrel_a2a_server:start(Card, Opts),
    {ok, A1} = barrel_a2a_client:connect(barrel_a2a_server:url(S1)),
    {ok, {task, T}} = barrel_a2a_client:send(A1, <<"hello">>),
    Id = barrel_a2a_task:id(T),
    ok = barrel_a2a_server:stop(S1),
    {ok, S2} = barrel_a2a_server:start(Card, Opts),
    {ok, A2} = barrel_a2a_client:connect(barrel_a2a_server:url(S2)),
    {ok, Again} = barrel_a2a_client:get_task(A2, Id),
    ?assertEqual(completed, barrel_a2a_task:state(Again)),
    ?assertEqual(<<"hello">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Again)))),
    ok = barrel_a2a_server:stop(S2),
    file:delete(File).
