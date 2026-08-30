%%%-------------------------------------------------------------------
%%% @doc A long-running agent that streams progress and artifact
%%% chunks while it works, and asks for input when the request is
%%% too short.
%%%
%%% `streaming_server:start(8080).' then use streaming_client.
%%% @end
%%%-------------------------------------------------------------------
-module(streaming_server).

-behaviour(barrel_a2a_handler).

-export([start/0, start/1, stop/1, card/0]).
-export([handle_message/2, handle_cancel/1]).

card() ->
    barrel_a2a_agent_card:new(#{
        name => <<"Streaming Reviewer">>,
        description => <<"Reviews text in several steps and streams its findings">>,
        version => <<"1.0.0">>,
        skills => [
            #{
                id => <<"code-review">>,
                name => <<"Code review">>,
                description => <<"Reviews the given text and streams comments">>,
                tags => [<<"review">>, <<"demo">>]
            }
        ]
    }).

start() -> start(8080).

start(Port) ->
    barrel_a2a_server:start(card(), #{handler => ?MODULE, http => #{port => Port}}).

stop(Server) -> barrel_a2a_server:stop(Server).

handle_message(Ctx, Message) ->
    Text = barrel_a2a_message:text(Message),
    case {barrel_a2a_ctx:is_follow_up(Ctx), byte_size(Text) < 10} of
        {false, true} ->
            %% Not enough to work with: pause the task until the client
            %% sends more. The next message re-enters here with
            %% `is_follow_up(Ctx)' true.
            {input_required, <<"Please give me at least ten characters to review.">>};
        _ ->
            review(Ctx, Text)
    end.

review(Ctx, Text) ->
    ok = barrel_a2a_ctx:status(Ctx, working, #{message => <<"Reading the input">>}),
    Words = binary:split(Text, <<" ">>, [global]),
    Total = length(Words),
    lists:foldl(
        fun(Word, N) ->
            case barrel_a2a_ctx:cancelled(Ctx) of
                true ->
                    throw(cancelled);
                false ->
                    timer:sleep(200),
                    Comment = io_lib:format("~b/~b: ~s looks fine~n", [N, Total, Word]),
                    ok = barrel_a2a_ctx:artifact(Ctx, iolist_to_binary(Comment), #{
                        artifact_id => <<"review">>,
                        name => <<"review.txt">>,
                        append => N > 1,
                        last_chunk => N =:= Total
                    }),
                    N + 1
            end
        end,
        1,
        Words
    ),
    ok = barrel_a2a_ctx:status(Ctx, working, #{message => <<"Done">>}),
    ok.

handle_cancel(Ctx) ->
    io:format("task ~s canceled by the client~n", [barrel_a2a_ctx:task_id(Ctx)]),
    ok.
