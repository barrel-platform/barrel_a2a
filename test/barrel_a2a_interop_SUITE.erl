%%%-------------------------------------------------------------------
%%% @doc Interop suite: the wire format between barrel_a2a and the
%%% official A2A SDKs, in both directions and over both HTTP bindings.
%%%
%%% One group per reference implementation, all running the same cases:
%%%
%%% - `ref_client_*' runs that SDK's client script against an Erlang
%%%   server hosting `barrel_a2a_test_agent'. The script prints one
%%%   JSON line per step and the cases assert on those, so the contract
%%%   between suite and script is the same in every language.
%%% - `ref_server_*' starts that SDK's server script, which mirrors the
%%%   test agent, and drives it with `barrel_a2a_client'.
%%%
%%% A group skips when its toolchain is absent, so plain `rebar3 ct'
%%% needs none of them:
%%%
%%%   make interop-python   % INTEROP_PYTHON, a venv interpreter
%%%   make interop-js       % INTEROP_NODE, a node binary
%%%   make interop-go       % INTEROP_GO_BIN, a directory of two binaries
%%%   make interop          % all three
%%%
%%% Adding a fourth language is a script pair under `test/interop/',
%%% a clause of {@link runner/1} and a Makefile target.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    ref_client_jsonrpc_card/1,
    ref_client_jsonrpc_send/1,
    ref_client_jsonrpc_stream/1,
    ref_client_jsonrpc_multiturn/1,
    ref_client_jsonrpc_cancel/1,
    ref_client_jsonrpc_direct/1,
    ref_client_jsonrpc_get/1,
    ref_client_rest_card/1,
    ref_client_rest_send/1,
    ref_client_rest_stream/1,
    ref_client_rest_multiturn/1,
    ref_client_rest_cancel/1,
    ref_client_rest_direct/1,
    ref_client_rest_get/1,
    ref_client_jsonrpc_list_tasks/1,
    ref_client_rest_list_tasks/1,
    ref_client_jsonrpc_push_config/1,
    ref_client_rest_push_config/1,
    ref_client_jsonrpc_resubscribe/1,
    ref_client_rest_resubscribe/1,
    ref_client_jsonrpc_extended_card/1,
    ref_client_rest_extended_card/1,
    ref_server_jsonrpc_send/1,
    ref_server_jsonrpc_stream/1,
    ref_server_jsonrpc_multiturn/1,
    ref_server_jsonrpc_cancel/1,
    ref_server_jsonrpc_get/1,
    ref_server_jsonrpc_direct/1,
    ref_server_rest_send/1,
    ref_server_rest_stream/1,
    ref_server_rest_multiturn/1,
    ref_server_rest_cancel/1,
    ref_server_rest_get/1,
    ref_server_rest_direct/1
]).

-define(CLIENT_TIMEOUT, 60000).
-define(READY_TIMEOUT, 30000).
-define(PUSH_URL, <<"https://example.com/hook">>).

-define(LANGUAGES, [python, js, go]).

all() ->
    [{group, L} || L <- ?LANGUAGES].

groups() ->
    [{L, [], cases()} || L <- ?LANGUAGES].

