%%%-------------------------------------------------------------------
%%% @doc Follow a long-running task as it streams.
%%%
%%% `streaming_client:run(<<"http://localhost:8080">>)' starts a task
%%% on the streaming_server example, prints every event as it
%%% arrives, answers an input request, and prints the final artifact.
%%% `run/0' starts the server itself on a free port.
%%% @end
%%%-------------------------------------------------------------------
-module(streaming_client).

-export([run/0, run/1, run/2]).

run() ->
    {ok, Server} = streaming_server:start(0),
    try
        run(barrel_a2a_server:url(Server))
    after
        streaming_server:stop(Server)
    end.

run(Url) -> run(Url, <<"Review this repository please">>).

run(Url, Text) ->
    {ok, Agent} = barrel_a2a_client:connect(Url),
    {ok, RT} = barrel_a2a_client:start(Agent, Text),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    loop(RT).

loop(RT) ->
    receive
        {a2a_event, RT, Event} ->
            print(Event),
            loop(RT);
        {a2a_done, RT, {message, Message}} ->
            io:format("reply: ~s~n", [barrel_a2a_message:text(Message)]),
            {ok, barrel_a2a_message:text(Message)};
        {a2a_done, RT, Task} ->
            case barrel_a2a_task:state(Task) of
                input_required ->
                    io:format("agent asks: ~s~n", [
                        barrel_a2a_message:text(barrel_a2a_task:status_message(Task))
                    ]),
                    ok = barrel_a2a_remote_task:send(RT, <<"Here is a longer request for you">>),
                    loop(RT);
                State ->
                    io:format("task ~p~n~s", [State, barrel_a2a_remote_task:text(RT)]),
                    {ok, barrel_a2a_remote_task:text(RT)}
            end;
        {a2a_error, RT, Error} ->
            io:format("error: ~p~n", [Error]),
            {error, Error}
    after 30000 ->
        {error, timeout}
    end.

print(#{<<"task">> := Task}) ->
    io:format("task ~s ~p~n", [barrel_a2a_task:id(Task), barrel_a2a_task:state(Task)]);
print(#{<<"statusUpdate">> := #{<<"status">> := Status}}) ->
    Msg =
        case maps:get(<<"message">>, Status, undefined) of
            undefined -> <<>>;
            M -> barrel_a2a_message:text(M)
        end,
    io:format("status ~s ~s~n", [maps:get(<<"state">>, Status), Msg]);
print(#{<<"artifactUpdate">> := #{<<"artifact">> := Artifact}}) ->
    io:format("chunk: ~s", [barrel_a2a_artifact:text(Artifact)]);
print(Other) ->
    io:format("event: ~p~n", [Other]).
