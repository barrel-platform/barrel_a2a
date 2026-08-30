%%%-------------------------------------------------------------------
%%% @doc The handler behaviour: how an application exposes its agent.
%%%
%%% One handler per server, invoked once per incoming message, like
%%% the a2a-python `AgentExecutor'. The handler may be a module
%%% implementing this behaviour or a `fun((Ctx, Message) -> result())'.
%%%
%%% ```
%%% handle_message(Ctx, Message) ->
%%%     ok = barrel_a2a_ctx:status(Ctx, working),
%%%     Result = run_local_agent(barrel_a2a_message:text(Message)),
%%%     {ok, Result}.
%%% '''
%%%
%%% Results:
%%%
%%% - `{ok, Result}': `Result' (text, a part, parts or an artifact)
%%%   becomes the final artifact and the task completes.
%%% - `{message, Message}': a direct reply with no task, allowed only
%%%   before any `barrel_a2a_ctx' call created one.
%%% - `{input_required, Message}' / `{auth_required, Message}': the
%%%   task pauses in that state; the next message on the task calls
%%%   `handle_message' again with `barrel_a2a_ctx:task/1' set.
%%% - `{reject, Message}': the task is rejected.
%%% - `ok': the handler drove the state itself through the ctx and
%%%   the task stays as it left it (a task still `working' when the
%%%   handler returns `ok' is completed).
%%% - `{error, Reason}': the task fails; `Reason' may be a message,
%%%   text, or a `barrel_a2a_error' error for a protocol error.
%%%
%%% A crash fails the task. `throw({a2a_error, Error})' surfaces a
%%% protocol error to the caller of SendMessage.
%%%
%%% `handle_cancel/1' is optional. It runs when a client cancels a
%%% task whose handler is still running; the handler worker is then
%%% killed. Handlers that need cooperative cancellation poll
%%% `barrel_a2a_ctx:cancelled/1'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_handler).

-export([invoke/3, invoke_cancel/2, normalize/1]).

-type result() ::
    {ok, barrel_a2a_message:content() | barrel_a2a:artifact()}
    | {message, barrel_a2a:message()}
    | {input_required, barrel_a2a:message() | binary()}
    | {auth_required, barrel_a2a:message() | binary()}
    | {reject, barrel_a2a:message() | binary()}
    | ok
    | {error, barrel_a2a:message() | binary() | barrel_a2a_error:error()}.

-type handler() :: module() | fun((barrel_a2a_ctx:ctx(), barrel_a2a:message()) -> result()).

-export_type([result/0, handler/0]).

-callback handle_message(barrel_a2a_ctx:ctx(), barrel_a2a:message()) -> result().
-callback handle_cancel(barrel_a2a_ctx:ctx()) -> ok.

-optional_callbacks([handle_cancel/1]).

%% @doc Validate a handler at server start.
-spec normalize(term()) -> {ok, handler()} | {error, term()}.
normalize(Fun) when is_function(Fun, 2) ->
    {ok, Fun};
normalize(Mod) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, _} ->
            case erlang:function_exported(Mod, handle_message, 2) of
                true -> {ok, Mod};
                false -> {error, {handler_missing_callback, Mod, handle_message}}
            end;
        {error, Reason} ->
            {error, {handler_not_loaded, Mod, Reason}}
    end;
normalize(Other) ->
    {error, {invalid_handler, Other}}.

-spec invoke(handler(), barrel_a2a_ctx:ctx(), barrel_a2a:message()) -> result().
invoke(Fun, Ctx, Message) when is_function(Fun, 2) -> Fun(Ctx, Message);
invoke(Mod, Ctx, Message) -> Mod:handle_message(Ctx, Message).

-spec invoke_cancel(handler(), barrel_a2a_ctx:ctx()) -> ok.
invoke_cancel(Mod, Ctx) when is_atom(Mod) ->
    case erlang:function_exported(Mod, handle_cancel, 1) of
        true -> Mod:handle_cancel(Ctx);
        false -> ok
    end;
invoke_cancel(_, _) ->
    ok.