cases() ->
    [
        ref_client_jsonrpc_card,
        ref_client_jsonrpc_send,
        ref_client_jsonrpc_stream,
        ref_client_jsonrpc_multiturn,
        ref_client_jsonrpc_cancel,
        ref_client_jsonrpc_direct,
        ref_client_jsonrpc_get,
        ref_client_rest_card,
        ref_client_rest_send,
        ref_client_rest_stream,
        ref_client_rest_multiturn,
        ref_client_rest_cancel,
        ref_client_rest_direct,
        ref_client_rest_get,
        ref_client_jsonrpc_list_tasks,
        ref_client_rest_list_tasks,
        ref_client_jsonrpc_push_config,
        ref_client_rest_push_config,
        ref_client_jsonrpc_resubscribe,
        ref_client_rest_resubscribe,
        ref_client_jsonrpc_extended_card,
        ref_client_rest_extended_card,
        ref_server_jsonrpc_send,
        ref_server_jsonrpc_stream,
        ref_server_jsonrpc_multiturn,
        ref_server_jsonrpc_cancel,
        ref_server_jsonrpc_get,
        ref_server_jsonrpc_direct,
        ref_server_rest_send,
        ref_server_rest_stream,
        ref_server_rest_multiturn,
        ref_server_rest_cancel,
        ref_server_rest_get,
        ref_server_rest_direct
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_a2a),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Language, Config) ->
    case runner(Language) of
        {error, Why} -> {skip, Why};
        {ok, Runner} -> [{runner, Runner} | Config]
    end.

end_per_group(_Language, _Config) ->
    ok.

%% `ref_client_*' needs an Erlang server to talk to; `ref_server_*'
%% needs the SDK's. The case name carries the binding.
init_per_testcase(TC, Config) ->
    case atom_to_list(TC) of
        "ref_client_" ++ _ ->
            {ok, Server} = barrel_a2a_server:start(barrel_a2a_test_agent:card(), #{
                handler => barrel_a2a_test_agent,
                http => #{port => 0},
                blocking_timeout => 10000,
                %% The push and extended card scenarios need the
                %% capabilities advertised. The guard is off because the
                %% scenario registers a webhook it never calls.
                push_notifications => #{ssrf_guard => false},
                extended_card => barrel_a2a_test_agent:card(#{name => <<"Extended">>})
            }),
            [{server, Server} | Config];
        "ref_server_" ++ _ ->
            Port = free_port(),
            RefPort = start_ref_server(?config(runner, Config), Port),
            [{ref_port, RefPort}, {ref_url, base_url(Port)} | Config]
    end.

end_per_testcase(_TC, Config) ->
    case ?config(server, Config) of
        undefined -> ok;
        Server -> safe_stop(Server)
    end,
    case ?config(ref_port, Config) of
        undefined -> ok;
        RefPort -> stop_ref_server(RefPort)
    end,
    ok.

%%====================================================================
%% Direction A: Python client against the Erlang server
%%====================================================================

ref_client_jsonrpc_card(Config) -> card_case(jsonrpc, Config).
ref_client_rest_card(Config) -> card_case(rest, Config).

card_case(Binding, Config) ->
    #{<<"card">> := Card} = run_client(Binding, "card", Config),
    ?assertEqual(<<"Test Agent">>, maps:get(<<"name">>, Card)),
    ?assertEqual(1, maps:get(<<"skills">>, Card)),
    ?assertEqual(true, maps:get(<<"streaming">>, Card)),
    Bindings = [maps:get(<<"binding">>, I) || I <- maps:get(<<"interfaces">>, Card)],
    ?assert(lists:member(<<"JSONRPC">>, Bindings)),
    ?assert(lists:member(<<"HTTP+JSON">>, Bindings)),
    Url = barrel_a2a_server:url(?config(server, Config)),
    ?assert(
        lists:all(
            fun(I) -> binary:match(maps:get(<<"url">>, I), Url) =/= nomatch end,
            maps:get(<<"interfaces">>, Card)
        )
    ).

ref_client_jsonrpc_send(Config) -> send_case(jsonrpc, Config).
ref_client_rest_send(Config) -> send_case(rest, Config).

send_case(Binding, Config) ->
    #{<<"send">> := Send} = run_client(Binding, "send", Config),
    ?assertEqual([<<"task">>], maps:get(<<"kinds">>, Send)),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Send)),
    ?assertEqual(<<"interop">>, maps:get(<<"artifact">>, Send)),
    ?assert(is_binary(maps:get(<<"task_id">>, Send))),
    ?assert(is_binary(maps:get(<<"context_id">>, Send))).

