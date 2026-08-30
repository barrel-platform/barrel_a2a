%%%-------------------------------------------------------------------
%%% @doc The binding-neutral request dispatcher.
%%%
%%% Every binding (JSON-RPC and HTTP+JSON here, gRPC in
%%% `livery_grpc_a2a') calls {@link call/4} with the operation, the
%%% request object exactly as the A2A JSON shape, and a request
%%% context describing what the binding knows: headers or metadata,
%%% the requested version and extensions, the tenant from the path,
%%% the peer, optionally an already authenticated principal.
%%%
%%% The dispatcher applies, in order: rate limiting, authentication,
%%% tenant check, version negotiation, extension negotiation,
%%% capability validation, request validation (structural, then JSON
%%% Schema when enabled), authorization scoping, and the operation.
%%%
%%% Replies are `{ok, ReplyObject}' for unary operations,
%%% `{stream, Subscribe}' for the two streaming operations where
%%% `Subscribe(Pid)' registers `Pid' for `{a2a_task_event, TaskId,
%%% StreamResponse}' messages and returns the events to send first,
%%% or `{error, Error}'.
%%%
%%% == Neighbours ==
%%%
%%% Called by `barrel_a2a_http_engine' (both HTTP bindings) and by an
%%% out-of-tree binding such as `livery_grpc_a2a'. Calls
%%% `barrel_a2a_auth', `barrel_a2a_validate', `barrel_a2a_schema',
%%% `barrel_a2a_task_registry', `barrel_a2a_task_proc' and
%%% `barrel_a2a_push'.
%%%
%%% Specification: operations 3.1, error mapping 5.4, security 13.
%%%
%%% == Invariants ==
%%%
%%% Subscribing a caller before starting a task is a `call' and running
%%% it is a `cast'; that asymmetry is the only thing keeping the first
%%% events from being lost. See docs/internals/invariants.md, T1.
%%%
%%% == Testing ==
%%%
%%% Exercise it through a started server: build a `req_ctx()' by hand
%%% and call {@link call/4} directly, without a socket. The end-to-end
%%% suites drive the same path through the bindings.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_server_core).

-export([call/4, active_extensions/2]).

-type req_ctx() :: #{
    binding := jsonrpc | rest | grpc | atom(),
    headers => [{binary(), binary()}],
    version => binary() | undefined,
    extensions => [binary()],
    tenant => binary() | undefined,
    peer => term(),
    principal => barrel_a2a:principal()
}.

%% The accumulator {@link call/4} threads through the pipeline. It
%% grows as the request is checked, so which keys are present depends
%% on how far it has got:
%%
%% - `cfg', `op', `req' and `ctx' exist from the start (`call/4');
%% - `principal' is added by `authenticate/1', the second step, so
%%   everything after it may assume a caller identity;
%% - `version' by `version/1' and `extensions' by `extensions/1', both
%%   before any operation runs.
%%
%% By the time `dispatch/2' sees it, every key is set. A helper called
%% from earlier in the pipeline must not assume the later ones.
-type env() :: #{
    cfg := barrel_a2a_server:cfg(),
    op := barrel_a2a:op(),
    %% The request object in its A2A JSON shape, as the binding built it.
    req := barrel_a2a:object(),
    ctx := req_ctx(),
    principal => barrel_a2a:principal(),
    version => binary(),
    extensions => [binary()]
}.

%% The three keys a task process needs from the server config, so that
%% a task never reads the whole thing.
-type task_cfg() :: #{
    handler := barrel_a2a_handler:handler(),
    registry := barrel_a2a_task_registry:table(),
    push_notify := undefined | fun((binary(), barrel_a2a:stream_response()) -> ok)
}.

%% What the request knew, carried into the task process so that a
%% handler invoked later (a follow-up, a resume) still sees the
%% context of the message that triggered it.
-type task_req() :: #{
    configuration := map(),
    metadata := map(),
    extensions := [binary()],
    tenant := undefined | binary(),
    principal := barrel_a2a:principal(),
    binding := atom()
}.

-type subscribe() :: fun((pid()) -> {ok, [barrel_a2a:stream_response()]} | {error, term()}).

-type reply() ::
    {ok, barrel_a2a:object()}
    | {stream, subscribe()}
    | {error, barrel_a2a_error:error()}.

