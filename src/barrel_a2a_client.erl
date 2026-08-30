%%%-------------------------------------------------------------------
%%% @doc Talk to a remote agent.
%%%
%%% ```
%%% {ok, Agent} = barrel_a2a_client:connect(<<"http://localhost:8080">>),
%%% Card = barrel_a2a_client:card(Agent),
%%% {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"analyse this document">>),
%%% {ok, RT} = barrel_a2a_client:start(Agent, <<"Review this repository">>),
%%% ok = barrel_a2a_remote_task:stream_to(RT, self()),
%%% {ok, Final} = barrel_a2a_remote_task:result(RT, 60000).
%%% '''
%%%
%%% {@link connect/2} fetches the Agent Card from the well-known URI
%%% (or takes one with {@link from_card/2}), verifies its signature when
%%% asked, selects an interface per 8.3.2, and opens the transport.
%%% The handle is a plain map; it is safe to share between processes.
%%%
%%% == Options ==
%%%
%%% - `prefer': bindings in preference order (`[jsonrpc, rest]' or
%%%   the wire names); the card order decides otherwise.
%%% - `transports': extra `{BindingName, Module}' pairs implementing
%%%   `barrel_a2a_client_transport' (for gRPC).
%%% - `auth': see `barrel_a2a_client_auth'; or `credentials', a map
%%%   keyed by security scheme name, resolved against the card.
%%% - `version': the `A2A-Version' to send (default `<<"1.0">>').
%%% - `extensions': extension URIs to opt into.
%%% - `timeout' ms per call (default 30000), `retries' for idempotent
%%%   operations (default 2), `retry_backoff_ms' (default 200).
%%% - `verify_signatures': options of `barrel_a2a_card_sign:verify/2'
%%%   (`required => true' to refuse unsigned cards).
%%% - `validate_schema': validate replies against the A2A schema
%%%   (default `false').
%%% - `card_path': override of the well-known path.
%%% - `transport_opts': passed to the transport (`ssl_options', ...).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_client).

-export([connect/1, connect/2, from_card/2, close/1]).
-export([card/1, skills/1, interface/1, binding/1, refresh_card/1, extended_card/1]).
-export([send/2, send/3, start/2, start/3]).
-export([get_task/2, get_task/3, list_tasks/2, cancel/2, cancel/3, subscribe/2]).
-export([create_push_config/3, get_push_config/3, list_push_configs/3, delete_push_config/3]).
-export([call/3, call/4, stream/4, cancel_stream/2, headers/2, send_request/3]).

-type agent() :: #{
    card := barrel_a2a:agent_card(),
    interface := barrel_a2a_agent_card:interface(),
    binding := binary(),
    transport := module(),
    conn := barrel_a2a_client_transport:conn(),
    opts := map(),
    auth := barrel_a2a_client_auth:config(),
    base_url := binary() | undefined,
    card_etag => binary()
}.

-type send_opts() :: #{
    context_id => binary(),
    task_id => binary(),
    message_id => binary(),
    metadata => map(),
    request_metadata => map(),
    accepted_output_modes => [binary()],
    history_length => non_neg_integer(),
    return_immediately => boolean(),
    push_notification_config => map(),
    reference_task_ids => [binary()],
    timeout => timeout()
}.

-export_type([agent/0, send_opts/0]).

-define(DEFAULT_TIMEOUT, 30000).

%%--------------------------------------------------------------------
%% Connection
%%--------------------------------------------------------------------

-spec connect(binary()) -> {ok, agent()} | {error, barrel_a2a_error:error()}.
connect(Url) -> connect(Url, #{}).

-spec connect(binary(), map()) -> {ok, agent()} | {error, barrel_a2a_error:error()}.
connect(Url, Opts) ->
    _ = application:ensure_all_started(barrel_a2a),
    Base = string:trim(Url, trailing, "/"),
    CardUrl =
        <<Base/binary, (maps:get(card_path, Opts, barrel_a2a:well_known_card_path()))/binary>>,
    case barrel_a2a_client_http:fetch_card(CardUrl, fetch_opts(Opts, undefined)) of
        {ok, Card, ETag} ->
            case from_card(Card, Opts#{base_url => Base}) of
                {ok, Agent} -> {ok, Agent#{card_etag => ETag, card_url => CardUrl}};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

fetch_opts(Opts, ETag) ->
    Auth = auth_config(Opts, undefined),
    #{
        headers => barrel_a2a_client_auth:headers(Auth, get_agent_card),
        timeout => maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
        etag => ETag,
        transport_opts => maps:get(transport_opts, Opts, #{})
    }.

%% @doc Connect from an Agent Card obtained elsewhere.
-spec from_card(barrel_a2a:agent_card(), map()) ->
    {ok, agent()} | {error, barrel_a2a_error:error()}.
from_card(Card, Opts) ->
    _ = application:ensure_all_started(barrel_a2a),
    try
        ok = verify_card(Card, Opts),
        Auth = auth_config(Opts, Card),
        Transports = transports(Opts),
        Prefer = [binding_name(B) || B <- maps:get(prefer, Opts, [])],
        Supported = [Name || {Name, _} <- Transports],
        Interface = select(Card, Supported, Prefer),
        Binding = maps:get(<<"protocolBinding">>, Interface),
        Module = proplists:get_value(Binding, Transports),
        TOpts = (maps:get(transport_opts, Opts, #{}))#{
            timeout => maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)
        },
        case Module:connect(Interface, TOpts) of
            {ok, Conn} ->
                {ok, #{
                    card => Card,
                    interface => Interface,
                    binding => Binding,
                    transport => Module,
                    conn => Conn,
                    opts => Opts,
                    auth => Auth,
                    base_url => maps:get(base_url, Opts, undefined)
                }};
            {error, _} = E ->
                E
        end
    catch
        throw:{a2a_error, Error} -> {error, Error}
    end.

verify_card(Card, Opts) ->
    case maps:get(verify_signatures, Opts, undefined) of
        undefined ->
            ok;
        VOpts ->
            case barrel_a2a_card_sign:verify(Card, VOpts) of
                ok ->
                    ok;
                {error, Reason} ->
                    throw(
                        {a2a_error,
                            barrel_a2a_error:new(
                                unauthenticated,
                                io_lib:format("Agent Card signature: ~0p", [Reason])
                            )}
                    )
            end
    end.

auth_config(Opts, Card) ->
    case maps:get(auth, Opts, undefined) of
        undefined ->
            case {maps:get(credentials, Opts, undefined), Card} of
                {Creds, C} when is_map(Creds), is_map(C) ->
                    case barrel_a2a_client_auth:select(Creds, C) of
                        {ok, Cfg} -> Cfg;
                        error -> none
                    end;
                _ ->
                    none
            end;
        A ->
            case barrel_a2a_client_auth:normalize(A) of
                {ok, Cfg} ->
                    Cfg;
                {error, R} ->
                    throw(
                        {a2a_error, barrel_a2a_error:new(invalid_params, io_lib:format("~0p", [R]))}
                    )
            end
    end.

transports(Opts) ->
    Extra = [{binding_name(B), M} || {B, M} <- maps:get(transports, Opts, [])],
    Extra ++
        [
            {barrel_a2a:binding_jsonrpc(), barrel_a2a_client_http},
            {barrel_a2a:binding_rest(), barrel_a2a_client_http}
        ].

binding_name(jsonrpc) -> barrel_a2a:binding_jsonrpc();
binding_name(rest) -> barrel_a2a:binding_rest();
binding_name(grpc) -> barrel_a2a:binding_grpc();
binding_name(B) when is_binary(B) -> B.

select(Card, Supported, Prefer) ->
    case barrel_a2a_agent_card:select_interface(Card, Supported, Prefer) of
        {ok, I} ->
            I;
        error ->
            throw(
                {a2a_error,
                    barrel_a2a_error:new(
                        unsupported_operation, <<"No supported interface in the Agent Card">>
                    )}
            )
    end.

-spec close(agent()) -> ok.
close(#{transport := M, conn := Conn}) -> M:close(Conn).

%%--------------------------------------------------------------------
%% Card
%%--------------------------------------------------------------------

-spec card(agent()) -> barrel_a2a:agent_card().
card(#{card := C}) -> C.

-spec skills(agent()) -> [barrel_a2a:object()].
skills(#{card := C}) -> barrel_a2a_agent_card:skills(C).

-spec interface(agent()) -> barrel_a2a_agent_card:interface().
interface(#{interface := I}) -> I.

-spec binding(agent()) -> binary().
binding(#{binding := B}) -> B.

%% @doc Re-fetch the card with a conditional request (8.6.2).
-spec refresh_card(agent()) -> {ok, agent()} | {error, barrel_a2a_error:error()}.
refresh_card(#{card_url := Url, opts := Opts} = Agent) ->
    case
        barrel_a2a_client_http:fetch_card(
            Url, fetch_opts(Opts, maps:get(card_etag, Agent, undefined))
        )
    of
        {ok, not_modified} -> {ok, Agent};
        {ok, Card, ETag} -> {ok, Agent#{card => Card, card_etag => ETag}};
        {error, _} = E -> E
    end;
refresh_card(Agent) ->
    {ok, Agent}.

%% @doc Fetch the authenticated extended card and use it for this
%% session (3.1.11).
-spec extended_card(agent()) -> {ok, agent()} | {error, barrel_a2a_error:error()}.
extended_card(Agent) ->
    case call(Agent, get_extended_agent_card, #{}) of
        {ok, Card} -> {ok, Agent#{card => Card}};
        {error, _} = E -> E
    end.

%%--------------------------------------------------------------------
%% Messages
%%--------------------------------------------------------------------

%% @doc Send a message and wait for the outcome (blocking SendMessage).
-spec send(agent(), barrel_a2a_message:content() | barrel_a2a:message()) ->
    {ok, {task, barrel_a2a:task()} | {message, barrel_a2a:message()}}
    | {error, barrel_a2a_error:error()}.
send(Agent, Content) -> send(Agent, Content, #{}).

-spec send(agent(), barrel_a2a_message:content() | barrel_a2a:message(), send_opts()) ->
    {ok, {task, barrel_a2a:task()} | {message, barrel_a2a:message()}}
    | {error, barrel_a2a_error:error()}.
send(Agent, Content, Opts) ->
    Request = send_request(Agent, Content, Opts),
    case call(Agent, send_message, Request, call_opts(Opts)) of
        {ok, #{<<"task">> := Task}} ->
            {ok, {task, Task}};
        {ok, #{<<"message">> := Message}} ->
            {ok, {message, Message}};
        {ok, Other} ->
            {error, barrel_a2a_error:new(invalid_agent_response, io_lib:format("~0p", [Other]))};
        {error, _} = E ->
            E
    end.

%% @doc Start a task and return a `barrel_a2a_remote_task' handle that
%% streams (when the agent supports it) or polls.
-spec start(agent(), barrel_a2a_message:content() | barrel_a2a:message()) ->
    {ok, pid()} | {error, barrel_a2a_error:error()}.
start(Agent, Content) -> start(Agent, Content, #{}).

-spec start(agent(), barrel_a2a_message:content() | barrel_a2a:message(), send_opts()) ->
    {ok, pid()} | {error, barrel_a2a_error:error()}.
start(Agent, Content, Opts) ->
    Request = send_request(Agent, Content, Opts),
    barrel_a2a_remote_task:start(Agent, Request, Opts).

%% @doc Build a `SendMessageRequest' (exported for the remote task).
-spec send_request(agent(), barrel_a2a_message:content() | barrel_a2a:message(), send_opts()) ->
    barrel_a2a:object().
send_request(Agent, Content, Opts) ->
    Message0 =
        case Content of
            #{<<"parts">> := _} -> Content;
            _ -> barrel_a2a_message:new(Content)
        end,
    Message = lists:foldl(
        fun({Key, Fun}, M) ->
            case maps:get(Key, Opts, undefined) of
                undefined -> M;
                V -> Fun(V, M)
            end
        end,
        Message0,
        [
            {context_id, fun barrel_a2a_message:with_context/2},
            {task_id, fun barrel_a2a_message:with_task/2},
            {message_id, fun barrel_a2a_message:with_id/2},
            {metadata, fun barrel_a2a_message:with_metadata/2},
            {reference_task_ids, fun(V, M) -> M#{<<"referenceTaskIds">> => V} end}
        ]
    ),
    Configuration = lists:foldl(
        fun({Key, Wire}, C) ->
            case maps:get(Key, Opts, undefined) of
                undefined -> C;
                V when Key =:= push_notification_config -> C#{Wire => push_config_wire(V)};
                V -> C#{Wire => V}
            end
        end,
        #{},
        [
            {accepted_output_modes, <<"acceptedOutputModes">>},
            {history_length, <<"historyLength">>},
            {return_immediately, <<"returnImmediately">>},
            {push_notification_config, <<"taskPushNotificationConfig">>}
        ]
    ),
    Req0 = #{<<"message">> => Message},
    Req1 =
        case map_size(Configuration) of
            0 -> Req0;
            _ -> Req0#{<<"configuration">> => Configuration}
        end,
    Req2 =
        case maps:get(request_metadata, Opts, undefined) of
            undefined -> Req1;
            RM -> Req1#{<<"metadata">> => RM}
        end,
    with_tenant(Agent, Req2).

with_tenant(#{interface := I}, Req) ->
    case maps:get(<<"tenant">>, I, undefined) of
        undefined -> Req;
        T -> Req#{<<"tenant">> => T}
    end.

%%--------------------------------------------------------------------
%% Tasks
%%--------------------------------------------------------------------

-spec get_task(agent(), binary()) -> {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
get_task(Agent, TaskId) -> get_task(Agent, TaskId, #{}).

-spec get_task(agent(), binary(), #{history_length => non_neg_integer(), timeout => timeout()}) ->
    {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
get_task(Agent, TaskId, Opts) ->
    Req0 = #{<<"id">> => TaskId},
    Req =
        case maps:get(history_length, Opts, undefined) of
            undefined -> Req0;
            N -> Req0#{<<"historyLength">> => N}
        end,
    call(Agent, get_task, with_tenant(Agent, Req), call_opts(Opts)).

-spec list_tasks(agent(), map()) ->
    {ok, #{tasks := [barrel_a2a:task()], next_page_token := binary(), total_size := integer()}}
    | {error, barrel_a2a_error:error()}.
list_tasks(Agent, Opts) ->
    Req = lists:foldl(
        fun({Key, Wire, Conv}, R) ->
            case maps:get(Key, Opts, undefined) of
                undefined -> R;
                V -> R#{Wire => Conv(V)}
            end
        end,
        #{},
        [
            {context_id, <<"contextId">>, fun(V) -> V end},
            {status, <<"status">>, fun state_wire/1},
            {page_size, <<"pageSize">>, fun(V) -> V end},
            {page_token, <<"pageToken">>, fun(V) -> V end},
            {history_length, <<"historyLength">>, fun(V) -> V end},
            {status_timestamp_after, <<"statusTimestampAfter">>, fun(V) -> V end},
            {include_artifacts, <<"includeArtifacts">>, fun(V) -> V end}
        ]
    ),
    case call(Agent, list_tasks, with_tenant(Agent, Req), call_opts(Opts)) of
        {ok, #{<<"tasks">> := Tasks} = R} ->
            {ok, #{
                tasks => Tasks,
                next_page_token => maps:get(<<"nextPageToken">>, R, <<>>),
                total_size => maps:get(<<"totalSize">>, R, length(Tasks))
            }};
        {ok, Other} ->
            {error, barrel_a2a_error:new(invalid_agent_response, io_lib:format("~0p", [Other]))};
        {error, _} = E ->
            E
    end.

state_wire(S) when is_atom(S) -> barrel_a2a_task_state:to_wire(S);
state_wire(S) -> S.

-spec cancel(agent(), binary()) -> {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
cancel(Agent, TaskId) -> cancel(Agent, TaskId, #{}).

-spec cancel(agent(), binary(), #{metadata => map(), timeout => timeout()}) ->
    {ok, barrel_a2a:task()} | {error, barrel_a2a_error:error()}.
cancel(Agent, TaskId, Opts) ->
    Req0 = #{<<"id">> => TaskId},
    Req =
        case maps:get(metadata, Opts, undefined) of
            undefined -> Req0;
            M -> Req0#{<<"metadata">> => M}
        end,
    call(Agent, cancel_task, with_tenant(Agent, Req), call_opts(Opts)).

%% @doc A remote task handle subscribed to an existing task.
-spec subscribe(agent(), binary()) -> {ok, pid()} | {error, barrel_a2a_error:error()}.
subscribe(Agent, TaskId) ->
    barrel_a2a_remote_task:attach(Agent, TaskId, #{}).

%%--------------------------------------------------------------------
%% Push notification configs
%%--------------------------------------------------------------------

-spec create_push_config(agent(), binary(), map()) ->
    {ok, barrel_a2a:push_config()} | {error, barrel_a2a_error:error()}.
create_push_config(Agent, TaskId, Config) ->
    Req = maps:merge(push_config_wire(Config), #{<<"taskId">> => TaskId}),
    call(Agent, create_push_config, with_tenant(Agent, Req)).

push_config_wire(Config) ->
    maps:fold(
        fun
            (url, V, Acc) ->
                Acc#{<<"url">> => V};
            (token, V, Acc) ->
                Acc#{<<"token">> => V};
            (authentication, #{scheme := S} = A, Acc) ->
                Auth0 = #{<<"scheme">> => S},
                Auth =
                    case maps:get(credentials, A, undefined) of
                        undefined -> Auth0;
                        C -> Auth0#{<<"credentials">> => C}
                    end,
                Acc#{<<"authentication">> => Auth};
            (K, V, Acc) when is_binary(K) -> Acc#{K => V};
            (_, _, Acc) ->
                Acc
        end,
        #{},
        Config
    ).

-spec get_push_config(agent(), binary(), binary()) ->
    {ok, barrel_a2a:push_config()} | {error, barrel_a2a_error:error()}.
get_push_config(Agent, TaskId, ConfigId) ->
    call(
        Agent, get_push_config, with_tenant(Agent, #{<<"taskId">> => TaskId, <<"id">> => ConfigId})
    ).

-spec list_push_configs(agent(), binary(), map()) ->
    {ok, #{configs := [barrel_a2a:push_config()], next_page_token := binary()}}
    | {error, barrel_a2a_error:error()}.
list_push_configs(Agent, TaskId, Opts) ->
    Req0 = #{<<"taskId">> => TaskId},
    Req = maps:fold(
        fun
            (page_size, V, R) -> R#{<<"pageSize">> => V};
            (page_token, V, R) -> R#{<<"pageToken">> => V};
            (_, _, R) -> R
        end,
        Req0,
        Opts
    ),
    case call(Agent, list_push_configs, with_tenant(Agent, Req), call_opts(Opts)) of
        {ok, #{<<"configs">> := Configs} = R} ->
            {ok, #{configs => Configs, next_page_token => maps:get(<<"nextPageToken">>, R, <<>>)}};
        {ok, _} ->
            {ok, #{configs => [], next_page_token => <<>>}};
        {error, _} = E ->
            E
    end.

-spec delete_push_config(agent(), binary(), binary()) -> ok | {error, barrel_a2a_error:error()}.
delete_push_config(Agent, TaskId, ConfigId) ->
    case
        call(
            Agent,
            delete_push_config,
            with_tenant(Agent, #{<<"taskId">> => TaskId, <<"id">> => ConfigId})
        )
    of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

%%--------------------------------------------------------------------
%% Low level
%%--------------------------------------------------------------------

%% @doc Invoke any unary operation with a raw request object.
-spec call(agent(), barrel_a2a:op(), barrel_a2a:object()) ->
    {ok, barrel_a2a:json()} | {error, barrel_a2a_error:error()}.
call(Agent, Op, Request) -> call(Agent, Op, Request, #{}).

-spec call(agent(), barrel_a2a:op(), barrel_a2a:object(), map()) ->
    {ok, barrel_a2a:json()} | {error, barrel_a2a_error:error()}.
call(#{transport := M, conn := Conn, opts := Opts} = Agent, Op, Request, CallOpts) ->
    TOpts = #{
        headers => headers(Agent, Op),
        timeout => maps:get(timeout, CallOpts, maps:get(timeout, Opts, ?DEFAULT_TIMEOUT))
    },
    Retries =
        case idempotent(Op) of
            true -> maps:get(retries, Opts, 2);
            false -> 0
        end,
    Result = with_retries(
        fun() -> M:call(Conn, Op, Request, TOpts) end,
        Retries,
        maps:get(retry_backoff_ms, Opts, 200)
    ),
    validate_reply(Op, Result, Opts).

idempotent(get_task) -> true;
idempotent(list_tasks) -> true;
idempotent(get_push_config) -> true;
idempotent(list_push_configs) -> true;
idempotent(get_extended_agent_card) -> true;
idempotent(_) -> false.

with_retries(Fun, Retries, Backoff) ->
    case Fun() of
        {error, #{type := T}} when
            Retries > 0, T =:= transport; Retries > 0, T =:= unavailable; Retries > 0, T =:= timeout
        ->
            timer:sleep(Backoff),
            with_retries(Fun, Retries - 1, Backoff * 2);
        Result ->
            Result
    end.

validate_reply(Op, {ok, Reply}, #{validate_schema := true}) ->
    Type = barrel_a2a_schema:reply_type(Op),
    case barrel_a2a_schema:validate(Type, Reply) of
        ok ->
            {ok, Reply};
        {error, Errors} ->
            {error,
                barrel_a2a_error:new(
                    invalid_agent_response,
                    io_lib:format("Reply does not match ~s: ~0p", [Type, Errors])
                )}
    end;
validate_reply(_, Result, _) ->
    Result.

%% @doc Open a stream for `send_streaming_message' or
%% `subscribe_to_task'; events go to `Owner' as documented in
%% `barrel_a2a_client_transport'.
-spec stream(agent(), barrel_a2a:op(), barrel_a2a:object(), pid()) ->
    {ok, barrel_a2a_client_transport:stream_ref()} | {error, barrel_a2a_error:error()}.
stream(#{transport := M, conn := Conn, opts := Opts} = Agent, Op, Request, Owner) ->
    TOpts = #{headers => headers(Agent, Op), timeout => maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)},
    M:stream(Conn, Op, Request, Owner, TOpts).

-spec cancel_stream(agent(), barrel_a2a_client_transport:stream_ref()) -> ok.
cancel_stream(#{transport := M, conn := Conn}, Ref) -> M:cancel_stream(Conn, Ref).

%% @doc The per-request headers: credentials, `A2A-Version',
%% `A2A-Extensions'.
-spec headers(agent(), barrel_a2a:op() | atom()) -> [{binary(), binary()}].
headers(#{auth := Auth, opts := Opts}, Op) ->
    Version = maps:get(version, Opts, barrel_a2a:protocol_version()),
    Ext =
        case barrel_a2a_extensions:format_header(maps:get(extensions, Opts, [])) of
            undefined -> [];
            V -> [{<<"a2a-extensions">>, V}]
        end,
    [{<<"a2a-version">>, Version} | Ext] ++ barrel_a2a_client_auth:headers(Auth, Op).

call_opts(Opts) ->
    maps:with([timeout], Opts).
