-module(barrel_a2a_task_tests).

-include_lib("eunit/include/eunit.hrl").

-define(RECV_MS, 2000).

%%--------------------------------------------------------------------
%% registry helpers
%%--------------------------------------------------------------------

%% A task with an explicit status timestamp so ordering is deterministic.
task_at(Id, Ctx, State, Ms) ->
    T = barrel_a2a_task:new(Id, Ctx),
    barrel_a2a_task:set_status(T, State, undefined, barrel_a2a_time:to_iso(Ms)).

entry(Id, Ctx, State, Ms, Owner) ->
    Task = task_at(Id, Ctx, State, Ms),
    #{id => Id, pid => undefined, task => Task, owner => Owner, state => State}.

%% Five tasks, ids t1..t5, timestamps 1000..5000, alternating owners and
%% contexts.
seed(Tab) ->
    lists:foreach(
        fun(N) ->
            Id = <<"t", (integer_to_binary(N))/binary>>,
            Ctx =
                case N rem 2 of
                    0 -> <<"even">>;
                    1 -> <<"odd">>
                end,
            Owner =
                case N =< 3 of
                    true -> alice;
                    false -> bob
                end,
            State =
                case N of
                    5 -> completed;
                    _ -> working
                end,
            ok = barrel_a2a_task_registry:insert(Tab, entry(Id, Ctx, State, N * 1000, Owner))
        end,
        lists:seq(1, 5)
    ).

