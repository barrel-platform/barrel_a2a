%%%-------------------------------------------------------------------
%%% @doc Python interop suite: the wire format between barrel_a2a and
%%% the official A2A Python SDK (`a2a-sdk'), in both directions and
%%% over both HTTP bindings.
%%%
%%% Direction A runs `test/interop/client.py' against an Erlang server
%%% hosting `barrel_a2a_test_agent'; the script prints one JSON line
%%% per step and the cases assert on those. Direction B starts
%%% `test/interop/server.py' (an SDK `AgentExecutor' mirroring the test
%%% agent) and drives it with `barrel_a2a_client'.
%%%
%%% Every case skips when `INTEROP_PYTHON' is unset or does not point
%%% at an interpreter, so plain `rebar3 ct' never needs Python. Run via:
%%%
%%%   make interop-setup        % once, creates test/interop/.venv
%%%   make interop-python
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_python_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    python_client_jsonrpc_card/1,
    python_client_jsonrpc_send/1,
    python_client_jsonrpc_stream/1,
    python_client_jsonrpc_multiturn/1,
    python_client_jsonrpc_cancel/1,
    python_client_jsonrpc_direct/1,
    python_client_jsonrpc_get/1,
    python_client_rest_card/1,
    python_client_rest_send/1,
    python_client_rest_stream/1,
    python_client_rest_multiturn/1,
    python_client_rest_cancel/1,
    python_client_rest_direct/1,
    python_client_rest_get/1,
    erlang_client_against_python_server_jsonrpc_send/1,
    erlang_client_against_python_server_jsonrpc_stream/1,
    erlang_client_against_python_server_jsonrpc_multiturn/1,
    erlang_client_against_python_server_jsonrpc_cancel/1,
    erlang_client_against_python_server_jsonrpc_get/1,
    erlang_client_against_python_server_jsonrpc_direct/1,
    erlang_client_against_python_server_rest_send/1,
    erlang_client_against_python_server_rest_stream/1,
    erlang_client_against_python_server_rest_multiturn/1,
    erlang_client_against_python_server_rest_cancel/1,
    erlang_client_against_python_server_rest_get/1,
    erlang_client_against_python_server_rest_direct/1
]).

-define(CLIENT_TIMEOUT, 60000).
-define(READY_TIMEOUT, 20000).

all() ->
    [
        python_client_jsonrpc_card,
        python_client_jsonrpc_send,
        python_client_jsonrpc_stream,
        python_client_jsonrpc_multiturn,
        python_client_jsonrpc_cancel,
        python_client_jsonrpc_direct,
        python_client_jsonrpc_get,
        python_client_rest_card,
        python_client_rest_send,
        python_client_rest_stream,
        python_client_rest_multiturn,
        python_client_rest_cancel,
        python_client_rest_direct,
        python_client_rest_get,
        erlang_client_against_python_server_jsonrpc_send,
        erlang_client_against_python_server_jsonrpc_stream,
        erlang_client_against_python_server_jsonrpc_multiturn,
        erlang_client_against_python_server_jsonrpc_cancel,
        erlang_client_against_python_server_jsonrpc_get,
        erlang_client_against_python_server_jsonrpc_direct,
        erlang_client_against_python_server_rest_send,
        erlang_client_against_python_server_rest_stream,
        erlang_client_against_python_server_rest_multiturn,
        erlang_client_against_python_server_rest_cancel,
        erlang_client_against_python_server_rest_get,
        erlang_client_against_python_server_rest_direct
    ].

init_per_suite(Config) ->
    case interpreter() of
        undefined ->
            {skip, "INTEROP_PYTHON not set or not executable; run `make interop-python`"};
        Python ->
            {ok, _} = application:ensure_all_started(barrel_a2a),
            [{python, Python} | Config]
    end.

end_per_suite(_Config) ->
    ok.

%% Direction A cases get an Erlang server; direction B cases get a
%% Python one. The case name carries the binding.
init_per_testcase(TC, Config) ->
    case atom_to_list(TC) of
        "python_client_" ++ _ ->
            {ok, Server} = barrel_a2a_server:start(barrel_a2a_test_agent:card(), #{
                handler => barrel_a2a_test_agent,
                http => #{port => 0},
                blocking_timeout => 10000
            }),
            [{server, Server} | Config];
        "erlang_client_against_python_server_" ++ _ ->
            Port = free_port(),
            PyPort = start_python_server(?config(python, Config), Port),
            [{py_port, PyPort}, {py_url, base_url(Port)} | Config]
    end.

end_per_testcase(_TC, Config) ->
    case ?config(server, Config) of
        undefined -> ok;
        Server -> safe_stop(Server)
    end,
    case ?config(py_port, Config) of
        undefined -> ok;
        PyPort -> stop_python_server(PyPort)
    end,
    ok.

%%====================================================================
%% Direction A: Python client against the Erlang server
%%====================================================================

python_client_jsonrpc_card(Config) -> card_case(jsonrpc, Config).
python_client_rest_card(Config) -> card_case(rest, Config).

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

python_client_jsonrpc_send(Config) -> send_case(jsonrpc, Config).
python_client_rest_send(Config) -> send_case(rest, Config).

send_case(Binding, Config) ->
    #{<<"send">> := Send} = run_client(Binding, "send", Config),
    ?assertEqual([<<"task">>], maps:get(<<"kinds">>, Send)),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Send)),
    ?assertEqual(<<"from python">>, maps:get(<<"artifact">>, Send)),
    ?assert(is_binary(maps:get(<<"task_id">>, Send))),
    ?assert(is_binary(maps:get(<<"context_id">>, Send))).

python_client_jsonrpc_stream(Config) -> stream_case(jsonrpc, Config).
python_client_rest_stream(Config) -> stream_case(rest, Config).

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

python_client_jsonrpc_multiturn(Config) -> multiturn_case(jsonrpc, Config).
python_client_rest_multiturn(Config) -> multiturn_case(rest, Config).

multiturn_case(Binding, Config) ->
    #{<<"ask">> := Ask, <<"multiturn">> := Done} = run_client(Binding, "multiturn", Config),
    ?assertEqual(<<"TASK_STATE_INPUT_REQUIRED">>, maps:get(<<"state">>, Ask)),
    ?assertEqual(<<"more?">>, maps:get(<<"prompt">>, Ask)),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Done)),
    ?assertEqual(<<"thanks: second">>, maps:get(<<"artifact">>, Done)),
    ?assertEqual(true, maps:get(<<"same_task">>, Done)),
    ?assertEqual(3, maps:get(<<"history">>, Done)).

python_client_jsonrpc_cancel(Config) -> cancel_case(jsonrpc, Config).
python_client_rest_cancel(Config) -> cancel_case(rest, Config).

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

python_client_jsonrpc_direct(Config) -> direct_case(jsonrpc, Config).
python_client_rest_direct(Config) -> direct_case(rest, Config).

direct_case(Binding, Config) ->
    #{<<"direct">> := Direct} = run_client(Binding, "direct", Config),
    ?assertEqual([<<"message">>], maps:get(<<"kinds">>, Direct)),
    ?assertEqual(<<"direct reply">>, maps:get(<<"text">>, Direct)),
    ?assertEqual(<<"ROLE_AGENT">>, maps:get(<<"role">>, Direct)).

python_client_jsonrpc_get(Config) -> get_case(jsonrpc, Config).
python_client_rest_get(Config) -> get_case(rest, Config).

get_case(Binding, Config) ->
    #{<<"get">> := Get} = run_client(Binding, "get", Config),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, maps:get(<<"state">>, Get)),
    ?assertEqual(true, maps:get(<<"same_id">>, Get)),
    ?assertEqual(<<"x">>, maps:get(<<"artifact">>, Get)).

%%====================================================================
%% Direction B: Erlang client against the Python server
%%====================================================================

erlang_client_against_python_server_jsonrpc_send(Config) -> py_send(jsonrpc, Config).
erlang_client_against_python_server_rest_send(Config) -> py_send(rest, Config).

py_send(Binding, Config) ->
    Agent = py_connect(Binding, Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: from erlang">>),
    ?assertEqual(completed, barrel_a2a_task:state(Task)),
    ?assertEqual(
        <<"from erlang">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Task)))
    ),
    ?assert(barrel_a2a_task:context_id(Task) =/= undefined).

erlang_client_against_python_server_jsonrpc_stream(Config) -> py_stream(jsonrpc, Config).
erlang_client_against_python_server_rest_stream(Config) -> py_stream(rest, Config).

py_stream(Binding, Config) ->
    Agent = py_connect(Binding, Config),
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

erlang_client_against_python_server_jsonrpc_multiturn(Config) -> py_multiturn(jsonrpc, Config).
erlang_client_against_python_server_rest_multiturn(Config) -> py_multiturn(rest, Config).

py_multiturn(Binding, Config) ->
    Agent = py_connect(Binding, Config),
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

erlang_client_against_python_server_jsonrpc_cancel(Config) -> py_cancel(jsonrpc, Config).
erlang_client_against_python_server_rest_cancel(Config) -> py_cancel(rest, Config).

py_cancel(Binding, Config) ->
    Agent = py_connect(Binding, Config),
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

erlang_client_against_python_server_jsonrpc_get(Config) -> py_get(jsonrpc, Config).
erlang_client_against_python_server_rest_get(Config) -> py_get(rest, Config).

py_get(Binding, Config) ->
    Agent = py_connect(Binding, Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: x">>),
    Id = barrel_a2a_task:id(Task),
    {ok, Fetched} = barrel_a2a_client:get_task(Agent, Id),
    ?assertEqual(Id, barrel_a2a_task:id(Fetched)),
    ?assertEqual(completed, barrel_a2a_task:state(Fetched)),
    ?assertEqual(<<"x">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Fetched)))).

erlang_client_against_python_server_jsonrpc_direct(Config) -> py_direct(jsonrpc, Config).
erlang_client_against_python_server_rest_direct(Config) -> py_direct(rest, Config).

py_direct(Binding, Config) ->
    Agent = py_connect(Binding, Config),
    {ok, {message, M}} = barrel_a2a_client:send(Agent, <<"direct">>),
    ?assertEqual(<<"direct reply">>, barrel_a2a_message:text(M)),
    ?assertEqual(agent, barrel_a2a_message:role(M)).

%%====================================================================
%% Helpers
%%====================================================================

interpreter() ->
    case os:getenv("INTEROP_PYTHON") of
        false ->
            undefined;
        "" ->
            undefined;
        Path ->
            case filelib:is_regular(Path) of
                true -> Path;
                false -> undefined
            end
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
    Url = binary_to_list(barrel_a2a_server:url(?config(server, Config))),
    Args = [script("client.py"), Url, atom_to_list(Binding), Scenario],
    {Status, Lines} = run_python(?config(python, Config), Args),
    ct:log("client.py ~s ~s exit ~p~n~s", [Binding, Scenario, Status, Lines]),
    Steps = parse_steps(Lines),
    case Status of
        0 -> ok;
        _ -> ct:fail({python_client_failed, Binding, Scenario, Status, Lines})
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

run_python(Python, Args) ->
    Port = open_port(
        {spawn_executable, Python},
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

%% server.py serves both bindings; wait for its READY line.
start_python_server(Python, Port) ->
    PyPort = open_port(
        {spawn_executable, Python},
        [
            {args, [script("server.py"), integer_to_list(Port), "both"]},
            {cd, root_dir()},
            exit_status,
            stderr_to_stdout,
            use_stdio,
            binary,
            {line, 65536}
        ]
    ),
    wait_ready(PyPort, []),
    PyPort.

wait_ready(PyPort, Acc) ->
    receive
        {PyPort, {data, {_, <<"READY ", _/binary>>}}} ->
            %% Keep draining the server's output so the port buffer
            %% never fills up.
            spawn_link(fun() -> drain(PyPort) end),
            ok;
        {PyPort, {data, {_, Line}}} ->
            wait_ready(PyPort, [Line | Acc]);
        {PyPort, {exit_status, Status}} ->
            ct:fail({python_server_exited, Status, lists:reverse(Acc)})
    after ?READY_TIMEOUT ->
        kill_port(PyPort),
        ct:fail({python_server_not_ready, lists:reverse(Acc)})
    end.

drain(PyPort) ->
    receive
        {PyPort, {data, {_, Line}}} ->
            ct:log("server.py: ~s", [Line]),
            drain(PyPort);
        {PyPort, {exit_status, _}} ->
            ok;
        stop ->
            ok
    end.

stop_python_server(PyPort) ->
    kill_port(PyPort).

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

py_connect(Binding, Config) ->
    Url = ?config(py_url, Config),
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