ref_client_jsonrpc_stream(Config) -> stream_case(jsonrpc, Config).
ref_client_rest_stream(Config) -> stream_case(rest, Config).

stream_case(Binding, Config) ->
    Steps = run_client(Binding, "stream", Config),
    #{<<"stream">> := Stream} = Steps,
    ?assertEqual(
        [
            <<"task">>,
            <<"status_update">>,
            <<"artifact_update">>,
            <<"artifact_update">>,
            <<"status_update">>
        ],
        maps:get(<<"kinds">>, Stream)
    ),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Stream)),
    Events = maps:get(<<"event">>, Steps),
    [First, Second] = [E || #{<<"kind">> := <<"artifact_update">>} = E <- Events],
    ?assertEqual(<<"part one ">>, maps:get(<<"text">>, First)),
    ?assertEqual(false, maps:get(<<"append">>, First)),
    ?assertEqual(<<"part two">>, maps:get(<<"text">>, Second)),
    ?assertEqual(true, maps:get(<<"append">>, Second)),
    ?assertEqual(true, maps:get(<<"last_chunk">>, Second)),
    ?assertEqual(
        [<<"TASK_STATE_WORKING">>, <<"TASK_STATE_COMPLETED">>],
        [S || #{<<"kind">> := <<"status_update">>, <<"state">> := S} <- Events]
    ).

ref_client_jsonrpc_multiturn(Config) -> multiturn_case(jsonrpc, Config).
ref_client_rest_multiturn(Config) -> multiturn_case(rest, Config).

multiturn_case(Binding, Config) ->
    #{<<"ask">> := Ask, <<"multiturn">> := Done} = run_client(Binding, "multiturn", Config),
    ?assertEqual(<<"TASK_STATE_INPUT_REQUIRED">>, maps:get(<<"state">>, Ask)),
    ?assertEqual(<<"more?">>, maps:get(<<"prompt">>, Ask)),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Done)),
    ?assertEqual(<<"thanks: second">>, maps:get(<<"artifact">>, Done)),
    ?assertEqual(true, maps:get(<<"same_task">>, Done)),
    ?assertEqual(3, maps:get(<<"history">>, Done)).

ref_client_jsonrpc_cancel(Config) -> cancel_case(jsonrpc, Config).
ref_client_rest_cancel(Config) -> cancel_case(rest, Config).

cancel_case(Binding, Config) ->
    #{<<"started">> := Started, <<"cancel">> := Cancel, <<"after_cancel">> := After} =
        run_client(Binding, "cancel", Config),
    ?assert(
        lists:member(maps:get(<<"state">>, Started), [
            <<"TASK_STATE_SUBMITTED">>, <<"TASK_STATE_WORKING">>
        ])
    ),
    ?assertEqual(<<"TASK_STATE_CANCELED">>, maps:get(<<"state">>, Cancel)),
    ?assertEqual(maps:get(<<"task_id">>, Started), maps:get(<<"task_id">>, Cancel)),
    ?assertEqual(<<"TASK_STATE_CANCELED">>, maps:get(<<"state">>, After)).

ref_client_jsonrpc_direct(Config) -> direct_case(jsonrpc, Config).
ref_client_rest_direct(Config) -> direct_case(rest, Config).

direct_case(Binding, Config) ->
    #{<<"direct">> := Direct} = run_client(Binding, "direct", Config),
    ?assertEqual([<<"message">>], maps:get(<<"kinds">>, Direct)),
    ?assertEqual(<<"direct reply">>, maps:get(<<"text">>, Direct)),
    ?assertEqual(<<"ROLE_AGENT">>, maps:get(<<"role">>, Direct)).

ref_client_jsonrpc_get(Config) -> get_case(jsonrpc, Config).
ref_client_rest_get(Config) -> get_case(rest, Config).

get_case(Binding, Config) ->
    #{<<"get">> := Get} = run_client(Binding, "get", Config),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Get)),
    ?assertEqual(true, maps:get(<<"same_id">>, Get)),
    ?assertEqual(<<"x">>, maps:get(<<"artifact">>, Get)).

