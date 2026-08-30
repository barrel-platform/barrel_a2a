-module(barrel_a2a_schema_tests).

-include_lib("eunit/include/eunit.hrl").

minimal_message() ->
    #{
        <<"messageId">> => <<"msg-1">>,
        <<"role">> => <<"ROLE_USER">>,
        <<"parts">> => [#{<<"text">> => <<"hi">>}]
    }.

load_is_idempotent_test() ->
    ?assertEqual(ok, barrel_a2a_schema:load()),
    ?assertEqual(ok, barrel_a2a_schema:load()),
    ?assert(lists:member(<<"Message">>, barrel_a2a_schema:types())).

minimal_message_passes_test() ->
    ?assertEqual(ok, barrel_a2a_schema:validate(<<"Message">>, minimal_message())).

%% The bundle carries no `required' lists: presence is the caller's
%% business, shape is the schema's.
missing_role_still_passes_test() ->
    ?assertEqual(
        ok,
        barrel_a2a_schema:validate(<<"Message">>, maps:remove(<<"role">>, minimal_message()))
    ).

wrong_type_for_parts_fails_test() ->
    ?assertMatch(
        {error, [_ | _]},
        barrel_a2a_schema:validate(<<"Message">>, (minimal_message())#{
            <<"parts">> => <<"not a list">>
        })
    ).

unknown_property_fails_test() ->
    ?assertMatch(
        {error, [_ | _]},
        barrel_a2a_schema:validate(<<"Message">>, (minimal_message())#{
            <<"bogus">> => 1
        })
    ).

snake_case_alias_is_accepted_test() ->
    ?assertEqual(
        ok,
        barrel_a2a_schema:validate(<<"Message">>, (minimal_message())#{
            <<"context_id">> => <<"ctx-1">>
        })
    ).

unknown_type_test() ->
    ?assertEqual(
        {error, [{[], {unknown_type, <<"Nope">>}}]},
        barrel_a2a_schema:validate(<<"Nope">>, #{})
    ).

%% Forward compatibility: a request written against a later minor
%% version carries fields this bundle does not declare. `lenient'
%% ignores them, `strict' does not.
lenient_ignores_unknown_fields_test() ->
    Msg = (minimal_message())#{<<"fromTheFuture">> => 1},
    ?assertEqual(ok, barrel_a2a_schema:validate(<<"Message">>, Msg, lenient)),
    ?assertMatch({error, [_ | _]}, barrel_a2a_schema:validate(<<"Message">>, Msg, strict)).

%% Relaxing must not lose any other check, at any depth.
lenient_still_checks_types_test() ->
    Shallow = (minimal_message())#{<<"messageId">> => 42},
    Nested = (minimal_message())#{<<"parts">> => [#{<<"text">> => 7}]},
    ?assertMatch(
        {error, [{[<<"messageId">>], _}]},
        barrel_a2a_schema:validate(<<"Message">>, Shallow, lenient)
    ),
    ?assertMatch(
        {error, [{[<<"parts">>, 0, <<"text">>], _}]},
        barrel_a2a_schema:validate(<<"Message">>, Nested, lenient)
    ).

%% An unknown field nested inside a declared object is ignored too.
lenient_ignores_nested_unknown_fields_test() ->
    Msg = (minimal_message())#{
        <<"parts">> => [#{<<"text">> => <<"hi">>, <<"fromTheFuture">> => 1}]
    },
    ?assertEqual(ok, barrel_a2a_schema:validate(<<"Message">>, Msg, lenient)),
    ?assertMatch({error, [_ | _]}, barrel_a2a_schema:validate(<<"Message">>, Msg, strict)).

request_and_reply_types_test() ->
    Types = barrel_a2a_schema:types(),
    Ops = [
        send_message,
        send_streaming_message,
        get_task,
        list_tasks,
        cancel_task,
        subscribe_to_task,
        create_push_config,
        get_push_config,
        delete_push_config,
        list_push_configs,
        get_extended_agent_card
    ],
    lists:foreach(
        fun(Op) ->
            ?assert(lists:member(barrel_a2a_schema:request_type(Op), Types)),
            ?assert(lists:member(barrel_a2a_schema:reply_type(Op), Types))
        end,
        Ops
    ).
