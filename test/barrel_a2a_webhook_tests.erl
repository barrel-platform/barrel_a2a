-module(barrel_a2a_webhook_tests).

-include_lib("eunit/include/eunit.hrl").

event() ->
    barrel_a2a_event:status_update(<<"task-1">>, <<"ctx">>, #{
        <<"state">> => <<"TASK_STATE_WORKING">>
    }).

body() ->
    barrel_a2a_json:encode(event()).

headers() ->
    [
        {<<"Content-Type">>, <<"application/a2a+json">>},
        {<<"X-A2A-Notification-Token">>, <<"tok">>},
        {<<"Authorization">>, <<"Bearer abc">>}
    ].

ok_path_test() ->
    Opts = #{token => <<"tok">>, authorization => <<"Bearer abc">>, task_ids => [<<"task-1">>]},
    ?assertEqual({ok, event()}, barrel_a2a_webhook:receive_notification(headers(), body(), Opts)).

no_checks_test() ->
    ?assertEqual({ok, event()}, barrel_a2a_webhook:receive_notification([], body(), #{})).

token_mismatch_test() ->
    ?assertEqual(
        {error, unauthenticated},
        barrel_a2a_webhook:receive_notification(headers(), body(), #{token => <<"other">>})
    ),
    ?assertEqual(
        {error, unauthenticated},
        barrel_a2a_webhook:receive_notification([], body(), #{token => <<"tok">>})
    ).

authorization_check_test() ->
    ?assertEqual(
        {error, unauthenticated},
        barrel_a2a_webhook:receive_notification(headers(), body(), #{
            authorization => <<"Bearer nope">>
        })
    ),
    Check = fun(V) -> V =:= <<"Bearer abc">> end,
    ?assertEqual(
        {ok, event()},
        barrel_a2a_webhook:receive_notification(headers(), body(), #{authorization => Check})
    ),
    ?assertEqual(
        {error, unauthenticated},
        barrel_a2a_webhook:receive_notification([], body(), #{authorization => Check})
    ).

task_id_filter_test() ->
    ?assertEqual(
        {error, unexpected_task},
        barrel_a2a_webhook:receive_notification(headers(), body(), #{task_ids => [<<"x">>]})
    ).

bad_json_test() ->
    ?assertEqual(
        {error, bad_payload}, barrel_a2a_webhook:receive_notification(headers(), <<"{">>, #{})
    ),
    ?assertEqual(
        {error, bad_payload}, barrel_a2a_webhook:receive_notification(headers(), <<"[1]">>, #{})
    ),
    ?assertEqual(
        {error, bad_payload},
        barrel_a2a_webhook:receive_notification(headers(), <<"{\"foo\":1}">>, #{})
    ).

schema_validation_test() ->
    Bad = barrel_a2a_json:encode(#{<<"statusUpdate">> => #{<<"taskId">> => 1}}),
    ?assertEqual(
        {error, bad_payload},
        barrel_a2a_webhook:receive_notification(headers(), Bad, #{validate_schema => true})
    ),
    ?assertEqual(
        {ok, event()},
        barrel_a2a_webhook:receive_notification(headers(), body(), #{validate_schema => true})
    ).

ack_test() ->
    ?assertMatch({200, [_ | _], <<>>}, barrel_a2a_webhook:ack()).