ref_client_jsonrpc_list_tasks(Config) -> list_tasks_case(jsonrpc, Config).
ref_client_rest_list_tasks(Config) -> list_tasks_case(rest, Config).

%% ListTasks as an independent client sees it: the page is capped, the
%% total counts everything, and a token leads to the rest.
list_tasks_case(Binding, Config) ->
    #{<<"list">> := List, <<"page">> := Page} = run_client(Binding, "list_tasks", Config),
    ?assert(maps:get(<<"total">>, List) >= 2),
    ?assert(maps:get(<<"count">>, List) >= 2),
    ?assertEqual(1, maps:get(<<"count">>, Page)),
    ?assertNotEqual(<<>>, maps:get(<<"next">>, Page)).

ref_client_jsonrpc_push_config(Config) -> push_config_case(jsonrpc, Config).
ref_client_rest_push_config(Config) -> push_config_case(rest, Config).

%% The four push configuration operations, round trip.
push_config_case(Binding, Config) ->
    Steps = run_client(Binding, "push_config", Config),
    #{<<"created">> := Created, <<"fetched">> := Fetched} = Steps,
    #{<<"listed">> := Listed, <<"after_delete">> := After} = Steps,
    Id = maps:get(<<"id">>, Created),
    ?assert(is_binary(Id) andalso Id =/= <<>>),
    ?assertEqual(?PUSH_URL, maps:get(<<"url">>, Created)),
    ?assertEqual(Id, maps:get(<<"id">>, Fetched)),
    ?assertEqual(1, maps:get(<<"count">>, Listed)),
    ?assertEqual(0, maps:get(<<"count">>, After)).

ref_client_jsonrpc_resubscribe(Config) -> resubscribe_case(jsonrpc, Config).
ref_client_rest_resubscribe(Config) -> resubscribe_case(rest, Config).

%% Attaching to a task that is already running: the client must still
%% see it through to a terminal state (3.1.7).
resubscribe_case(Binding, Config) ->
    #{<<"started">> := Started, <<"resubscribe">> := Sub} =
        run_client(Binding, "resubscribe", Config),
    ?assert(
        lists:member(maps:get(<<"state">>, Started), [
            <<"TASK_STATE_SUBMITTED">>, <<"TASK_STATE_WORKING">>
        ])
    ),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Sub)),
    ?assert(maps:get(<<"events">>, Sub) >= 1).

ref_client_jsonrpc_extended_card(Config) -> extended_card_case(jsonrpc, Config).
ref_client_rest_extended_card(Config) -> extended_card_case(rest, Config).

%% The card advertises the capability and the server still refuses an
%% unauthenticated caller (13.3). Checked here because the error has to
%% be legible to a client that is not ours.
extended_card_case(Binding, Config) ->
    #{<<"extended_card">> := Res} = run_client(Binding, "extended_card", Config),
    ?assertEqual(true, maps:get(<<"advertised">>, Res)),
    ?assertEqual(false, maps:get(<<"ok">>, Res)),
    ?assert(maps:get(<<"error">>, Res) =/= <<>>).

%%====================================================================
%% Direction B: Erlang client against the Python server
%%====================================================================

ref_server_jsonrpc_send(Config) -> ref_send(jsonrpc, Config).
ref_server_rest_send(Config) -> ref_send(rest, Config).

ref_send(Binding, Config) ->
    Agent = ref_connect(Binding, Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: from erlang">>),
    ?assertEqual(completed, barrel_a2a_task:state(Task)),
    ?assertEqual(
        <<"from erlang">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Task)))
    ),
    ?assert(barrel_a2a_task:context_id(Task) =/= undefined).

ref_server_jsonrpc_stream(Config) -> ref_stream(jsonrpc, Config).
ref_server_rest_stream(Config) -> ref_stream(rest, Config).

