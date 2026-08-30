%%%-------------------------------------------------------------------
%%% @doc Container for listeners.
%%%
%%% Restart intensity is deliberately low: a listener whose port is
%%% taken fails on every restart, and looping on it hides the cause.
%%% Children are `transient' so a clean stop is final and a crash is
%%% retried a few times.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_listener_sup).

-behaviour(supervisor).

-export([start_link/0, start_listener/3, stop_listener/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_listener(term(), map(), barrel_a2a_listener:handler()) ->
    {ok, pid()} | {error, term()}.
start_listener(Id, Opts, Handler) ->
    Spec = #{
        id => Id,
        start => {barrel_a2a_listener, start_link, [Opts, Handler]},
        restart => transient,
        shutdown => 5000,
        type => worker
    },
    case supervisor:start_child(?MODULE, Spec) of
        {ok, Pid} ->
            {ok, Pid};
        {error, already_present} ->
            _ = supervisor:delete_child(?MODULE, Id),
            supervisor:start_child(?MODULE, Spec);
        {error, {already_started, Pid}} ->
            {ok, Pid};
        {error, {Reason, _Child}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec stop_listener(term()) -> ok | {error, not_found}.
stop_listener(Id) ->
    case supervisor:terminate_child(?MODULE, Id) of
        ok ->
            _ = supervisor:delete_child(?MODULE, Id),
            ok;
        {error, not_found} = E ->
            E
    end.

%% @private
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, []}}.
