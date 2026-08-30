%%%-------------------------------------------------------------------
%%% @doc Receiving side of push notifications (specification 4.3.3).
%%%
%%% A client that registered a push configuration gets a POST per
%%% task event. `receive_notification/3' checks the notification
%%% token and `Authorization' header, decodes the `StreamResponse'
%%% payload and optionally filters by task id. `ack/0' is the reply
%%% to send back on success.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_webhook).

-export([receive_notification/3, ack/0]).

-type opts() :: #{
    token => binary(),
    authorization => binary() | fun((binary() | undefined) -> boolean()),
    task_ids => [binary()],
    validate_schema => boolean()
}.

-export_type([opts/0]).

-spec receive_notification([{binary(), binary()}], binary(), opts()) ->
    {ok, barrel_a2a:stream_response()} | {error, unauthenticated | unexpected_task | bad_payload}.
receive_notification(Headers0, Body, Opts) ->
    Headers = [{string:lowercase(K), V} || {K, V} <- Headers0],
    case authenticate(Headers, Opts) of
        ok ->
            case decode(Body, Opts) of
                {ok, Event} -> check_task(Event, Opts);
                Error -> Error
            end;
        Error ->
            Error
    end.

%% @doc The response acknowledging a notification.
-spec ack() -> {200, [{binary(), binary()}], binary()}.
ack() ->
    {200, [{<<"content-length">>, <<"0">>}], <<>>}.

authenticate(Headers, Opts) ->
    case token_ok(Headers, Opts) andalso authorization_ok(Headers, Opts) of
        true -> ok;
        false -> {error, unauthenticated}
    end.

token_ok(Headers, #{token := Expected}) ->
    header(<<"x-a2a-notification-token">>, Headers) =:= Expected;
token_ok(_, _) ->
    true.

authorization_ok(Headers, #{authorization := Check}) when is_function(Check, 1) ->
    case Check(header(<<"authorization">>, Headers)) of
        true -> true;
        _ -> false
    end;
authorization_ok(Headers, #{authorization := Expected}) when is_binary(Expected) ->
    header(<<"authorization">>, Headers) =:= Expected;
authorization_ok(_, _) ->
    true.

decode(Body, Opts) ->
    case barrel_a2a_json:decode(Body) of
        {ok, Event} when is_map(Event) ->
            case barrel_a2a_event:kind(Event) of
                unknown -> {error, bad_payload};
                _ -> validate(Event, Opts)
            end;
        _ ->
            {error, bad_payload}
    end.

validate(Event, #{validate_schema := true}) ->
    case barrel_a2a_schema:validate(<<"StreamResponse">>, Event) of
        ok -> {ok, Event};
        {error, _} -> {error, bad_payload}
    end;
validate(Event, _) ->
    {ok, Event}.

check_task(Event, #{task_ids := Ids}) ->
    case lists:member(barrel_a2a_event:task_id(Event), Ids) of
        true -> {ok, Event};
        false -> {error, unexpected_task}
    end;
check_task(Event, _) ->
    {ok, Event}.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.
