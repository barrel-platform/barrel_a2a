%%%-------------------------------------------------------------------
%%% @doc Unfinished tasks found in a persistent store on server start:
%%% failed by default, or resumed by the application's `resume' fun and
%%% then served as live tasks under their original ids. Every case
%%% starts its own server on a store seeded as a previous run left it,
%%% and runs over both bindings.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_resume_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [{group, jsonrpc}, {group, rest}, invalid_option].

groups() ->
    Cases = [
        no_option_fails,
        resume_fail_fails,
        resume_completes,
        resume_crash_fails_that_task,
        resume_cancel_seen_by_fun,
        keep_paused_task,
        paused_task_cannot_be_run,
        push_config_survives_restart,
        push_final_status_redelivered
    ],
    [{jsonrpc, [], Cases}, {rest, [], Cases}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_a2a),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(jsonrpc, Config) -> [{prefer, [jsonrpc]} | Config];
init_per_group(rest, Config) -> [{prefer, [rest]} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    File = filename:join(
        ?config(priv_dir, Config),
        "tasks_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"
    ),
    [
        {store, {barrel_a2a_task_store_dets, #{file => File}}},
        {push_store, {barrel_a2a_task_store_dets, #{file => File ++ ".push"}}}
        | Config
    ].

end_per_testcase(_Case, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Leave rows in the store as a previous run would: the task was
%% working when the node went down.
seed(Config, Ids) ->
    seed(Config, Ids, working).

seed(Config, Ids, State) ->
    {ok, Store} = barrel_a2a_task_registry:new(?config(store, Config)),
    lists:foreach(
        fun(Id) ->
            Msg = barrel_a2a_message:new(<<"work on ", Id/binary>>),
            Task0 = barrel_a2a_task:add_history(
                barrel_a2a_task:new(Id, <<"ctx-1">>), Msg, unlimited
            ),
            Task = barrel_a2a_task:set_status(Task0, State, undefined),
            ok = barrel_a2a_task_registry:insert(Store, #{
                id => Id, pid => self(), task => Task, owner => anonymous
            })
        end,
        Ids
    ),
    ok = barrel_a2a_task_registry:close(Store).

start(Config, Extra) ->
    Opts = maps:merge(
        #{
            handler => fun(_Ctx, _Msg) -> {error, <<"handler must not run">>} end,
            http => #{port => 0},
            task_store => ?config(store, Config)
        },
        Extra
    ),
    Card = barrel_a2a_agent_card:new(#{name => <<"Resume">>, description => <<"resume">>}),
    {ok, Server} = barrel_a2a_server:start(Card, Opts),
    {ok, Agent} = barrel_a2a_client:connect(
        barrel_a2a_server:url(Server), #{prefer => ?config(prefer, Config), timeout => 5000}
    ),
    {Server, Agent}.

poll_until(_Agent, _Id, _State, 0) ->
    ct:fail(poll_timeout);
poll_until(Agent, Id, State, N) ->
    {ok, Task} = barrel_a2a_client:get_task(Agent, Id),
    case barrel_a2a_task:state(Task) of
        State ->
            Task;
        _ ->
            timer:sleep(50),
            poll_until(Agent, Id, State, N - 1)
    end.

status_text(Task) ->
    barrel_a2a_message:text(barrel_a2a_task:status_message(Task)).

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

%% Without the option an unfinished task is failed, as before 0.2.1.
no_option_fails(Config) ->
    seed(Config, [<<"t1">>]),
    {Server, Agent} = start(Config, #{}),
    {ok, Task} = barrel_a2a_client:get_task(Agent, <<"t1">>),
    ?assertEqual(failed, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"Task interrupted by a server restart">>, status_text(Task)),
    barrel_a2a_server:stop(Server).

resume_fail_fails(Config) ->
    seed(Config, [<<"t1">>]),
    {Server, Agent} = start(Config, #{resume => fun(_) -> fail end}),
    {ok, Task} = barrel_a2a_client:get_task(Agent, <<"t1">>),
    ?assertEqual(failed, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"Task interrupted by a server restart">>, status_text(Task)),
    barrel_a2a_server:stop(Server).

resume_completes(Config) ->
    seed(Config, [<<"t1">>]),
    Resume = fun(_) -> {resume, fun(_) -> {ok, barrel_a2a_part:data(#{<<"x">> => 1})} end} end,
    {Server, Agent} = start(Config, #{resume => Resume}),
    Task = poll_until(Agent, <<"t1">>, completed, 100),
    ?assertEqual(<<"ctx-1">>, barrel_a2a_task:context_id(Task)),
    [Artifact] = barrel_a2a_task:artifacts(Task),
    ?assertMatch([#{<<"data">> := #{<<"x">> := 1}}], barrel_a2a_artifact:parts(Artifact)),
    barrel_a2a_server:stop(Server).

%% A decision fun that crashes, and a resumed fun that crashes, each
%% fail their own task; the others complete.
resume_crash_fails_that_task(Config) ->
    seed(Config, [<<"ok">>, <<"bad-decision">>, <<"bad-run">>]),
    Resume = fun(Task) ->
        case barrel_a2a_task:id(Task) of
            <<"bad-decision">> -> error(boom);
            <<"bad-run">> -> {resume, fun(_) -> error(boom) end};
            <<"ok">> -> {resume, fun(_) -> {ok, <<"done">>} end}
        end
    end,
    {Server, Agent} = start(Config, #{resume => Resume}),
    Ok = poll_until(Agent, <<"ok">>, completed, 100),
    ?assertEqual(<<"done">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Ok)))),
    Decision = poll_until(Agent, <<"bad-decision">>, failed, 100),
    ?assertEqual(<<"Task interrupted by a server restart">>, status_text(Decision)),
    Run = poll_until(Agent, <<"bad-run">>, failed, 100),
    ?assertEqual(<<"Handler crashed">>, status_text(Run)),
    barrel_a2a_server:stop(Server).

resume_cancel_seen_by_fun(Config) ->
    seed(Config, [<<"t1">>]),
    Test = self(),
    Follow = fun(Ctx) ->
        Test ! {resumed, barrel_a2a_ctx:task_id(Ctx)},
        Loop = fun Loop() ->
            case barrel_a2a_ctx:cancelled(Ctx) of
                true ->
                    Test ! saw_cancel,
                    ok;
                false ->
                    timer:sleep(10),
                    Loop()
            end
        end,
        Loop()
    end,
    {Server, Agent} = start(Config, #{resume => fun(_) -> {resume, Follow} end}),
    receive
        {resumed, <<"t1">>} -> ok
    after 5000 -> ct:fail(not_resumed)
    end,
    {ok, Canceled} = barrel_a2a_client:cancel(Agent, <<"t1">>),
    ?assertEqual(canceled, barrel_a2a_task:state(Canceled)),
    receive
        saw_cancel -> ok
    after 5000 -> ct:fail(cancel_not_seen)
    end,
    {ok, After} = barrel_a2a_client:get_task(Agent, <<"t1">>),
    ?assertEqual(canceled, barrel_a2a_task:state(After)),
    barrel_a2a_server:stop(Server).

%% A task paused for input when the node stopped is kept paused, and the
%% client's answer continues it through the handler.
keep_paused_task(Config) ->
    seed(Config, [<<"t1">>], input_required),
    Handler = fun(Ctx, Message) ->
        true = barrel_a2a_ctx:is_follow_up(Ctx),
        {ok, <<"got ", (barrel_a2a_message:text(Message))/binary>>}
    end,
    {Server, Agent} = start(Config, #{handler => Handler, resume => fun(_) -> keep end}),
    {ok, Paused} = barrel_a2a_client:get_task(Agent, <<"t1">>),
    ?assertEqual(input_required, barrel_a2a_task:state(Paused)),
    {ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"blue">>, #{
        task_id => <<"t1">>, context_id => <<"ctx-1">>
    }),
    ?assertEqual(completed, barrel_a2a_task:state(Done)),
    ?assertEqual(<<"got blue">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Done)))),
    barrel_a2a_server:stop(Server).

%% `{resume, Fun}' on a paused task would continue it without the input
%% it waits for, so the answer is refused and the task failed.
paused_task_cannot_be_run(Config) ->
    seed(Config, [<<"t1">>], input_required),
    Resume = fun(_) -> {resume, fun(_) -> {ok, <<"x">>} end} end,
    {Server, Agent} = start(Config, #{resume => Resume}),
    {ok, Task} = barrel_a2a_client:get_task(Agent, <<"t1">>),
    ?assertEqual(failed, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"Task interrupted by a server restart">>, status_text(Task)),
    barrel_a2a_server:stop(Server).

%% The first run: a task that is still working when the server stops,
%% with a webhook registered on it. Returns the task id.
first_run_with_webhook(Config, WebhookUrl) ->
    Blocks = fun(_Ctx, _Msg) ->
        receive
            never -> ok
        end
    end,
    {Server, Agent} = start(Config, push_opts(Config, #{handler => Blocks})),
    {ok, {task, T}} = barrel_a2a_client:send(Agent, <<"work">>, #{return_immediately => true}),
    Id = barrel_a2a_task:id(T),
    {ok, _} = barrel_a2a_client:create_push_config(Agent, Id, #{url => WebhookUrl}),
    barrel_a2a_server:stop(Server),
    Id.

push_opts(Config, Extra) ->
    maps:merge(
        #{
            push_notifications => #{ssrf_guard => false, timeout => 2000, backoff => {50, 2}},
            push_config_store => ?config(push_store, Config)
        },
        Extra
    ).

%% The final webhook event for `Id', skipping anything before it.
final_webhook(Id) ->
    receive
        {webhook, _Headers, Body} ->
            {ok, Ev} = barrel_a2a_json:decode(Body),
            case barrel_a2a_event:is_final(Ev) andalso barrel_a2a_event:task_id(Ev) =:= Id of
                true -> Ev;
                false -> final_webhook(Id)
            end
    after 5000 -> ct:fail(no_final_webhook)
    end.

final_state(Ev) ->
    #{<<"statusUpdate">> := #{<<"status">> := #{<<"state">> := S}}} = Ev,
    S.

%% A webhook registered before the restart is told how the resumed task
%% ends.
push_config_survives_restart(Config) ->
    {Webhook, Port} = barrel_a2a_test_agent:webhook_server(self()),
    try
        Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/hook">>,
        Id = first_run_with_webhook(Config, Url),
        Resume = fun(_) -> {resume, fun(_) -> {ok, <<"done">>} end} end,
        {Server, Agent} = start(Config, push_opts(Config, #{resume => Resume})),
        ?assertEqual(<<"TASK_STATE_COMPLETED">>, final_state(final_webhook(Id))),
        _ = poll_until(Agent, Id, completed, 100),
        barrel_a2a_server:stop(Server)
    after
        barrel_a2a_test_agent:webhook_stop(Webhook)
    end.

%% Without `resume' the restart fails the task, and its webhook is told
%% so.
push_final_status_redelivered(Config) ->
    {Webhook, Port} = barrel_a2a_test_agent:webhook_server(self()),
    try
        Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/hook">>,
        Id = first_run_with_webhook(Config, Url),
        {Server, Agent} = start(Config, push_opts(Config, #{})),
        Ev = final_webhook(Id),
        ?assertEqual(<<"TASK_STATE_FAILED">>, final_state(Ev)),
        {ok, Task} = barrel_a2a_client:get_task(Agent, Id),
        ?assertEqual(failed, barrel_a2a_task:state(Task)),
        barrel_a2a_server:stop(Server)
    after
        barrel_a2a_test_agent:webhook_stop(Webhook)
    end.

invalid_option(_Config) ->
    Card = barrel_a2a_agent_card:new(#{name => <<"Resume">>, description => <<"resume">>}),
    ?assertEqual(
        {error, {invalid_option, {resume, 42}}},
        barrel_a2a_server:start(Card, #{
            handler => fun(_, _) -> ok end, listen => false, resume => 42
        })
    ),
    ?assertEqual(
        {error, {invalid_option, {push_config_store, 42}}},
        barrel_a2a_server:start(Card, #{
            handler => fun(_, _) -> ok end,
            listen => false,
            push_notifications => #{},
            push_config_store => 42
        })
    ).