ids(Entries) -> [Id || #{id := Id} <- Entries].

%%--------------------------------------------------------------------
%% registry
%%--------------------------------------------------------------------

registry_crud_test_() ->
    [
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            ?assertEqual(error, barrel_a2a_task_registry:lookup(Tab, <<"t1">>)),
            ?assertEqual([], barrel_a2a_task_registry:all(Tab)),
            E = entry(<<"t1">>, <<"c1">>, submitted, 1000, alice),
            ok = barrel_a2a_task_registry:insert(Tab, E),
            {ok, Got} = barrel_a2a_task_registry:lookup(Tab, <<"t1">>),
            ?assertEqual(E, Got),
            ?assertEqual([E], barrel_a2a_task_registry:all(Tab)),
            ok = barrel_a2a_task_registry:delete(Tab, <<"t1">>),
            ?assertEqual(error, barrel_a2a_task_registry:lookup(Tab, <<"t1">>)),
            %% deleting again is fine
            ?assertEqual(ok, barrel_a2a_task_registry:delete(Tab, <<"t1">>))
        end),
        %% update keeps owner and pid unless the entry carries them
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            Task0 = task_at(<<"t1">>, <<"c1">>, submitted, 1000),
            ok = barrel_a2a_task_registry:insert(Tab, #{
                id => <<"t1">>, pid => self(), task => Task0, owner => alice, state => submitted
            }),
            Task1 = barrel_a2a_task:set_status(Task0, working, undefined),
            ok = barrel_a2a_task_registry:update(Tab, #{id => <<"t1">>, task => Task1}),
            {ok, #{pid := Pid, owner := Owner, state := State, task := Task}} =
                barrel_a2a_task_registry:lookup(Tab, <<"t1">>),
            ?assertEqual(self(), Pid),
            ?assertEqual(alice, Owner),
            ?assertEqual(working, State),
            ?assertEqual(Task1, Task),
            ok = barrel_a2a_task_registry:update(Tab, #{
                id => <<"t1">>, task => Task1, pid => undefined, owner => bob
            }),
            ?assertMatch(
                {ok, #{pid := undefined, owner := bob}},
                barrel_a2a_task_registry:lookup(Tab, <<"t1">>)
            )
        end),
        %% update of an unknown id inserts
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            ok = barrel_a2a_task_registry:update(Tab, entry(<<"new">>, <<"c">>, working, 1, alice)),
            ?assertMatch(
                {ok, #{id := <<"new">>, state := working}},
                barrel_a2a_task_registry:lookup(Tab, <<"new">>)
            )
        end),
        %% the state is derived from the task, whatever the entry says
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            E = entry(<<"t1">>, <<"c1">>, completed, 1000, alice),
            ok = barrel_a2a_task_registry:insert(Tab, E#{state => working}),
            ?assertMatch(
                {ok, #{state := completed}}, barrel_a2a_task_registry:lookup(Tab, <<"t1">>)
            )
        end)
    ].

registry_list_test_() ->
    [
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            {ok, [], <<>>, 0} = barrel_a2a_task_registry:list(Tab, #{})
        end),
        %% sorted by status timestamp, newest first
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            {ok, Entries, Next, Total} = barrel_a2a_task_registry:list(Tab, #{}),
            ?assertEqual([<<"t5">>, <<"t4">>, <<"t3">>, <<"t2">>, <<"t1">>], ids(Entries)),
            ?assertEqual(<<>>, Next),
            ?assertEqual(5, Total)
        end),
        %% equal timestamps break ties on id, descending
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            ok = barrel_a2a_task_registry:insert(Tab, entry(<<"a">>, <<"c">>, working, 1000, x)),
            ok = barrel_a2a_task_registry:insert(Tab, entry(<<"b">>, <<"c">>, working, 1000, x)),
            {ok, Entries, _, _} = barrel_a2a_task_registry:list(Tab, #{}),
            ?assertEqual([<<"b">>, <<"a">>], ids(Entries))
        end),
        %% filters
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            {ok, Alice, _, 3} = barrel_a2a_task_registry:list(Tab, #{owner => alice}),
            ?assertEqual([<<"t3">>, <<"t2">>, <<"t1">>], ids(Alice)),
            {ok, Bob, _, 2} = barrel_a2a_task_registry:list(Tab, #{owner => bob}),
            ?assertEqual([<<"t5">>, <<"t4">>], ids(Bob)),
            {ok, [], _, 0} = barrel_a2a_task_registry:list(Tab, #{owner => carol}),
            {ok, Any, _, 5} = barrel_a2a_task_registry:list(Tab, #{owner => any}),
            ?assertEqual(5, length(Any)),
            {ok, Even, _, 2} = barrel_a2a_task_registry:list(Tab, #{context_id => <<"even">>}),
            ?assertEqual([<<"t4">>, <<"t2">>], ids(Even)),
            {ok, [], _, 0} = barrel_a2a_task_registry:list(Tab, #{context_id => <<"none">>}),
            {ok, Done, _, 1} = barrel_a2a_task_registry:list(Tab, #{state => completed}),
            ?assertEqual([<<"t5">>], ids(Done)),
            {ok, Working, _, 4} = barrel_a2a_task_registry:list(Tab, #{state => working}),
            ?assertEqual(4, length(Working)),
            %% after_ms is inclusive, so t3 at 3000 is in
            {ok, After, _, 3} = barrel_a2a_task_registry:list(Tab, #{after_ms => 3000}),
            ?assertEqual([<<"t5">>, <<"t4">>, <<"t3">>], ids(After)),
            {ok, Last, _, 1} = barrel_a2a_task_registry:list(Tab, #{after_ms => 5000}),
            ?assertEqual([<<"t5">>], ids(Last)),
            {ok, [], _, 0} = barrel_a2a_task_registry:list(Tab, #{after_ms => 5001}),
            %% filters combine
            {ok, Combined, _, 2} = barrel_a2a_task_registry:list(Tab, #{
                owner => alice, context_id => <<"odd">>, state => working, after_ms => 1000
            }),
            ?assertEqual([<<"t3">>, <<"t1">>], ids(Combined))
        end),
        %% a `visible' predicate is applied with the other filters, so
        %% the total and the page describe only what the caller may see
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            Odd = fun(#{id := Id}) -> binary:last(Id) rem 2 =:= 1 end,
            {ok, Rows, Next, Total} = barrel_a2a_task_registry:list(Tab, #{
                visible => Odd, page_size => 2
            }),
            ?assertEqual(3, Total),
            ?assertEqual([<<"t5">>, <<"t3">>], ids(Rows)),
            {ok, Rest, <<>>, 3} = barrel_a2a_task_registry:list(Tab, #{
                visible => Odd, page_size => 2, page_token => Next
            }),
            ?assertEqual([<<"t1">>], ids(Rest))
        end),
        %% page_size is clamped to the range the specification gives
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            {ok, Big, _, 5} = barrel_a2a_task_registry:list(Tab, #{page_size => 1000}),
            ?assertEqual(5, length(Big)),
            {ok, One, _, 5} = barrel_a2a_task_registry:list(Tab, #{page_size => 1}),
            ?assertEqual([<<"t5">>], ids(One)),
            %% zero and nonsense fall back to the default
            {ok, Zero, _, 5} = barrel_a2a_task_registry:list(Tab, #{page_size => 0}),
            ?assertEqual(5, length(Zero))
        end),
        %% pagination with cursor round trip
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            {ok, Page1, Next1, 5} = barrel_a2a_task_registry:list(Tab, #{page_size => 2}),
            ?assertEqual([<<"t5">>, <<"t4">>], ids(Page1)),
            ?assertNotEqual(<<>>, Next1),
            %% the cursor is the last row of the page
            ?assertEqual({ok, {4000, <<"t4">>}}, barrel_a2a_id:cursor_decode(Next1)),
            {ok, Page2, Next2, 5} = barrel_a2a_task_registry:list(Tab, #{
                page_size => 2, page_token => Next1
            }),
            ?assertEqual([<<"t3">>, <<"t2">>], ids(Page2)),
            ?assertNotEqual(<<>>, Next2),
            {ok, Page3, Next3, 5} = barrel_a2a_task_registry:list(Tab, #{
                page_size => 2, page_token => Next2
            }),
            ?assertEqual([<<"t1">>], ids(Page3)),
            ?assertEqual(<<>>, Next3),
            %% an exact fit ends with an empty token too
            {ok, Page4, Next4, 5} = barrel_a2a_task_registry:list(Tab, #{page_size => 5}),
            ?assertEqual(5, length(Page4)),
            ?assertEqual(<<>>, Next4),
            %% the total counts every match, not the page
            {ok, [_], _, 3} = barrel_a2a_task_registry:list(Tab, #{page_size => 1, owner => alice})
        end),
        %% a token built by hand from the cursor term works too
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            Token = barrel_a2a_id:cursor_encode({3000, <<"t3">>}),
            {ok, Entries, <<>>, 5} = barrel_a2a_task_registry:list(Tab, #{page_token => Token}),
            ?assertEqual([<<"t2">>, <<"t1">>], ids(Entries))
        end),
        %% empty and undefined tokens start from the top
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            {ok, A, _, _} = barrel_a2a_task_registry:list(Tab, #{page_token => <<>>}),
            {ok, B, _, _} = barrel_a2a_task_registry:list(Tab, #{page_token => undefined}),
            ?assertEqual(ids(A), ids(B)),
            ?assertEqual(5, length(A))
        end),
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            seed(Tab),
            ?assertEqual(
                {error, invalid_page_token},
                barrel_a2a_task_registry:list(Tab, #{page_token => <<"garbage!">>})
            ),
            ?assertEqual(
                {error, invalid_page_token},
                barrel_a2a_task_registry:list(Tab, #{
                    page_token => barrel_a2a_id:cursor_encode(not_a_cursor)
                })
            ),
            ?assertEqual(
                {error, invalid_page_token},
                barrel_a2a_task_registry:list(Tab, #{
                    page_token => barrel_a2a_id:cursor_encode({<<"x">>, 1})
                })
            )
        end),
        %% page size defaults and caps
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            lists:foreach(
                fun(N) ->
                    Id = integer_to_binary(N),
                    ok = barrel_a2a_task_registry:insert(Tab, entry(Id, <<"c">>, working, N, x))
                end,
                lists:seq(1, 60)
            ),
            {ok, Default, NextD, 60} = barrel_a2a_task_registry:list(Tab, #{}),
            ?assertEqual(50, length(Default)),
            ?assertNotEqual(<<>>, NextD),
            {ok, Bad, _, 60} = barrel_a2a_task_registry:list(Tab, #{page_size => 0}),
            ?assertEqual(50, length(Bad)),
            {ok, Huge, <<>>, 60} = barrel_a2a_task_registry:list(Tab, #{page_size => 100000}),
            ?assertEqual(60, length(Huge))
        end)
    ].

registry_expire_test_() ->
    [
        ?_test(begin
            Tab = barrel_a2a_task_registry:new(),
            ok = barrel_a2a_task_registry:insert(Tab, entry(<<"done">>, <<"c">>, completed, 1, x)),
            ok = barrel_a2a_task_registry:insert(Tab, entry(<<"failed">>, <<"c">>, failed, 1, x)),
            ok = barrel_a2a_task_registry:insert(Tab, entry(<<"live">>, <<"c">>, working, 1, x)),
            %% a finished task still attached to a process is kept
            Attached = entry(<<"attached">>, <<"c">>, canceled, 1, x),
            ok = barrel_a2a_task_registry:insert(Tab, Attached#{pid => self()}),
            timer:sleep(20),
            %% nothing is older than an hour
            ?assertEqual(0, barrel_a2a_task_registry:expire(Tab, 3600000)),
            ?assertEqual(4, length(barrel_a2a_task_registry:all(Tab))),
            ?assertEqual(2, barrel_a2a_task_registry:expire(Tab, 0)),
            ?assertEqual(error, barrel_a2a_task_registry:lookup(Tab, <<"done">>)),
            ?assertEqual(error, barrel_a2a_task_registry:lookup(Tab, <<"failed">>)),
            ?assertMatch({ok, _}, barrel_a2a_task_registry:lookup(Tab, <<"live">>)),
            ?assertMatch({ok, _}, barrel_a2a_task_registry:lookup(Tab, <<"attached">>)),
            ?assertEqual(0, barrel_a2a_task_registry:expire(Tab, 0))
        end)
    ].

%%--------------------------------------------------------------------
%% task_proc helpers
%%--------------------------------------------------------------------

start(Handler) -> start(Handler, #{}).

start(Handler, Extra) ->
    Tab = barrel_a2a_task_registry:new(),
    Cfg = maps:merge(#{handler => Handler, registry => Tab}, Extra),
    Id = barrel_a2a_id:uuid(),
    Ctx = barrel_a2a_id:uuid(),
    Msg = barrel_a2a_message:new(<<"hello">>, #{message_id => <<"m1">>}),
    {ok, Pid} = barrel_a2a_task_proc:start_link(#{
        cfg => Cfg,
        task_id => Id,
        context_id => Ctx,
        message => Msg,
        owner => anonymous,
        req => #{}
    }),
    {ok, undefined} = barrel_a2a_task_proc:subscribe(Pid, self()),
    track(Pid),
    #{pid => Pid, id => Id, ctx => Ctx, tab => Tab, msg => Msg}.

%% Monitor a task process from the start so its exit is never missed,
%% and remember it so the test wrapper can kill it afterwards.
track(Pid) ->
    put({mon, Pid}, erlang:monitor(process, Pid)),
    put(task_pids, [Pid | get_list(task_pids)]),
    ok.

get_list(Key) ->
    case get(Key) of
        undefined -> [];
        L -> L
    end.

%% Each task_proc test runs in its own process (own mailbox, own ETS
%% table); leftover task processes are killed before the table owner
%% exits so they do not crash in terminate/2.
t(Fun) ->
    {spawn,
        {timeout, 10, fun() ->
            try
                Fun()
            after
                lists:foreach(
                    fun(P) ->
                        unlink(P),
                        exit(P, kill)
                    end,
                    get_list(task_pids)
                )
            end
        end}}.

recv() ->
    receive
        {a2a_task_event, _, _} = Ev -> Ev;
        {a2a_task_error, _, _} = Err -> Err
    after ?RECV_MS -> error(no_event)
    end.

recv(Tag) ->
    receive
        {Tag, _} = M -> M
    after ?RECV_MS -> error({no_message, Tag})
    end.

expect_task(Id) ->
    {a2a_task_event, Id, #{<<"task">> := T}} = recv(),
    T.

expect_status(Id, State) ->
    {a2a_task_event, Id, #{<<"statusUpdate">> := #{<<"status">> := Status}}} = recv(),
    ?assertEqual(barrel_a2a_task_state:to_wire(State), maps:get(<<"state">>, Status)),
    Status.

expect_artifact(Id) ->
    {a2a_task_event, Id, #{<<"artifactUpdate">> := Ev}} = recv(),
    Ev.

no_more_events() ->
    receive
        {a2a_task_event, _, _} = Ev -> error({unexpected_event, Ev});
        {a2a_task_error, _, _} = Err -> error({unexpected_error, Err})
    after 150 -> ok
    end.

wait_down(Pid) ->
    Ref =
        case get({mon, Pid}) of
            undefined -> erlang:monitor(process, Pid);
            R -> R
        end,
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    after ?RECV_MS -> error(still_alive)
    end.

snapshot(#{tab := Tab, id := Id}) ->
    {ok, #{task := T} = E} = barrel_a2a_task_registry:lookup(Tab, Id),
    {T, E}.

%%--------------------------------------------------------------------
%% task_proc
%%--------------------------------------------------------------------

ok_result_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id, ctx := Ctx} = S = start(fun(_Ctx, _M) -> {ok, <<"hi">>} end),
        ok = barrel_a2a_task_proc:run(Pid),
        T0 = expect_task(Id),
        ?assertEqual(Id, barrel_a2a_task:id(T0)),
        ?assertEqual(Ctx, barrel_a2a_task:context_id(T0)),
        ?assertEqual(submitted, barrel_a2a_task:state(T0)),
        ?assertEqual([<<"m1">>], [barrel_a2a_message:id(M) || M <- barrel_a2a_task:history(T0)]),
        Art = expect_artifact(Id),
        ?assertMatch(
            #{
                <<"taskId">> := Id,
                <<"contextId">> := Ctx,
                <<"lastChunk">> := true,
                <<"append">> := false
            },
            Art
        ),
        Artifact = maps:get(<<"artifact">>, Art),
        ?assert(barrel_a2a_id:is_uuid(barrel_a2a_artifact:id(Artifact))),
        ?assertEqual(<<"hi">>, barrel_a2a_artifact:text(Artifact)),
        Status = expect_status(Id, completed),
        ?assertNot(maps:is_key(<<"message">>, Status)),
        ?assert(barrel_a2a_time:is_iso(maps:get(<<"timestamp">>, Status))),
        no_more_events(),
        {T, #{state := State, owner := Owner}} = snapshot(S),
        ?assertEqual(completed, State),
        ?assertEqual(anonymous, Owner),
        ?assertEqual(completed, barrel_a2a_task:state(T)),
        ?assertEqual([Artifact], barrel_a2a_task:artifacts(T)),
        %% the process lingers briefly and exits normally; the row stays
        ?assertEqual(normal, wait_down(Pid)),
        ?assertMatch(
            {ok, #{pid := undefined, state := completed}},
            barrel_a2a_task_registry:lookup(maps:get(tab, S), Id)
        )
    end).

ok_result_with_artifact_test_() ->
    t(fun() ->
        Artifact = barrel_a2a_artifact:new(<<"pre-built">>, #{
            artifact_id => <<"art-1">>, name => <<"n">>
        }),
        #{pid := Pid, id := Id} = S = start(fun(_Ctx, _M) -> {ok, Artifact} end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        ?assertMatch(#{<<"artifact">> := Artifact}, expect_artifact(Id)),
        _ = expect_status(Id, completed),
        {T, _} = snapshot(S),
        ?assertEqual([Artifact], barrel_a2a_task:artifacts(T))
    end).

direct_message_test_() ->
    t(fun() ->
        Reply = barrel_a2a_message:agent(<<"reply">>, #{message_id => <<"r1">>}),
        #{pid := Pid, id := Id, ctx := Ctx, tab := Tab} = start(fun(_Ctx, _M) ->
            {message, Reply}
        end),
        ok = barrel_a2a_task_proc:run(Pid),
        {a2a_task_event, Id, #{<<"message">> := M}} = recv(),
        ?assertEqual(<<"r1">>, barrel_a2a_message:id(M)),
        ?assertEqual(agent, barrel_a2a_message:role(M)),
        ?assertEqual(Ctx, barrel_a2a_message:context_id(M)),
        ?assertNot(maps:is_key(<<"taskId">>, M)),
        no_more_events(),
        ?assertEqual(normal, wait_down(Pid)),
        ?assertEqual(error, barrel_a2a_task_registry:lookup(Tab, Id)),
        ?assertEqual([], barrel_a2a_task_registry:all(Tab))
    end).

input_required_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(Ctx, M) ->
            Test ! {invoked, {barrel_a2a_ctx:is_follow_up(Ctx), barrel_a2a_message:id(M)}},
            case barrel_a2a_ctx:is_follow_up(Ctx) of
                false ->
                    ?assertEqual(undefined, barrel_a2a_ctx:task(Ctx)),
                    {input_required, <<"more?">>};
                true ->
                    %% the snapshot is taken after the transition back to working;
                    %% history holds m1, the agent's "more?" and m2
                    T = barrel_a2a_ctx:task(Ctx),
                    ?assertEqual(working, barrel_a2a_task:state(T)),
                    ?assertEqual(3, length(barrel_a2a_task:history(T))),
                    ?assertEqual(
                        <<"m2">>, barrel_a2a_message:id(lists:last(barrel_a2a_task:history(T)))
                    ),
                    {ok, <<"done">>}
            end
        end,
        #{pid := Pid, id := Id, ctx := Ctx} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        ?assertEqual({invoked, {false, <<"m1">>}}, recv(invoked)),
        _ = expect_task(Id),
        Status = expect_status(Id, input_required),
        StatusMsg = maps:get(<<"message">>, Status),
        ?assertEqual(<<"more?">>, barrel_a2a_message:text(StatusMsg)),
        ?assertEqual(agent, barrel_a2a_message:role(StatusMsg)),
        ?assertEqual(Id, barrel_a2a_message:task_id(StatusMsg)),
        ?assertEqual(Ctx, barrel_a2a_message:context_id(StatusMsg)),
        no_more_events(),
        {T1, #{state := input_required}} = snapshot(S),
        ?assert(barrel_a2a_task:is_interrupted(T1)),
        ?assertEqual(<<"more?">>, barrel_a2a_message:text(barrel_a2a_task:status_message(T1))),
        %% follow-up
        Follow = barrel_a2a_message:new(<<"here you go">>, #{message_id => <<"m2">>}),
        ?assertEqual(ok, barrel_a2a_task_proc:send_message(Pid, Follow, #{})),
        _ = expect_status(Id, working),
        ?assertEqual({invoked, {true, <<"m2">>}}, recv(invoked)),
        _ = expect_artifact(Id),
        _ = expect_status(Id, completed),
        %% a message on a finished task is refused
        ?assertMatch(
            {error, #{type := unsupported_operation}},
            barrel_a2a_task_proc:send_message(Pid, Follow, #{})
        ),
        no_more_events(),
        {T2, #{state := completed}} = snapshot(S),
        ?assertEqual(
            [<<"m1">>, <<"m2">>],
            [
                barrel_a2a_message:id(M)
             || M <- barrel_a2a_task:history(T2), barrel_a2a_message:role(M) =:= user
            ]
        ),
        ?assertEqual(<<"done">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T2))))
    end).

error_result_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} = S = start(fun(_Ctx, _M) -> {error, <<"boom">>} end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        Status = expect_status(Id, failed),
        Msg = maps:get(<<"message">>, Status),
        ?assertEqual(<<"boom">>, barrel_a2a_message:text(Msg)),
        ?assertEqual(agent, barrel_a2a_message:role(Msg)),
        ?assertEqual(Id, barrel_a2a_message:task_id(Msg)),
        no_more_events(),
        {T, #{state := failed}} = snapshot(S),
        ?assert(barrel_a2a_task:is_terminal(T)),
        ?assertEqual(<<"boom">>, barrel_a2a_message:text(barrel_a2a_task:status_message(T))),
        %% the status message is also appended to the history
        ?assertEqual(<<"boom">>, barrel_a2a_message:text(lists:last(barrel_a2a_task:history(T)))),
        ?assertEqual([], barrel_a2a_task:artifacts(T))
    end).

error_message_result_test_() ->
    t(fun() ->
        Msg = barrel_a2a_message:agent(<<"nope">>, #{message_id => <<"e1">>}),
        #{pid := Pid, id := Id} = start(fun(_Ctx, _M) -> {error, Msg} end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        Status = expect_status(Id, failed),
        ?assertEqual(<<"e1">>, barrel_a2a_message:id(maps:get(<<"message">>, Status)))
    end).

crash_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} = S = start(fun(_Ctx, _M) -> error(kaboom) end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        Status = expect_status(Id, failed),
        ?assertEqual(
            <<"Handler crashed">>, barrel_a2a_message:text(maps:get(<<"message">>, Status))
        ),
        no_more_events(),
        {_, #{state := failed}} = snapshot(S),
        ?assertEqual(normal, wait_down(Pid))
    end).

invalid_result_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} = start(fun(_Ctx, _M) -> something_else end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        Status = expect_status(Id, failed),
        ?assertEqual(
            <<"Invalid handler result">>, barrel_a2a_message:text(maps:get(<<"message">>, Status))
        )
    end).

reject_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} = S = start(fun(_Ctx, _M) -> {reject, <<"no thanks">>} end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        Status = expect_status(Id, rejected),
        ?assertEqual(<<"no thanks">>, barrel_a2a_message:text(maps:get(<<"message">>, Status))),
        ?assertMatch(
            {error, #{type := task_not_cancelable}}, barrel_a2a_task_proc:cancel(Pid, #{})
        ),
        no_more_events(),
        {_, #{state := rejected}} = snapshot(S)
    end).

ctx_driven_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(Ctx, _M) ->
            ok = barrel_a2a_ctx:status(Ctx, working),
            ok = barrel_a2a_ctx:message(Ctx, <<"progress">>),
            ok = barrel_a2a_ctx:artifact(Ctx, <<"part one">>, #{
                artifact_id => <<"art">>, name => <<"out">>
            }),
            ok = barrel_a2a_ctx:artifact(Ctx, <<" part two">>, #{
                artifact_id => <<"art">>, append => true
            }),
            ok = barrel_a2a_ctx:artifact(Ctx, barrel_a2a_part:data(#{<<"n">> => 3}), #{
                artifact_id => <<"art">>, append => true, last_chunk => true
            }),
            ok = barrel_a2a_ctx:artifact(Ctx, <<"other">>, #{artifact_id => <<"other">>}),
            %% a bad transition is reported, not fatal
            Test ! {bad, barrel_a2a_ctx:status(Ctx, submitted)},
            ok
        end,
        #{pid := Pid, id := Id, ctx := Ctx} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        T0 = expect_task(Id),
        ?assertEqual(submitted, barrel_a2a_task:state(T0)),
        Working = expect_status(Id, working),
        ?assertNot(maps:is_key(<<"message">>, Working)),
        Progress = expect_status(Id, working),
        ?assertEqual(<<"progress">>, barrel_a2a_message:text(maps:get(<<"message">>, Progress))),
        A1 = expect_artifact(Id),
        ?assertMatch(
            #{
                <<"append">> := false,
                <<"lastChunk">> := false,
                <<"taskId">> := Id,
                <<"contextId">> := Ctx
            },
            A1
        ),
        ?assertEqual(<<"out">>, barrel_a2a_artifact:name(maps:get(<<"artifact">>, A1))),
        A2 = expect_artifact(Id),
        ?assertMatch(#{<<"append">> := true, <<"lastChunk">> := false}, A2),
        A3 = expect_artifact(Id),
        ?assertMatch(#{<<"append">> := true, <<"lastChunk">> := true}, A3),
        A4 = expect_artifact(Id),
        ?assertEqual(<<"other">>, barrel_a2a_artifact:id(maps:get(<<"artifact">>, A4))),
        ?assertMatch({bad, {error, {invalid_transition, working, submitted}}}, recv(bad)),
        _ = expect_status(Id, completed),
        no_more_events(),
        {T, #{state := completed}} = snapshot(S),
        [Merged, Other] = barrel_a2a_task:artifacts(T),
        ?assertEqual(<<"art">>, barrel_a2a_artifact:id(Merged)),
        ?assertEqual(<<"out">>, barrel_a2a_artifact:name(Merged)),
        ?assertEqual(3, length(barrel_a2a_artifact:parts(Merged))),
        ?assertEqual(<<"part one part two">>, barrel_a2a_artifact:text(Merged)),
        ?assertEqual(<<"other">>, barrel_a2a_artifact:id(Other)),
        %% the progress message went to the history
        ?assertEqual(
            <<"progress">>, barrel_a2a_message:text(lists:last(barrel_a2a_task:history(T)))
        )
    end).

ctx_handler_returns_ok_when_terminal_test_() ->
    t(fun() ->
        Handler = fun(Ctx, _M) ->
            ok = barrel_a2a_ctx:status(Ctx, failed, #{message => <<"gave up">>}),
            %% no further changes are accepted on a terminal task
            {error, task_terminal} = barrel_a2a_ctx:artifact(Ctx, <<"late">>),
            {error, _} = barrel_a2a_ctx:status(Ctx, working),
            ok
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        Status = expect_status(Id, failed),
        ?assertEqual(<<"gave up">>, barrel_a2a_message:text(maps:get(<<"message">>, Status))),
        no_more_events(),
        {T, #{state := failed}} = snapshot(S),
        ?assertEqual([], barrel_a2a_task:artifacts(T))
    end).

cancel_blocking_handler_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(Ctx, _M) ->
            Test ! {worker, self()},
            ok = barrel_a2a_ctx:status(Ctx, working),
            Loop = fun Loop() ->
                case barrel_a2a_ctx:cancelled(Ctx) of
                    true -> Test ! {worker, saw_cancel};
                    false -> ok
                end,
                timer:sleep(10),
                Loop()
            end,
            Loop()
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        {worker, Worker} = recv(worker),
        _ = expect_task(Id),
        _ = expect_status(Id, working),
        {ok, T} = barrel_a2a_task_proc:cancel(Pid, #{<<"reason">> => <<"user">>}),
        ?assertEqual(canceled, barrel_a2a_task:state(T)),
        Msg = barrel_a2a_task:status_message(T),
        ?assertEqual(<<"Task canceled">>, barrel_a2a_message:text(Msg)),
        ?assertEqual(#{<<"reason">> => <<"user">>}, barrel_a2a_message:metadata(Msg)),
        %% a second cancel is idempotent (3.3.1) while the process
        %% lingers, and a follow-up message is refused
        ?assertMatch({ok, _}, barrel_a2a_task_proc:cancel(Pid, #{})),
        ?assertMatch(
            {error, #{type := unsupported_operation}},
            barrel_a2a_task_proc:send_message(Pid, barrel_a2a_message:new(<<"x">>), #{})
        ),
        _ = expect_status(Id, canceled),
        no_more_events(),
        ?assertNot(is_process_alive(Worker)),
        {_, #{state := canceled}} = snapshot(S)
    end).

cancel_sleeping_handler_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(_Ctx, _M) ->
            Test ! {worker, self()},
            timer:sleep(60000),
            {ok, <<"never">>}
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        {worker, Worker} = recv(worker),
        %% not materialized yet: cancel materializes it first
        {ok, T} = barrel_a2a_task_proc:cancel(Pid, #{}),
        ?assertEqual(canceled, barrel_a2a_task:state(T)),
        ?assertNot(maps:is_key(<<"metadata">>, barrel_a2a_task:status_message(T))),
        _ = expect_task(Id),
        _ = expect_status(Id, canceled),
        no_more_events(),
        ?assertNot(is_process_alive(Worker)),
        {_, #{state := canceled}} = snapshot(S)
    end).

cancel_completed_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} = start(fun(_Ctx, _M) -> {ok, <<"hi">>} end),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        _ = expect_artifact(Id),
        _ = expect_status(Id, completed),
        {error, E} = barrel_a2a_task_proc:cancel(Pid, #{}),
        ?assertEqual(task_not_cancelable, barrel_a2a_error:type(E))
    end).

await_timeout_test_() ->
    t(fun() ->
        Handler = fun(Ctx, _M) ->
            ok = barrel_a2a_ctx:status(Ctx, working),
            timer:sleep(60000),
            {ok, <<"never">>}
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        {task, T} = barrel_a2a_task_proc:await(Pid, 200),
        ?assertEqual(Id, barrel_a2a_task:id(T)),
        ?assertEqual(working, barrel_a2a_task:state(T)),
        {T2, #{state := working, pid := Pid}} = snapshot(S),
        ?assertEqual(T, T2),
        ?assertEqual({ok, T}, barrel_a2a_task_proc:get_task(Pid))
    end).

await_unmaterialized_timeout_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} =
            S = start(fun(_Ctx, _M) ->
                timer:sleep(60000),
                ok
            end),
        ok = barrel_a2a_task_proc:run(Pid),
        %% await materializes the task on timeout so the caller can answer
        {task, T} = barrel_a2a_task_proc:await(Pid, 100),
        ?assertEqual(submitted, barrel_a2a_task:state(T)),
        {_, #{state := submitted}} = snapshot(S),
        %% the Task event is delivered to the subscriber as well
        _ = expect_task(Id)
    end).

await_settled_test_() ->
    t(fun() ->
        #{pid := Pid} = start(fun(_Ctx, _M) -> {ok, <<"quick">>} end),
        ok = barrel_a2a_task_proc:run(Pid),
        {task, T} = barrel_a2a_task_proc:await(Pid, 5000),
        ?assertEqual(completed, barrel_a2a_task:state(T)),
        ?assertEqual(<<"quick">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T))))
    end).

await_message_test_() ->
    t(fun() ->
        #{pid := Pid} = start(fun(_Ctx, _M) ->
            {message, barrel_a2a_message:agent(<<"direct">>)}
        end),
        ok = barrel_a2a_task_proc:run(Pid),
        {message, M} = barrel_a2a_task_proc:await(Pid, 5000),
        ?assertEqual(<<"direct">>, barrel_a2a_message:text(M))
    end).

await_interrupted_test_() ->
    t(fun() ->
        #{pid := Pid} = start(fun(_Ctx, _M) -> {input_required, <<"?">>} end),
        ok = barrel_a2a_task_proc:run(Pid),
        {task, T} = barrel_a2a_task_proc:await(Pid, 5000),
        ?assertEqual(input_required, barrel_a2a_task:state(T))
    end).

auth_required_resume_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(Ctx, M) ->
            case barrel_a2a_ctx:is_follow_up(Ctx) of
                false ->
                    Test ! {ctx, Ctx},
                    {auth_required, <<"please log in">>};
                true ->
                    ?assertEqual(working, barrel_a2a_task:state(barrel_a2a_ctx:task(Ctx))),
                    %% resumed with the original message
                    Test ! {resumed, barrel_a2a_message:id(M)},
                    {ok, <<"authorized">>}
            end
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        {ctx, Ctx} = recv(ctx),
        _ = expect_task(Id),
        Status = expect_status(Id, auth_required),
        ?assertEqual(<<"please log in">>, barrel_a2a_message:text(maps:get(<<"message">>, Status))),
        no_more_events(),
        {_, #{state := auth_required}} = snapshot(S),
        %% resume from the test process, using the handler's ctx
        ?assertEqual(ok, barrel_a2a_ctx:resume(Ctx)),
        _ = expect_status(Id, working),
        ?assertEqual({resumed, <<"m1">>}, recv(resumed)),
        _ = expect_artifact(Id),
        _ = expect_status(Id, completed),
        %% resume on a task that is not interrupted is refused
        ?assertMatch(
            {error, {invalid_transition, completed, working}}, barrel_a2a_ctx:resume(Ctx)
        ),
        no_more_events(),
        {T, #{state := completed}} = snapshot(S),
        ?assertEqual(<<"authorized">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(T))))
    end).

resume_with_message_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(Ctx, M) ->
            case barrel_a2a_ctx:is_follow_up(Ctx) of
                false ->
                    Test ! {ctx, Ctx},
                    {auth_required, <<"login">>};
                true ->
                    Test ! {resumed, barrel_a2a_message:id(M)},
                    ok
            end
        end,
        #{pid := Pid, id := Id} = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        {ctx, Ctx} = recv(ctx),
        _ = expect_task(Id),
        _ = expect_status(Id, auth_required),
        Other = barrel_a2a_message:new(<<"token">>, #{message_id => <<"m9">>}),
        ?assertEqual(ok, barrel_a2a_ctx:resume(Ctx, Other)),
        _ = expect_status(Id, working),
        ?assertEqual({resumed, <<"m9">>}, recv(resumed)),
        %% `ok' from a working task completes it
        _ = expect_status(Id, completed)
    end).

subscriber_down_test_() ->
    t(fun() ->
        Test = self(),
        Handler = fun(_Ctx, _M) ->
            Test ! {worker, self()},
            receive
                go -> {ok, <<"hi">>}
            end
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        Sub = spawn(fun() ->
            receive
                stop -> ok
            end
        end),
        {ok, undefined} = barrel_a2a_task_proc:subscribe(Pid, Sub),
        %% subscribing twice is idempotent
        {ok, undefined} = barrel_a2a_task_proc:subscribe(Pid, Sub),
        ok = barrel_a2a_task_proc:run(Pid),
        {worker, Worker} = recv(worker),
        Sub ! stop,
        _ = wait_down(Sub),
        %% the worker is waiting on us; release it after the subscriber died
        Worker ! go,
        _ = expect_task(Id),
        _ = expect_artifact(Id),
        _ = expect_status(Id, completed),
        {_, #{state := completed}} = snapshot(S),
        ?assertEqual(normal, wait_down(Pid))
    end).

unsubscribe_test_() ->
    t(fun() ->
        #{pid := Pid, id := Id} = S = start(fun(_Ctx, _M) -> {ok, <<"hi">>} end),
        ok = barrel_a2a_task_proc:unsubscribe(Pid, self()),
        ok = barrel_a2a_task_proc:run(Pid),
        no_more_events(),
        {_, #{state := completed}} = snapshot(S),
        ?assertEqual(Id, maps:get(id, S)),
        %% unsubscribe of a dead process does not raise
        _ = wait_down(Pid),
        ?assertEqual(ok, barrel_a2a_task_proc:unsubscribe(Pid, self()))
    end).

late_subscriber_gets_snapshot_test_() ->
    t(fun() ->
        Handler = fun(Ctx, _M) ->
            ok = barrel_a2a_ctx:status(Ctx, working),
            timer:sleep(60000),
            ok
        end,
        #{pid := Pid, id := Id} = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        _ = expect_status(Id, working),
        Other = spawn(fun() ->
            receive
                stop -> ok
            end
        end),
        {ok, Snapshot} = barrel_a2a_task_proc:subscribe(Pid, Other),
        ?assertEqual(working, barrel_a2a_task:state(Snapshot)),
        ?assertEqual(Id, barrel_a2a_task:id(Snapshot)),
        Other ! stop
    end).

protocol_error_throw_test_() ->
    t(fun() ->
        Handler = fun(_Ctx, _M) ->
            throw({a2a_error, barrel_a2a_error:new(content_type_not_supported)})
        end,
        #{pid := Pid, id := Id, tab := Tab} = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        {a2a_task_error, Id, Err} = recv(),
        ?assertMatch(
            #{type := content_type_not_supported, message := <<"Incompatible content types">>}, Err
        ),
        no_more_events(),
        %% never materialized: no registry row, process gone
        ?assertEqual(error, barrel_a2a_task_registry:lookup(Tab, Id)),
        ?assertEqual(normal, wait_down(Pid))
    end).

protocol_error_after_materialize_test_() ->
    t(fun() ->
        Handler = fun(Ctx, _M) ->
            ok = barrel_a2a_ctx:status(Ctx, working),
            throw({a2a_error, barrel_a2a_error:new(content_type_not_supported)})
        end,
        #{pid := Pid, id := Id} = S = start(Handler),
        ok = barrel_a2a_task_proc:run(Pid),
        _ = expect_task(Id),
        _ = expect_status(Id, working),
        %% once a task exists the error fails it instead
        Status = expect_status(Id, failed),
        ?assertEqual(
            <<"Incompatible content types">>,
            barrel_a2a_message:text(maps:get(<<"message">>, Status))
        ),
        {_, #{state := failed}} = snapshot(S)
    end).

await_error_test_() ->
    t(fun() ->
        #{pid := Pid} = start(fun(_Ctx, _M) ->
            throw({a2a_error, barrel_a2a_error:new(unsupported_operation)})
        end),
        ok = barrel_a2a_task_proc:run(Pid),
        ?assertMatch(
            {error, #{type := unsupported_operation}}, barrel_a2a_task_proc:await(Pid, 5000)
        )
    end).

push_notify_hook_test_() ->
    t(fun() ->
        Test = self(),
        Notify = fun(TaskId, Event) -> Test ! {push, {TaskId, barrel_a2a_event:kind(Event)}} end,
        #{pid := Pid, id := Id} = start(fun(_Ctx, _M) -> {ok, <<"hi">>} end, #{
            push_notify => Notify
        }),
        ok = barrel_a2a_task_proc:run(Pid),
        ?assertEqual({push, {Id, task}}, recv(push)),
        ?assertEqual({push, {Id, artifact_update}}, recv(push)),
        ?assertEqual({push, {Id, status_update}}, recv(push))
    end).

ctx_fields_test_() ->
    t(fun() ->
        Test = self(),
        Tab = barrel_a2a_task_registry:new(),
        Handler = fun(Ctx, M) ->
            Test ! {ctx, Ctx},
            Test ! {msg, M},
            {ok, <<"x">>}
        end,
        Msg = barrel_a2a_message:new(<<"hello">>, #{message_id => <<"m1">>}),
        Req = #{
            configuration => #{<<"acceptedOutputModes">> => [<<"text/plain">>]},
            metadata => #{<<"k">> => 1},
            extensions => [<<"ext:a">>],
            tenant => <<"acme">>,
            binding => rest
        },
        {ok, Pid} = barrel_a2a_task_proc:start_link(#{
            cfg => #{handler => Handler, registry => Tab},
            task_id => <<"task-1">>,
            context_id => <<"ctx-1">>,
            message => Msg,
            owner => {user, <<"alice">>},
            req => Req,
            metadata => #{<<"task">> => <<"meta">>}
        }),
        track(Pid),
        {ok, undefined} = barrel_a2a_task_proc:subscribe(Pid, self()),
        ok = barrel_a2a_task_proc:run(Pid),
        {ctx, Ctx} = recv(ctx),
        {msg, Msg} = recv(msg),
        ?assertEqual(Msg, barrel_a2a_ctx:message(Ctx)),
        ?assertEqual(<<"task-1">>, barrel_a2a_ctx:task_id(Ctx)),
        ?assertEqual(<<"ctx-1">>, barrel_a2a_ctx:context_id(Ctx)),
        ?assertEqual(undefined, barrel_a2a_ctx:task(Ctx)),
        ?assertNot(barrel_a2a_ctx:is_follow_up(Ctx)),
        ?assertEqual(
            #{<<"acceptedOutputModes">> => [<<"text/plain">>]}, barrel_a2a_ctx:configuration(Ctx)
        ),
        ?assertEqual([<<"text/plain">>], barrel_a2a_ctx:accepted_output_modes(Ctx)),
        ?assertEqual(#{<<"k">> => 1}, barrel_a2a_ctx:metadata(Ctx)),
        ?assertEqual([<<"ext:a">>], barrel_a2a_ctx:extensions(Ctx)),
        ?assertEqual(<<"acme">>, barrel_a2a_ctx:tenant(Ctx)),
        ?assertEqual({user, <<"alice">>}, barrel_a2a_ctx:principal(Ctx)),
        ?assertEqual(rest, barrel_a2a_ctx:binding(Ctx)),
        ?assertEqual(Pid, maps:get(task_pid, Ctx)),
        _ = expect_task(<<"task-1">>),
        _ = expect_artifact(<<"task-1">>),
        _ = expect_status(<<"task-1">>, completed),
        {ok, #{task := T, owner := Owner}} = barrel_a2a_task_registry:lookup(Tab, <<"task-1">>),
        ?assertEqual({user, <<"alice">>}, Owner),
        ?assertEqual(#{<<"task">> => <<"meta">>}, barrel_a2a_task:metadata(T)),
        ?assertEqual(completed, barrel_a2a_task:state(T))
    end).