-export_type([req_ctx/0, env/0, task_cfg/0, task_req/0, subscribe/0, reply/0]).

-spec call(pid(), barrel_a2a:op(), barrel_a2a:object(), req_ctx()) -> reply().
call(Server, Op, Request, ReqCtx) ->
    Cfg = barrel_a2a_server:config(Server),
    try
        Env0 = #{cfg => Cfg, op => Op, req => Request, ctx => ReqCtx},
        ok = rate_limit(Env0),
        Env1 = authenticate(Env0),
        ok = tenant(Env1),
        Env2 = version(Env1),
        Env3 = extensions(Env2),
        ok = capability(Env3),
        ok = validate(Env3),
        dispatch(Op, Env3)
    catch
        throw:{a2a_error, #{type := _} = Error} -> {error, Error}
    end.

%% @doc Extensions active for a request, for the response header.
-spec active_extensions(pid(), req_ctx()) -> [binary()].
active_extensions(Server, ReqCtx) ->
    Cfg = barrel_a2a_server:config(Server),
    Requested = maps:get(extensions, ReqCtx, []),
    case barrel_a2a_extensions:negotiate(Requested, maps:get(card, Cfg)) of
        {ok, Active} -> Active;
        {error, _} -> []
    end.

-spec fail(barrel_a2a_error:error()) -> no_return().
fail(Error) -> throw({a2a_error, Error}).

%%--------------------------------------------------------------------
%% Pre-checks
%%--------------------------------------------------------------------

rate_limit(#{cfg := #{rate_limit := undefined}}) ->
    ok;
rate_limit(#{cfg := #{rate_limit := Fun}, ctx := Ctx, op := Op}) ->
    case Fun(Ctx#{op => Op}) of
        ok ->
            ok;
        {error, RetryAfter} ->
            E = barrel_a2a_error:new(rate_limited),
            fail(E#{retry_after => RetryAfter})
    end.

authenticate(#{ctx := #{principal := P}} = Env) when P =/= undefined ->
    Env#{principal => P};
authenticate(#{cfg := Cfg, ctx := Ctx, op := Op} = Env) ->
    Request = #{
        headers => maps:get(headers, Ctx, []),
        op => Op,
        binding => maps:get(binding, Ctx, unknown),
        peer => maps:get(peer, Ctx, undefined)
    },
    case barrel_a2a_auth:authenticate(maps:get(auth, Cfg), Request, #{}) of
        {ok, Principal} ->
            Env#{principal => Principal};
        {error, forbidden} ->
            fail(barrel_a2a_error:new(permission_denied));
        {error, _} ->
            E = barrel_a2a_error:new(unauthenticated),
            fail(E#{
                challenge => barrel_a2a_auth:challenge_headers(
                    maps:get(auth, Cfg), maps:get(card, Cfg)
                )
            })
    end.

tenant(#{cfg := #{tenant := Configured}, ctx := Ctx, req := Req}) ->
    Requested =
        case maps:get(tenant, Ctx, undefined) of
            undefined -> barrel_a2a_tenant:request_tenant(Req);
            T -> T
        end,
    case barrel_a2a_tenant:check(Configured, Requested) of
        ok ->
            case {Configured, barrel_a2a_tenant:request_tenant(Req)} of
                {undefined, _} -> ok;
                {_, undefined} -> ok;
                {Same, Same} -> ok;
                _ -> fail(barrel_a2a_error:invalid(<<"tenant">>, <<"unknown tenant">>))
            end;
        {error, E} ->
            fail(E)
    end.

version(#{cfg := Cfg, ctx := Ctx} = Env) ->
    Raw = maps:get(version, Ctx, undefined),
    Supported = maps:get(supported_versions, Cfg),
    case barrel_a2a_version:negotiate(Raw, Supported) of
        {ok, V} ->
            Env#{version => V};
        {error, unsupported} ->
            Legacy = barrel_a2a:legacy_version(),
            case {barrel_a2a_version:normalize(Raw), maps:get(accept_legacy_version, Cfg)} of
                {Legacy, true} ->
                    Env#{version => Legacy};
                {undefined, _} ->
                    fail(
                        barrel_a2a_error:new(
                            version_not_supported,
                            <<"A2A-Version is malformed">>,
                            [version_detail(Supported)]
                        )
                    );
                {Norm, _} ->
                    fail(
                        barrel_a2a_error:new(
                            version_not_supported,
                            [<<"A2A protocol version ">>, Norm, <<" is not supported">>],
                            [version_detail(Supported)]
                        )
                    )
            end
    end.

version_detail(Supported) ->
    barrel_a2a_error:error_info(version_not_supported, #{
        <<"supportedVersions">> => Supported
    }).

extensions(#{cfg := Cfg, ctx := Ctx} = Env) ->
    Requested = maps:get(extensions, Ctx, []),
    case barrel_a2a_extensions:negotiate(Requested, maps:get(card, Cfg)) of
        {ok, Active} ->
            Env#{extensions => Active};
        {error, {required, Uri}} ->
            fail(
                barrel_a2a_error:new(
                    extension_support_required,
                    [<<"Extension ">>, Uri, <<" is required">>],
                    [barrel_a2a_error:error_info(extension_support_required, #{<<"uri">> => Uri})]
                )
            )
    end.

capability(#{cfg := Cfg, op := Op}) ->
    Card = maps:get(card, Cfg),
    case Op of
        _ when Op =:= send_streaming_message; Op =:= subscribe_to_task ->
            case maps:get(streaming, Cfg) andalso barrel_a2a_agent_card:supports(Card, streaming) of
                true ->
                    ok;
                false ->
                    fail(
                        barrel_a2a_error:new(
                            unsupported_operation, <<"Streaming is not supported">>
                        )
                    )
            end;
        _ when
            Op =:= create_push_config;
            Op =:= get_push_config;
            Op =:= list_push_configs;
            Op =:= delete_push_config
        ->
            case maps:get(push, Cfg) of
                false -> fail(barrel_a2a_error:new(push_notification_not_supported));
                _ -> ok
            end;
        get_extended_agent_card ->
            case barrel_a2a_agent_card:supports(Card, extended_agent_card) of
                true ->
                    ok;
                false ->
                    fail(
                        barrel_a2a_error:new(
                            unsupported_operation, <<"Extended agent card is not supported">>
                        )
                    )
            end;
        _ ->
            ok
    end.

validate(#{cfg := Cfg, op := Op, req := Req}) ->
    Structural =
        case Op of
            send_message -> barrel_a2a_validate:send_message_request(Req);
            send_streaming_message -> barrel_a2a_validate:send_message_request(Req);
            get_task -> barrel_a2a_validate:get_task_request(Req);
            list_tasks -> barrel_a2a_validate:list_tasks_request(Req);
            cancel_task -> barrel_a2a_validate:cancel_task_request(Req);
            subscribe_to_task -> barrel_a2a_validate:subscribe_request(Req);
            create_push_config -> barrel_a2a_validate:push_config(Req);
            get_push_config -> barrel_a2a_validate:push_config_ref(Req);
            delete_push_config -> barrel_a2a_validate:push_config_ref(Req);
            list_push_configs -> barrel_a2a_validate:list_push_configs_request(Req);
            get_extended_agent_card -> ok
        end,
    case Structural of
        ok -> schema_validate(maps:get(validate_schema, Cfg), Op, Req);
        {error, Reason} -> fail(barrel_a2a_validate:to_error(Reason))
    end.

schema_validate(false, _, _) ->
    ok;
schema_validate(_, Op, Req) ->
    case barrel_a2a_schema:validate(barrel_a2a_schema:request_type(Op), Req) of
        ok ->
            ok;
        {error, Errors} ->
            Violations = [
                barrel_a2a_error:field_violation(path_to_bin(Path), reason_to_bin(Reason))
             || {Path, Reason} <- Errors
            ],
            fail(
                barrel_a2a_error:new(invalid_params, <<"Request does not match the A2A schema">>, [
                    barrel_a2a_error:bad_request(Violations)
                ])
            )
    end.

path_to_bin(Path) ->
    iolist_to_binary(lists:join(<<".">>, [segment(S) || S <- Path])).

segment(S) when is_binary(S) -> S;
segment(I) when is_integer(I) -> integer_to_binary(I);
segment(Other) -> iolist_to_binary(io_lib:format("~0p", [Other])).

reason_to_bin(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).

%%--------------------------------------------------------------------
%% Operations
%%--------------------------------------------------------------------

dispatch(send_message, Env) ->
    send_message(Env, false);
dispatch(send_streaming_message, Env) ->
    send_message(Env, true);
dispatch(get_task, #{req := Req} = Env) ->
    Entry = visible_task(Env, maps:get(<<"id">>, Req)),
    {ok, with_history(Env, snapshot(Entry), maps:get(<<"historyLength">>, Req, undefined))};
dispatch(list_tasks, #{req := Req, cfg := Cfg} = Env) ->
    Filter0 = #{
        page_size => maps:get(<<"pageSize">>, Req, undefined),
        page_token => maps:get(<<"pageToken">>, Req, undefined)
    },
    Filter1 = maybe_put(context_id, maps:get(<<"contextId">>, Req, undefined), Filter0),
    Filter2 =
        case maps:get(<<"status">>, Req, undefined) of
            undefined ->
                Filter1;
            S ->
                {ok, State} = barrel_a2a_task_state:from_wire(S),
                Filter1#{state => State}
        end,
    Filter3 =
        case maps:get(<<"statusTimestampAfter">>, Req, undefined) of
            undefined ->
                Filter2;
            Iso ->
                {ok, Ms} = barrel_a2a_time:from_iso(Iso),
                Filter2#{after_ms => Ms}
        end,
    Filter = scope_filter(Env, Filter3),
    case barrel_a2a_task_registry:list(maps:get(registry, Cfg), Filter) of
        {error, invalid_page_token} ->
            fail(barrel_a2a_error:invalid(<<"pageToken">>, <<"invalid page token">>));
        {ok, Entries, Next, Total} ->
            Visible = [E || E <- Entries, authorized(Env, E)],
            HistoryLength = maps:get(<<"historyLength">>, Req, undefined),
            IncludeArtifacts = maps:get(<<"includeArtifacts">>, Req, false) =:= true,
            Tasks = [
                list_task(Env, snapshot(E), HistoryLength, IncludeArtifacts)
             || E <- Visible
            ],
            {ok, #{
                <<"tasks">> => Tasks,
                <<"nextPageToken">> => Next,
                <<"pageSize">> => length(Tasks),
                <<"totalSize">> => Total
            }}
    end;
dispatch(cancel_task, #{req := Req} = Env) ->
    Entry = visible_task(Env, maps:get(<<"id">>, Req)),
    Metadata = maps:get(<<"metadata">>, Req, #{}),
    case Entry of
        #{pid := Pid} when is_pid(Pid) ->
            case safe_call(fun() -> barrel_a2a_task_proc:cancel(Pid, Metadata) end) of
                {ok, Task} -> {ok, with_history(Env, Task, undefined)};
                {error, #{type := _} = E} -> fail(E);
                _ -> cancel_finished(Env, Entry)
            end;
        _ ->
            cancel_finished(Env, Entry)
    end;
dispatch(subscribe_to_task, #{req := Req} = Env) ->
    Entry = visible_task(Env, maps:get(<<"id">>, Req)),
    case Entry of
        #{pid := Pid, task := Task} when is_pid(Pid) ->
            case barrel_a2a_task:is_terminal(Task) of
                true -> fail(terminal_error());
                false -> {stream, subscribe_existing(Pid)}
            end;
        _ ->
            fail(terminal_error())
    end;
dispatch(create_push_config, #{req := Req, cfg := Cfg} = Env) ->
    TaskId = maps:get(<<"taskId">>, Req, undefined),
    _ = visible_task(Env, TaskId),
    case barrel_a2a_push:create(maps:get(push_store, Cfg), TaskId, Req, maps:get(push, Cfg)) of
        {ok, Config} -> {ok, Config};
        {error, E} -> fail(E)
    end;
dispatch(get_push_config, #{req := Req, cfg := Cfg} = Env) ->
    TaskId = maps:get(<<"taskId">>, Req),
    _ = visible_task(Env, TaskId),
    case barrel_a2a_push:get(maps:get(push_store, Cfg), TaskId, maps:get(<<"id">>, Req)) of
        {ok, Config} ->
            {ok, Config};
        error ->
            fail(barrel_a2a_error:new(task_not_found, <<"Push notification config not found">>))
    end;
dispatch(list_push_configs, #{req := Req, cfg := Cfg} = Env) ->
    TaskId = maps:get(<<"taskId">>, Req),
    _ = visible_task(Env, TaskId),
    PageSize = maps:get(<<"pageSize">>, Req, undefined),
    Token = maps:get(<<"pageToken">>, Req, undefined),
    case barrel_a2a_push:list(maps:get(push_store, Cfg), TaskId, PageSize, Token) of
        {ok, Configs, Next} ->
            {ok, #{<<"configs">> => Configs, <<"nextPageToken">> => Next}};
        {error, invalid_page_token} ->
            fail(barrel_a2a_error:invalid(<<"pageToken">>, <<"invalid page token">>))
    end;
dispatch(delete_push_config, #{req := Req, cfg := Cfg} = Env) ->
    TaskId = maps:get(<<"taskId">>, Req),
    _ = visible_task(Env, TaskId),
    ok = barrel_a2a_push:delete(maps:get(push_store, Cfg), TaskId, maps:get(<<"id">>, Req)),
    {ok, #{}};
dispatch(get_extended_agent_card, #{cfg := Cfg, principal := Principal}) ->
    case maps:get(extended_card, Cfg) of
        undefined ->
            fail(barrel_a2a_error:new(extended_agent_card_not_configured));
        Fun when is_function(Fun, 1) ->
            case Fun(Principal) of
                Card when is_map(Card) -> {ok, Card};
                undefined -> fail(barrel_a2a_error:new(extended_agent_card_not_configured));
                _ -> fail(barrel_a2a_error:new(internal_error, <<"extended card hook failed">>))
            end;
        Card when is_map(Card) ->
            {ok, Card}
    end.

terminal_error() ->
    barrel_a2a_error:new(unsupported_operation, <<"Task is in a terminal state">>).

cancel_finished(Env, #{task := Task}) ->
    case barrel_a2a_task:state(Task) of
        canceled -> {ok, with_history(Env, Task, undefined)};
        _ -> fail(barrel_a2a_error:new(task_not_cancelable))
    end.

maybe_put(_, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

%%--------------------------------------------------------------------
%% SendMessage
%%--------------------------------------------------------------------

send_message(#{req := Req, cfg := Cfg} = Env, Streaming) ->
    Message0 = maps:get(<<"message">>, Req),
    Configuration = maps:get(<<"configuration">>, Req, #{}),
    ok = check_modes(Env, Message0, Configuration),
    ReturnImmediately = maps:get(<<"returnImmediately">>, Configuration, false) =:= true,
    HistoryLength = maps:get(<<"historyLength">>, Configuration, undefined),
    Message = barrel_a2a_message:with_id(message_id(Message0), Message0),
    TaskReq = task_req(Env, Configuration),
    case barrel_a2a_message:task_id(Message) of
        undefined ->
            case dedupe(Env, Message) of
                {ok, Existing} ->
                    reply_existing(Env, Existing, HistoryLength);
                new ->
                    ContextId = context_id(Env, Message),
                    Message1 = barrel_a2a_message:with_context(ContextId, Message),
                    Pid = create_task(Env, ContextId, Message1, TaskReq),
                    ok = attach_push(Env, Pid, Configuration),
                    case Streaming of
                        true ->
                            {stream, subscribe_new(Pid)};
                        false when ReturnImmediately ->
                            {ok, Task} = barrel_a2a_task_proc:materialize(Pid),
                            barrel_a2a_task_proc:run(Pid),
                            {ok, #{<<"task">> => with_history(Env, Task, HistoryLength)}};
                        false ->
                            %% Subscribe is a call and run is a cast, so the
                            %% subscription is registered before the handler
                            %% can produce anything. Reversing them loses the
                            %% first events (invariants.md, T1).
                            {ok, _} = barrel_a2a_task_proc:subscribe(Pid, self()),
                            barrel_a2a_task_proc:run(Pid),
                            await_reply(Env, Pid, HistoryLength, maps:get(blocking_timeout, Cfg))
                    end
            end;
        TaskId ->
            Entry = visible_task(Env, TaskId),
            Pid = live_pid(Entry),
            ContextId = barrel_a2a_task:context_id(maps:get(task, Entry)),
            case barrel_a2a_message:context_id(Message) of
                undefined ->
                    ok;
                ContextId ->
                    ok;
                _ ->
                    fail(
                        barrel_a2a_error:invalid(
                            <<"message.contextId">>, <<"does not match the task">>
                        )
                    )
            end,
            Message1 = barrel_a2a_message:with_context(ContextId, Message),
            ok = attach_push(Env, Pid, Configuration),
            case Streaming of
                true ->
                    {stream, subscribe_follow_up(Pid, Message1, TaskReq)};
                false ->
                    {ok, _} = barrel_a2a_task_proc:subscribe(Pid, self()),
                    case barrel_a2a_task_proc:send_message(Pid, Message1, TaskReq) of
                        ok when ReturnImmediately ->
                            {ok, Task} = barrel_a2a_task_proc:get_task(Pid),
                            barrel_a2a_task_proc:unsubscribe(Pid, self()),
                            {ok, #{<<"task">> => with_history(Env, Task, HistoryLength)}};
                        ok ->
                            await_reply(Env, Pid, HistoryLength, maps:get(blocking_timeout, Cfg));
                        {error, E} ->
                            barrel_a2a_task_proc:unsubscribe(Pid, self()),
                            fail(E)
                    end
            end
    end.

message_id(Message) ->
    case barrel_a2a_message:id(Message) of
        undefined -> barrel_a2a_id:uuid();
        Id -> Id
    end.

task_req(
    #{ctx := Ctx, principal := Principal, extensions := Ext, req := Req, cfg := Cfg}, Configuration
) ->
    Tenant =
        case maps:get(tenant, Ctx, undefined) of
            undefined ->
                case barrel_a2a_tenant:request_tenant(Req) of
                    undefined -> maps:get(tenant, Cfg);
                    T -> T
                end;
            T ->
                T
        end,
    #{
        configuration => Configuration,
        metadata => maps:get(<<"metadata">>, Req, #{}),
        extensions => Ext,
        tenant => Tenant,
        principal => Principal,
        binding => maps:get(binding, Ctx, unknown)
    }.

context_id(#{cfg := Cfg}, Message) ->
    case barrel_a2a_message:context_id(Message) of
        undefined ->
            barrel_a2a_id:uuid();
        Given ->
            case maps:get(accept_client_context_id, Cfg) of
                true ->
                    Given;
                false ->
                    fail(
                        barrel_a2a_error:invalid(
                            <<"message.contextId">>, <<"client-provided contextId is not accepted">>
                        )
                    )
            end
    end.

dedupe(#{cfg := #{dedupe_messages := false}}, _) ->
    new;
dedupe(#{cfg := Cfg} = Env, Message) ->
    Id = barrel_a2a_message:id(Message),
    Match = [
        E
     || E <- barrel_a2a_task_registry:all(maps:get(registry, Cfg)),
        authorized(Env, E),
        lists:any(
            fun(M) -> barrel_a2a_message:id(M) =:= Id end,
            barrel_a2a_task:history(maps:get(task, E))
        )
    ],
    case Match of
        [E | _] -> {ok, E};
        [] -> new
    end.

reply_existing(Env, Entry, HistoryLength) ->
    {ok, #{<<"task">> => with_history(Env, snapshot(Entry), HistoryLength)}}.

create_task(#{cfg := Cfg, principal := Principal, req := Req}, ContextId, Message, TaskReq) ->
    Args = #{
        cfg => task_cfg(Cfg),
        task_id => barrel_a2a_id:uuid(),
        context_id => ContextId,
        message => Message,
        owner => Principal,
        req => TaskReq,
        metadata => maps:get(<<"metadata">>, Req, undefined)
    },
    case barrel_a2a_task_sup:start_task(maps:get(task_sup, Cfg), Args) of
        {ok, Pid} -> Pid;
        {error, Reason} -> fail(barrel_a2a_error:internal({task_start_failed, Reason}))
    end.

-spec task_cfg(barrel_a2a_server:cfg()) -> task_cfg().
task_cfg(Cfg) ->
    #{
        handler => maps:get(handler, Cfg),
        registry => maps:get(registry, Cfg),
        push_notify => maps:get(push_notify, Cfg, undefined)
    }.

attach_push(#{cfg := #{push := false}}, _Pid, Configuration) ->
    case maps:get(<<"taskPushNotificationConfig">>, Configuration, undefined) of
        undefined -> ok;
        _ -> fail(barrel_a2a_error:new(push_notification_not_supported))
    end;
attach_push(#{cfg := Cfg}, Pid, Configuration) ->
    case maps:get(<<"taskPushNotificationConfig">>, Configuration, undefined) of
        undefined ->
            ok;
        PushCfg ->
            %% Register before the task materializes so the webhook
            %% sees the initial Task event too.
            {ok, Task} = barrel_a2a_task_proc:get_task(Pid),
            TaskId = barrel_a2a_task:id(Task),
            case
                barrel_a2a_push:create(
                    maps:get(push_store, Cfg), TaskId, PushCfg, maps:get(push, Cfg)
                )
            of
                {ok, _} -> ok;
                {error, E} -> fail(E)
            end
    end.

subscribe_new(Pid) ->
    fun(Subscriber) ->
        %% Same ordering rule as the blocking path (invariants.md, T1).
        {ok, _} = barrel_a2a_task_proc:subscribe(Pid, Subscriber),
        barrel_a2a_task_proc:run(Pid),
        {ok, []}
    end.

subscribe_existing(Pid) ->
    fun(Subscriber) ->
        case safe_call(fun() -> barrel_a2a_task_proc:subscribe(Pid, Subscriber) end) of
            {ok, undefined} -> {ok, []};
            {ok, Snapshot} -> {ok, [barrel_a2a_event:task(Snapshot)]};
            _ -> {error, terminal_error()}
        end
    end.

subscribe_follow_up(Pid, Message, TaskReq) ->
    fun(Subscriber) ->
        case safe_call(fun() -> barrel_a2a_task_proc:subscribe(Pid, Subscriber) end) of
            {ok, _Stale} ->
                case barrel_a2a_task_proc:send_message(Pid, Message, TaskReq) of
                    ok ->
                        %% The snapshot after the message was accepted,
                        %% so the stream opens on the current state.
                        case safe_call(fun() -> barrel_a2a_task_proc:get_task(Pid) end) of
                            {ok, Fresh} -> {ok, [barrel_a2a_event:task(Fresh)]};
                            _ -> {ok, []}
                        end;
                    {error, E} ->
                        {error, E}
                end;
            _ ->
                {error, terminal_error()}
        end
    end.

await_reply(Env, Pid, HistoryLength, Timeout) ->
    Result = barrel_a2a_task_proc:await(Pid, Timeout),
    barrel_a2a_task_proc:unsubscribe(Pid, self()),
    flush_events(),
    case Result of
        {task, Task} -> {ok, #{<<"task">> => with_history(Env, Task, HistoryLength)}};
        {message, Message} -> {ok, #{<<"message">> => Message}};
        {error, #{type := _} = E} -> fail(E);
        {error, Reason} -> fail(barrel_a2a_error:internal(Reason))
    end.

flush_events() ->
    receive
        {a2a_task_event, _, _} -> flush_events();
        {a2a_task_error, _, _} -> flush_events()
    after 0 -> ok
    end.

%%--------------------------------------------------------------------
%% Media types (3.1.1 ContentTypeNotSupported)
%%--------------------------------------------------------------------

check_modes(#{cfg := Cfg}, Message, Configuration) ->
    Card = maps:get(card, Cfg),
    InputModes = all_modes(Card, input),
    OutputModes = all_modes(Card, output),
    PartTypes = [barrel_a2a_part:media_type(P) || P <- barrel_a2a_message:parts(Message)],
    case [T || T <- PartTypes, T =/= undefined, not mode_accepted(T, InputModes)] of
        [Bad | _] ->
            fail(
                barrel_a2a_error:new(
                    content_type_not_supported,
                    [<<"Input media type ">>, Bad, <<" is not supported">>],
                    [
                        barrel_a2a_error:error_info(content_type_not_supported, #{
                            <<"mediaType">> => Bad
                        })
                    ]
                )
            );
        [] ->
            case maps:get(<<"acceptedOutputModes">>, Configuration, []) of
                [] ->
                    ok;
                Accepted ->
                    case lists:any(fun(A) -> mode_accepted(A, OutputModes) end, Accepted) of
                        true ->
                            ok;
                        false ->
                            fail(
                                barrel_a2a_error:new(
                                    content_type_not_supported,
                                    <<"None of the accepted output modes is supported">>
                                )
                            )
                    end
            end
    end.

all_modes(Card, Kind) ->
    {DefaultKey, SkillKey} =
        case Kind of
            input -> {fun barrel_a2a_agent_card:default_input_modes/1, <<"inputModes">>};
            output -> {fun barrel_a2a_agent_card:default_output_modes/1, <<"outputModes">>}
        end,
    FromSkills = lists:append([
        case maps:get(SkillKey, S, []) of
            L when is_list(L) -> L;
            _ -> []
        end
     || S <- barrel_a2a_agent_card:skills(Card)
    ]),
    lists:usort([string:lowercase(M) || M <- DefaultKey(Card) ++ FromSkills, is_binary(M)]).

%% `*/*' and `type/*' patterns on either side match; parameters are
%% ignored; an empty declared list accepts everything.
mode_accepted(_, []) ->
    true;
mode_accepted(Type, Modes) ->
    T = base_type(Type),
    lists:any(fun(M) -> type_match(T, base_type(M)) end, Modes).

base_type(Type) ->
    [Base | _] = binary:split(string:lowercase(Type), <<";">>),
    string:trim(Base).

type_match(_, <<"*/*">>) ->
    true;
type_match(<<"*/*">>, _) ->
    true;
type_match(T, M) ->
    case {binary:split(T, <<"/">>), binary:split(M, <<"/">>)} of
        {[Top, _], [Top, <<"*">>]} -> true;
        {[Top, <<"*">>], [Top, _]} -> true;
        _ -> T =:= M
    end.

%%--------------------------------------------------------------------
%% Tasks: lookup, scoping, shaping
%%--------------------------------------------------------------------

visible_task(_Env, undefined) ->
    fail(barrel_a2a_error:invalid(<<"id">>, <<"is required">>));
visible_task(#{cfg := Cfg} = Env, TaskId) ->
    case barrel_a2a_task_registry:lookup(maps:get(registry, Cfg), TaskId) of
        {ok, Entry} ->
            case authorized(Env, Entry) of
                true -> Entry;
                false -> fail(not_found(TaskId))
            end;
        error ->
            fail(not_found(TaskId))
    end.

not_found(TaskId) ->
    barrel_a2a_error:new(task_not_found, [<<"Task ">>, TaskId, <<" not found">>], [
        barrel_a2a_error:error_info(task_not_found, #{<<"taskId">> => TaskId})
    ]).

live_pid(#{pid := Pid}) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> Pid;
        false -> fail(terminal_error())
    end;
live_pid(_) ->
    fail(terminal_error()).

authorized(#{cfg := #{authorize := any}}, _) ->
    true;
authorized(#{cfg := #{authorize := owner}, principal := P}, #{owner := Owner}) ->
    Owner =:= P;
authorized(#{cfg := #{authorize := Fun}, principal := P}, Entry) ->
    try
        Fun(P, Entry) =:= true
    catch
        _:_ -> false
    end.

scope_filter(#{cfg := #{authorize := owner}, principal := P}, Filter) ->
    Filter#{owner => P};
scope_filter(_, Filter) ->
    Filter.

%% The latest snapshot: from the live process when there is one.
snapshot(#{pid := Pid, task := Task}) when is_pid(Pid) ->
    case safe_call(fun() -> barrel_a2a_task_proc:get_task(Pid) end) of
        {ok, T} -> T;
        _ -> Task
    end;
snapshot(#{task := Task}) ->
    Task.

with_history(#{cfg := Cfg}, Task, undefined) ->
    case maps:get(history_default, Cfg) of
        all -> Task;
        N when is_integer(N) -> barrel_a2a_task:with_history_length(Task, N)
    end;
with_history(_, Task, N) ->
    barrel_a2a_task:with_history_length(Task, N).

list_task(Env, Task, HistoryLength, true) ->
    with_history(Env, Task, HistoryLength);
list_task(Env, Task, HistoryLength, false) ->
    barrel_a2a_task:without_artifacts(with_history(Env, Task, HistoryLength)).

%% A call to a task process that may already have exited.
safe_call(Fun) ->
    try
        Fun()
    catch
        exit:_ -> {error, noproc}
    end.
