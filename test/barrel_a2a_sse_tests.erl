-module(barrel_a2a_sse_tests).

-include_lib("eunit/include/eunit.hrl").

parse(Bin) ->
    {Events, P} = barrel_a2a_sse:feed(Bin, barrel_a2a_sse:new()),
    Events ++ barrel_a2a_sse:finish(P).

encode_data_test() ->
    ?assertEqual(
        <<"data: {\"a\":1}\n\n">>, iolist_to_binary(barrel_a2a_sse:encode(<<"{\"a\":1}">>))
    ).

encode_event_test() ->
    Event = #{data => <<"x">>, event => <<"task">>, id => <<"7">>, retry => 3000},
    ?assertEqual(
        <<"id: 7\nevent: task\nretry: 3000\ndata: x\n\n">>,
        iolist_to_binary(barrel_a2a_sse:encode(Event))
    ).

encode_round_trip_test() ->
    Event = #{data => <<"{\"a\":1}">>, event => <<"task">>, id => <<"7">>, retry => 3000},
    ?assertEqual([Event], parse(iolist_to_binary(barrel_a2a_sse:encode(Event)))).

multi_line_data_test() ->
    Encoded = iolist_to_binary(barrel_a2a_sse:encode(<<"a\nb\r\nc">>)),
    ?assertEqual(<<"data: a\ndata: b\ndata: c\n\n">>, Encoded),
    ?assertEqual([#{data => <<"a\nb\nc">>}], parse(Encoded)).

comment_test() ->
    ?assertEqual(<<":ping\n\n">>, iolist_to_binary(barrel_a2a_sse:comment(<<"ping">>))),
    ?assertEqual(<<":a b\n\n">>, iolist_to_binary(barrel_a2a_sse:comment(<<"a\nb">>))).

comment_lines_ignored_test() ->
    ?assertEqual(
        [#{data => <<"x">>}],
        parse(<<": keep-alive\n\ndata: x\n: another\n\n">>)
    ).

crlf_and_cr_endings_test() ->
    ?assertEqual([#{data => <<"a\nb">>}], parse(<<"data: a\r\ndata: b\r\n\r\n">>)),
    ?assertEqual([#{data => <<"a\nb">>}], parse(<<"data: a\rdata: b\r\r">>)).

leading_space_stripped_once_test() ->
    ?assertEqual([#{data => <<" x">>}], parse(<<"data:  x\n\n">>)),
    ?assertEqual([#{data => <<"x">>}], parse(<<"data:x\n\n">>)).

unknown_field_ignored_test() ->
    ?assertEqual([#{data => <<"x">>}], parse(<<"foo: bar\ndata: x\n\n">>)).

stream() ->
    <<
        "event: one\r\ndata: 1\r\n\r\n",
        ": comment\n",
        "id: 42\ndata: two\ndata: lines\n\n",
        "retry: 10\rdata: 3\r\r"
    >>.

expected() ->
    [
        #{data => <<"1">>, event => <<"one">>},
        #{data => <<"two\nlines">>, id => <<"42">>},
        #{data => <<"3">>, id => <<"42">>, retry => 10}
    ].

split_at_every_byte_test() ->
    Stream = stream(),
    ?assertEqual(expected(), parse(Stream)),
    lists:foreach(
        fun(I) ->
            <<Head:I/binary, Tail/binary>> = Stream,
            {E1, P1} = barrel_a2a_sse:feed(Head, barrel_a2a_sse:new()),
            {E2, P2} = barrel_a2a_sse:feed(Tail, P1),
            ?assertEqual({I, expected()}, {I, E1 ++ E2 ++ barrel_a2a_sse:finish(P2)})
        end,
        lists:seq(0, byte_size(Stream))
    ).

one_byte_at_a_time_test() ->
    {Events, P} = lists:foldl(
        fun(C, {Acc, P0}) ->
            {E, P1} = barrel_a2a_sse:feed(<<C>>, P0),
            {Acc ++ E, P1}
        end,
        {[], barrel_a2a_sse:new()},
        binary_to_list(stream())
    ),
    ?assertEqual(expected(), Events ++ barrel_a2a_sse:finish(P)).

crlf_split_across_chunks_test() ->
    {[], P1} = barrel_a2a_sse:feed(<<"data: a\r">>, barrel_a2a_sse:new()),
    {[], P2} = barrel_a2a_sse:feed(<<"\ndata: b\r">>, P1),
    {[Event], P3} = barrel_a2a_sse:feed(<<"\n\r\n">>, P2),
    ?assertEqual(#{data => <<"a\nb">>}, Event),
    ?assertEqual([], barrel_a2a_sse:finish(P3)).

cr_then_lf_is_one_break_not_two_test() ->
    %% "data: a\r" + "\n\n" is one event; a CR+LF must not be read as
    %% two line ends (which would dispatch before the real blank line).
    {[], P1} = barrel_a2a_sse:feed(<<"data: a\r">>, barrel_a2a_sse:new()),
    {[], P2} = barrel_a2a_sse:feed(<<"\n">>, P1),
    {[#{data := <<"a">>}], _} = barrel_a2a_sse:feed(<<"\n">>, P2).

id_without_data_test() ->
    {Events, P} = barrel_a2a_sse:feed(<<"id: 9\n\n">>, barrel_a2a_sse:new()),
    ?assertEqual([], Events),
    ?assertEqual(<<"9">>, barrel_a2a_sse:last_event_id(P)),
    {[#{data := <<"x">>, id := <<"9">>}], _} = barrel_a2a_sse:feed(<<"data: x\n\n">>, P).

id_with_nul_ignored_test() ->
    {[], P} = barrel_a2a_sse:feed(<<"id: a", 0, "b\n\n">>, barrel_a2a_sse:new()),
    ?assertEqual(undefined, barrel_a2a_sse:last_event_id(P)).

retry_non_digits_ignored_test() ->
    ?assertEqual([#{data => <<"x">>}], parse(<<"retry: 12ab\ndata: x\n\n">>)),
    ?assertEqual([#{data => <<"x">>}], parse(<<"retry:\ndata: x\n\n">>)),
    ?assertEqual([#{data => <<"x">>, retry => 500}], parse(<<"retry: 500\ndata: x\n\n">>)).

empty_event_name_omitted_test() ->
    ?assertEqual([#{data => <<"x">>}], parse(<<"event:\ndata: x\n\n">>)).

finish_flushes_unterminated_event_test() ->
    {[], P} = barrel_a2a_sse:feed(<<"data: tail">>, barrel_a2a_sse:new()),
    ?assertEqual([#{data => <<"tail">>}], barrel_a2a_sse:finish(P)),
    {[], P2} = barrel_a2a_sse:feed(<<"id: 1">>, barrel_a2a_sse:new()),
    ?assertEqual([], barrel_a2a_sse:finish(P2)).

event_too_large_partial_line_test() ->
    P = barrel_a2a_sse:new(#{max_event_bytes => 16}),
    ?assertEqual({error, event_too_large}, barrel_a2a_sse:feed(binary:copy(<<"x">>, 17), P)).

event_too_large_data_test() ->
    P = barrel_a2a_sse:new(#{max_event_bytes => 16}),
    {[], P1} = barrel_a2a_sse:feed(<<"data: 12345678\n">>, P),
    ?assertEqual({error, event_too_large}, barrel_a2a_sse:feed(<<"data: 12345678\n">>, P1)),
    %% Below the limit, the same shape parses.
    {[#{data := <<"12345678">>}], _} = barrel_a2a_sse:feed(<<"\n">>, P1).
