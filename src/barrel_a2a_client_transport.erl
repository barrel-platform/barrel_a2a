%%%-------------------------------------------------------------------
%%% @doc Client transport behaviour: one module per protocol binding.
%%%
%%% `barrel_a2a_client_http' implements the JSON-RPC and HTTP+JSON
%%% bindings; a gRPC binding registers itself with
%%% `barrel_a2a_client:connect/2' `transports' option. The client
%%% builds the A2A request object and the per-request headers
%%% (authentication, `A2A-Version', `A2A-Extensions'); the transport
%%% only carries them.
%%%
%%% Stream events are delivered to the owner process as
%%% `{a2a_stream, Ref, {event, StreamResponse}}',
%%% `{a2a_stream, Ref, {error, Error}}' and `{a2a_stream, Ref, done}'.
%%% A transport must send `done' (or an error) exactly once per
%%% stream, after the last event.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_client_transport).

-type conn() :: term().
-type stream_ref() :: term().
-type call_opts() :: #{
    headers => [{binary(), binary()}],
    timeout => timeout()
}.

-export_type([conn/0, stream_ref/0, call_opts/0]).

-callback connect(Interface :: barrel_a2a_agent_card:interface(), Opts :: map()) ->
    {ok, conn()} | {error, barrel_a2a_error:error()}.

-callback call(conn(), barrel_a2a:op(), barrel_a2a:object(), call_opts()) ->
    {ok, barrel_a2a:json()} | {error, barrel_a2a_error:error()}.

-callback stream(conn(), barrel_a2a:op(), barrel_a2a:object(), Owner :: pid(), call_opts()) ->
    {ok, stream_ref()} | {error, barrel_a2a_error:error()}.

-callback cancel_stream(conn(), stream_ref()) -> ok.

-callback close(conn()) -> ok.
