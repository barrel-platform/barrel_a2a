%%%-------------------------------------------------------------------
%%% @doc Protocol constants and the types shared by every module.
%%%
%%% A2A objects are carried as the JSON maps the wire uses: binary
%%% camelCase keys, enum values as the strings the specification
%%% names (`<<"TASK_STATE_WORKING">>'), timestamps as ISO 8601 text,
%%% `metadata' and `data' as plain JSON terms. There is no
%%% intermediate representation; what `json:decode/1' returns is the
%%% object, and the `barrel_a2a_message', `barrel_a2a_task',
%%% `barrel_a2a_artifact', `barrel_a2a_part' and
%%% `barrel_a2a_agent_card' modules are accessors over that shape.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a).

-export([protocol_version/0, supported_versions/0, legacy_version/0]).
-export([media_type/0, well_known_card_path/0]).
-export([binding_jsonrpc/0, binding_rest/0, binding_grpc/0]).

-export_type([
    json/0,
    object/0,
    task/0,
    message/0,
    part/0,
    artifact/0,
    agent_card/0,
    task_status/0,
    stream_response/0,
    send_message_request/0,
    push_config/0,
    state/0,
    role/0,
    binding/0,
    principal/0,
    op/0
]).

%% Any JSON term as `json:decode/1' returns it.
-type json() :: null | boolean() | number() | binary() | [json()] | #{binary() => json()}.
-type object() :: #{binary() => json()}.

-type task() :: object().
-type message() :: object().
-type part() :: object().
-type artifact() :: object().
-type agent_card() :: object().
-type task_status() :: object().
-type stream_response() :: object().
-type send_message_request() :: object().
-type push_config() :: object().

%% Short atoms used by the accessor modules; `barrel_a2a_task_state'
%% converts to and from the wire strings.
-type state() ::
    submitted
    | working
    | completed
    | failed
    | canceled
    | input_required
    | rejected
    | auth_required
    | unspecified.

-type role() :: user | agent | unspecified.

%% A protocol binding as named in an Agent Card `supportedInterfaces'
%% entry. Custom bindings are URIs.
-type binding() :: binary().

%% Whatever the auth hook returned for the caller. `anonymous' when no
%% auth is configured.
-type principal() :: anonymous | term().

%% The eleven protocol operations.
-type op() ::
    send_message
    | send_streaming_message
    | get_task
    | list_tasks
    | cancel_task
    | subscribe_to_task
    | create_push_config
    | get_push_config
    | list_push_configs
    | delete_push_config
    | get_extended_agent_card.

%% @doc The protocol version this library implements, `Major.Minor'.
-spec protocol_version() -> binary().
protocol_version() -> <<"1.0">>.

%% @doc Versions a server accepts by default.
-spec supported_versions() -> [binary()].
supported_versions() -> [<<"1.0">>].

%% @doc The version a request without `A2A-Version' is taken to use
%% (specification 3.6.2).
-spec legacy_version() -> binary().
legacy_version() -> <<"0.3">>.

%% @doc The registered media type of the HTTP+JSON binding.
-spec media_type() -> binary().
media_type() -> <<"application/a2a+json">>.

%% @doc Well-known discovery path (specification 8.2).
-spec well_known_card_path() -> binary().
well_known_card_path() -> <<"/.well-known/agent-card.json">>.

-spec binding_jsonrpc() -> binding().
binding_jsonrpc() -> <<"JSONRPC">>.

-spec binding_rest() -> binding().
binding_rest() -> <<"HTTP+JSON">>.

-spec binding_grpc() -> binding().
binding_grpc() -> <<"GRPC">>.