ref_stream(Binding, Config) ->
    Agent = ref_connect(Binding, Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"stream">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    {Events, {done, Final}} = collect_events(RT),
    ?assertEqual(
        [task, status_update, artifact_update, artifact_update, status_update], kinds(Events)
    ),
    ?assertEqual([working, completed], states(Events)),
    [#{<<"artifactUpdate">> := First}, #{<<"artifactUpdate">> := Second}] = [
        E
     || E <- Events, barrel_a2a_event:kind(E) =:= artifact_update
    ],
    ?assertEqual(false, maps:get(<<"append">>, First, false)),
    ?assertEqual(true, maps:get(<<"append">>, Second)),
    ?assertEqual(true, maps:get(<<"lastChunk">>, Second)),
    ?assertEqual(completed, barrel_a2a_task:state(Final)),
    ?assertEqual(<<"part one part two">>, barrel_a2a_remote_task:text(RT)).

ref_server_jsonrpc_multiturn(Config) -> ref_multiturn(jsonrpc, Config).
ref_server_rest_multiturn(Config) -> ref_multiturn(rest, Config).

ref_multiturn(Binding, Config) ->
    Agent = ref_connect(Binding, Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"ask">>),
    ?assertEqual(input_required, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"more?">>, barrel_a2a_message:text(barrel_a2a_task:status_message(Task))),
    Id = barrel_a2a_task:id(Task),
    Ctx = barrel_a2a_task:context_id(Task),
    {ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"second">>, #{
        task_id => Id, context_id => Ctx
    }),
    ?assertEqual(Id, barrel_a2a_task:id(Done)),
    ?assertEqual(completed, barrel_a2a_task:state(Done)),
    ?assertEqual(
        <<"thanks: second">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Done)))
    ).

ref_server_jsonrpc_cancel(Config) -> ref_cancel(jsonrpc, Config).
ref_server_rest_cancel(Config) -> ref_cancel(rest, Config).

ref_cancel(Binding, Config) ->
    Agent = ref_connect(Binding, Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"cancel-me">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    receive
        {a2a_event, RT, #{
            <<"statusUpdate">> := #{<<"status">> := #{<<"state">> := <<"TASK_STATE_WORKING">>}}
        }} ->
            ok
    after 5000 -> ct:fail(no_working_event)
    end,
    {ok, Task} = barrel_a2a_remote_task:cancel(RT),
    ?assertEqual(canceled, barrel_a2a_task:state(Task)),
    {ok, Fetched} = barrel_a2a_client:get_task(Agent, barrel_a2a_task:id(Task)),
    ?assertEqual(canceled, barrel_a2a_task:state(Fetched)).

ref_server_jsonrpc_get(Config) -> ref_get(jsonrpc, Config).
ref_server_rest_get(Config) -> ref_get(rest, Config).

ref_get(Binding, Config) ->
    Agent = ref_connect(Binding, Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: x">>),
    Id = barrel_a2a_task:id(Task),
    {ok, Fetched} = barrel_a2a_client:get_task(Agent, Id),
    ?assertEqual(Id, barrel_a2a_task:id(Fetched)),
    ?assertEqual(completed, barrel_a2a_task:state(Fetched)),
    ?assertEqual(<<"x">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Fetched)))).

ref_server_jsonrpc_direct(Config) -> ref_direct(jsonrpc, Config).
ref_server_rest_direct(Config) -> ref_direct(rest, Config).

ref_direct(Binding, Config) ->
    Agent = ref_connect(Binding, Config),
    {ok, {message, M}} = barrel_a2a_client:send(Agent, <<"direct">>),
    ?assertEqual(<<"direct reply">>, barrel_a2a_message:text(M)),
    ?assertEqual(agent, barrel_a2a_message:role(M)).

%%====================================================================
%% Helpers
%%====================================================================

