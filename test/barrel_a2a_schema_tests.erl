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