%% How to launch one reference implementation's client and server.
%% `client' is given the server URL, the binding and the scenario name;
%% `server' is given a port and the string "both".
-type runner() :: #{
    name := atom(),
    client := {file:filename(), [string()]},
    server := {file:filename(), [string()]}
}.

-spec runner(atom()) -> {ok, runner()} | {error, string()}.
runner(python) ->
    case executable("INTEROP_PYTHON") of
        undefined ->
            {error, "INTEROP_PYTHON not set or not executable; run `make interop-python`"};
        Exe ->
            {ok, #{
                name => python,
                client => {Exe, [script("client.py")]},
                server => {Exe, [script("server.py")]}
            }}
    end;
runner(js) ->
    case executable("INTEROP_NODE") of
        undefined ->
            {error, "INTEROP_NODE not set or not executable; run `make interop-js`"};
        Exe ->
            {ok, #{
                name => js,
                client => {Exe, [script("js/client.mjs")]},
                server => {Exe, [script("js/server.mjs")]}
            }}
    end;
%% Go is compiled ahead of time rather than run through `go run', which
%% would rebuild on each of the client invocations.
runner(go) ->
    case os:getenv("INTEROP_GO_BIN") of
        Dir when is_list(Dir), Dir =/= "" ->
            Client = filename:join(Dir, "client"),
            Server = filename:join(Dir, "server"),
            case filelib:is_regular(Client) andalso filelib:is_regular(Server) of
                true -> {ok, #{name => go, client => {Client, []}, server => {Server, []}}};
                false -> {error, "INTEROP_GO_BIN holds no client/server; run `make interop-go`"}
            end;
        _ ->
            {error, "INTEROP_GO_BIN not set; run `make interop-go`"}
    end.

executable(Var) ->
    case os:getenv(Var) of
        Path when is_list(Path), Path =/= "" ->
            case filelib:is_regular(Path) of
                true -> Path;
                false -> undefined
            end;
        _ ->
            undefined
    end.

root_dir() ->
    {ok, Cwd} = file:get_cwd(),
    find_root(Cwd).

find_root(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true ->
            Dir;
        false ->
            case filename:dirname(Dir) of
                Dir -> Dir;
                Parent -> find_root(Parent)
            end
    end.

script(Name) -> filename:join([root_dir(), "test", "interop", Name]).

base_url(Port) -> iolist_to_binary(io_lib:format("http://127.0.0.1:~B", [Port])).

free_port() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    Port.

%% Run client.py for one scenario; returns the JSON steps keyed by
%% `step'. A key that occurs more than once (`event') maps to the list
%% of its objects in order.
run_client(Binding, Scenario, Config) ->
    #{name := Name, client := {Exe, Prefix}} = ?config(runner, Config),
    Url = binary_to_list(barrel_a2a_server:url(?config(server, Config))),
    Args = Prefix ++ [Url, atom_to_list(Binding), Scenario],
    {Status, Lines} = run_exe(Exe, Args),
    ct:log("~p client ~s ~s exit ~p~n~s", [Name, Binding, Scenario, Status, Lines]),
    Steps = parse_steps(Lines),
    case Status of
        0 -> ok;
        _ -> ct:fail({ref_client_failed, Binding, Scenario, Status, Lines})
    end,
    ?assertMatch(#{<<"done">> := _}, Steps),
    Steps.

parse_steps(Lines) ->
    Objects = [
        Obj
     || Line <- string:split(Lines, "\n", all),
        {ok, Obj} <- [decode_step(Line)]
    ],
    lists:foldl(
        fun(#{<<"step">> := Step} = Obj, Acc) ->
            case Step of
                <<"event">> ->
                    maps:update_with(Step, fun(L) -> L ++ [Obj] end, [Obj], Acc);
                _ ->
                    Acc#{Step => Obj}
            end
        end,
        #{},
        Objects
    ).

decode_step([${ | _] = Line) ->
    try json:decode(iolist_to_binary(Line)) of
        #{<<"step">> := _} = Obj -> {ok, Obj};
        _ -> error
    catch
        _:_ -> error
    end;
decode_step(_) ->
    error.

run_exe(Exe, Args) ->
    Port = open_port(
        {spawn_executable, Exe},
        [
            {args, Args},
            {cd, root_dir()},
            exit_status,
            stderr_to_stdout,
            use_stdio,
            binary,
            {line, 65536}
        ]
    ),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, {_, Line}}} ->
            collect(Port, [Line, $\n | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, unicode:characters_to_list(iolist_to_binary(lists:reverse(Acc)))}
    after ?CLIENT_TIMEOUT ->
        kill_port(Port),
        {timeout, unicode:characters_to_list(iolist_to_binary(lists:reverse(Acc)))}
    end.

%% Every reference server serves both bindings and prints `READY <port>'
%% once it is listening; that line is the whole startup contract.
start_ref_server(#{server := {Exe, Prefix}}, Port) ->
    RefPort = open_port(
        {spawn_executable, Exe},
        [
            {args, Prefix ++ [integer_to_list(Port), "both"]},
            {cd, root_dir()},
            exit_status,
            stderr_to_stdout,
            use_stdio,
            binary,
            {line, 65536}
        ]
    ),
    wait_ready(RefPort, []),
    RefPort.

wait_ready(RefPort, Acc) ->
    receive
        {RefPort, {data, {_, <<"READY ", _/binary>>}}} ->
            %% Keep draining the server's output so the port buffer
            %% never fills up.
            spawn_link(fun() -> drain(RefPort) end),
            ok;
        {RefPort, {data, {_, Line}}} ->
            wait_ready(RefPort, [Line | Acc]);
        {RefPort, {exit_status, Status}} ->
            ct:fail({ref_server_exited, Status, lists:reverse(Acc)})
    after ?READY_TIMEOUT ->
        kill_port(RefPort),
        ct:fail({ref_server_not_ready, lists:reverse(Acc)})
    end.

drain(RefPort) ->
    receive
        {RefPort, {data, {_, Line}}} ->
            ct:log("ref server: ~s", [Line]),
            drain(RefPort);
        {RefPort, {exit_status, _}} ->
            ok;
        stop ->
            ok
    end.

stop_ref_server(RefPort) ->
    kill_port(RefPort).

kill_port(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            _ = os:cmd("kill -9 " ++ integer_to_list(OsPid));
        _ ->
            ok
    end,
    try
        port_close(Port)
    catch
        _:_ -> ok
    end,
    ok.

safe_stop(Server) ->
    try
        barrel_a2a_server:stop(Server)
    catch
        _:_ -> ok
    end.

ref_connect(Binding, Config) ->
    Url = ?config(ref_url, Config),
    {ok, Agent} = barrel_a2a_client:connect(Url, #{prefer => [Binding], timeout => 15000}),
    Expected =
        case Binding of
            jsonrpc -> <<"JSONRPC">>;
            rest -> <<"HTTP+JSON">>
        end,
    ?assertEqual(Expected, barrel_a2a_client:binding(Agent)),
    Agent.

collect_events(RT) -> collect_events(RT, []).

collect_events(RT, Acc) ->
    receive
        {a2a_event, RT, Ev} -> collect_events(RT, [Ev | Acc]);
        {a2a_done, RT, Final} -> {lists:reverse(Acc), {done, Final}};
        {a2a_error, RT, E} -> {lists:reverse(Acc), {error, E}}
    after 10000 -> {lists:reverse(Acc), timeout}
    end.

kinds(Events) -> [barrel_a2a_event:kind(E) || E <- Events].

states(Events) ->
    [
        S
     || #{<<"statusUpdate">> := #{<<"status">> := #{<<"state">> := W}}} <- Events,
        {ok, S} <- [barrel_a2a_task_state:from_wire(W)]
    ].
