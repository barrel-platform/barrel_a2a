%%%-------------------------------------------------------------------
%%% @doc The A2A error model and its binding mappings (3.3.2, 5.4).
%%%
%%% An error is a map `#{type, message, details}'. `type' is one of
%%% the A2A error names as a snake_case atom, a standard JSON-RPC
%%% error, an auth error, or a client-side transport error. `details'
%%% is the list of `@type'-tagged objects the specification defines;
%%% {@link error_info/2} and {@link bad_request/1} build the two
%%% well-known ones.
%%%
%%% The mapping functions turn one error into each binding's native
%%% shape, and the `from_*' functions do the reverse for the client.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_error).

-export([new/1, new/2, new/3, is_error/1, type/1, message/1, details/1]).
-export([error_info/2, error_info/3, bad_request/1, field_violation/2]).
-export([jsonrpc_code/1, http_status/1, grpc_status/1, reason/1]).
-export([to_jsonrpc/1, to_http_body/1, from_jsonrpc/1, from_http/2]).
-export([invalid/2, internal/1, transport/1]).

-define(DOMAIN, <<"a2a-protocol.org">>).
-define(ERROR_INFO_TYPE, <<"type.googleapis.com/google.rpc.ErrorInfo">>).
-define(BAD_REQUEST_TYPE, <<"type.googleapis.com/google.rpc.BadRequest">>).

-type type() ::
    task_not_found
    | task_not_cancelable
    | push_notification_not_supported
    | unsupported_operation
    | content_type_not_supported
    | invalid_agent_response
    | extended_agent_card_not_configured
    | extension_support_required
    | version_not_supported
    | parse_error
    | invalid_request
    | method_not_found
    | invalid_params
    | internal_error
    | unauthenticated
    | permission_denied
    | rate_limited
    | unavailable
    | timeout
    | transport
    | atom().

-type error() :: #{
    type := type(),
    message := binary(),
    details := [barrel_a2a:object()],
    %% Binding-specific extras: HTTP status seen by a client, raw code.
    _ => _
}.

-export_type([type/0, error/0]).

-spec new(type()) -> error().
new(Type) -> new(Type, default_message(Type)).

-spec new(type(), iodata()) -> error().
new(Type, Message) -> new(Type, Message, []).

-spec new(type(), iodata(), [barrel_a2a:object()]) -> error().
new(Type, Message, Details) ->
    #{type => Type, message => iolist_to_binary(Message), details => Details}.

-spec is_error(term()) -> boolean().
is_error(#{type := T, message := M, details := D}) when is_atom(T), is_binary(M), is_list(D) ->
    true;
is_error(_) ->
    false.

-spec type(error()) -> type().
type(#{type := T}) -> T.

-spec message(error()) -> binary().
message(#{message := M}) -> M.

-spec details(error()) -> [barrel_a2a:object()].
details(#{details := D}) -> D.

%% @doc Shorthand for an `invalid_params' error naming a field.
-spec invalid(iodata(), iodata()) -> error().
invalid(Field, Description) ->
    new(invalid_params, [<<"Invalid parameters: ">>, Description], [
        bad_request([field_violation(Field, Description)])
    ]).

-spec internal(term()) -> error().
internal(Reason) ->
    new(internal_error, io_lib:format("Internal error: ~0p", [Reason])).

-spec transport(term()) -> error().
transport(Reason) ->
    new(transport, io_lib:format("Transport error: ~0p", [Reason])).

%% @doc A `google.rpc.ErrorInfo' detail for an A2A error type.
-spec error_info(type(), map()) -> barrel_a2a:object().
error_info(Type, Metadata) ->
    error_info(Type, ?DOMAIN, Metadata).

-spec error_info(type(), binary(), map()) -> barrel_a2a:object().
error_info(Type, Domain, Metadata) ->
    Base = #{
        <<"@type">> => ?ERROR_INFO_TYPE,
        <<"reason">> => reason(Type),
        <<"domain">> => Domain
    },
    case map_size(Metadata) of
        0 -> Base;
        _ -> Base#{<<"metadata">> => Metadata}
    end.

%% @doc A `google.rpc.BadRequest' detail.
-spec bad_request([barrel_a2a:object()]) -> barrel_a2a:object().
bad_request(Violations) ->
    #{<<"@type">> => ?BAD_REQUEST_TYPE, <<"fieldViolations">> => Violations}.

-spec field_violation(iodata(), iodata()) -> barrel_a2a:object().
field_violation(Field, Description) ->
    #{
        <<"field">> => iolist_to_binary(Field),
        <<"description">> => iolist_to_binary(Description)
    }.

%% @doc UPPER_SNAKE reason without the `Error' suffix (10.6, 11.6).
-spec reason(type()) -> binary().
reason(Type) -> string:uppercase(atom_to_binary(Type, utf8)).

%%--------------------------------------------------------------------
%% Mappings (5.4)
%%--------------------------------------------------------------------

-spec jsonrpc_code(type()) -> integer().
jsonrpc_code(task_not_found) -> -32001;
jsonrpc_code(task_not_cancelable) -> -32002;
jsonrpc_code(push_notification_not_supported) -> -32003;
jsonrpc_code(unsupported_operation) -> -32004;
jsonrpc_code(content_type_not_supported) -> -32005;
jsonrpc_code(invalid_agent_response) -> -32006;
jsonrpc_code(extended_agent_card_not_configured) -> -32007;
jsonrpc_code(extension_support_required) -> -32008;
jsonrpc_code(version_not_supported) -> -32009;
jsonrpc_code(parse_error) -> -32700;
jsonrpc_code(invalid_request) -> -32600;
jsonrpc_code(method_not_found) -> -32601;
jsonrpc_code(invalid_params) -> -32602;
jsonrpc_code(internal_error) -> -32603;
%% Auth and flow-control errors have no assigned code; they travel as
%% server errors in the reserved range together with their HTTP status.
jsonrpc_code(unauthenticated) -> -32010;
jsonrpc_code(permission_denied) -> -32011;
jsonrpc_code(rate_limited) -> -32012;
jsonrpc_code(unavailable) -> -32013;
jsonrpc_code(timeout) -> -32014;
jsonrpc_code(_) -> -32603.

-spec http_status(type()) -> 200..599.
http_status(task_not_found) -> 404;
http_status(task_not_cancelable) -> 400;
http_status(push_notification_not_supported) -> 400;
http_status(unsupported_operation) -> 400;
http_status(content_type_not_supported) -> 400;
http_status(invalid_agent_response) -> 500;
http_status(extended_agent_card_not_configured) -> 400;
http_status(extension_support_required) -> 400;
http_status(version_not_supported) -> 400;
http_status(parse_error) -> 400;
http_status(invalid_request) -> 400;
http_status(method_not_found) -> 404;
http_status(invalid_params) -> 400;
http_status(internal_error) -> 500;
http_status(unauthenticated) -> 401;
http_status(permission_denied) -> 403;
http_status(rate_limited) -> 429;
http_status(unavailable) -> 503;
http_status(timeout) -> 504;
http_status(_) -> 500.

%% @doc gRPC status for the binding implemented in `livery_grpc_a2a'.
-spec grpc_status(type()) -> atom().
grpc_status(task_not_found) -> not_found;
grpc_status(task_not_cancelable) -> failed_precondition;
grpc_status(push_notification_not_supported) -> failed_precondition;
grpc_status(unsupported_operation) -> failed_precondition;
grpc_status(content_type_not_supported) -> invalid_argument;
grpc_status(invalid_agent_response) -> internal;
grpc_status(extended_agent_card_not_configured) -> failed_precondition;
grpc_status(extension_support_required) -> failed_precondition;
grpc_status(version_not_supported) -> failed_precondition;
grpc_status(parse_error) -> invalid_argument;
grpc_status(invalid_request) -> invalid_argument;
grpc_status(method_not_found) -> unimplemented;
grpc_status(invalid_params) -> invalid_argument;
grpc_status(internal_error) -> internal;
grpc_status(unauthenticated) -> unauthenticated;
grpc_status(permission_denied) -> permission_denied;
grpc_status(rate_limited) -> resource_exhausted;
grpc_status(unavailable) -> unavailable;
grpc_status(timeout) -> deadline_exceeded;
grpc_status(_) -> internal.

http_status_name(400) -> <<"INVALID_ARGUMENT">>;
http_status_name(401) -> <<"UNAUTHENTICATED">>;
http_status_name(403) -> <<"PERMISSION_DENIED">>;
http_status_name(404) -> <<"NOT_FOUND">>;
http_status_name(429) -> <<"RESOURCE_EXHAUSTED">>;
http_status_name(500) -> <<"INTERNAL">>;
http_status_name(503) -> <<"UNAVAILABLE">>;
http_status_name(504) -> <<"DEADLINE_EXCEEDED">>.

%% @doc The JSON-RPC error object (9.5). A2A errors always carry an
%% `ErrorInfo' detail so the type survives the numeric code.
-spec to_jsonrpc(error()) -> barrel_a2a:object().
to_jsonrpc(#{type := Type, message := Message} = E) ->
    #{
        <<"code">> => jsonrpc_code(Type),
        <<"message">> => Message,
        <<"data">> => with_error_info(E)
    }.

%% @doc The `google.rpc.Status' JSON body of the REST binding (11.6).
-spec to_http_body(error()) -> barrel_a2a:object().
to_http_body(#{type := Type, message := Message} = E) ->
    Status = http_status(Type),
    #{
        <<"error">> => #{
            <<"code">> => Status,
            <<"status">> => http_status_name(Status),
            <<"message">> => Message,
            <<"details">> => with_error_info(E)
        }
    }.

with_error_info(#{type := Type, details := Details}) ->
    case
        lists:any(fun(D) -> maps:get(<<"@type">>, D, undefined) =:= ?ERROR_INFO_TYPE end, Details)
    of
        true -> Details;
        false -> [error_info(Type, #{}) | Details]
    end.

%% @doc Rebuild an error from a JSON-RPC error object.
-spec from_jsonrpc(barrel_a2a:object()) -> error().
from_jsonrpc(Obj) when is_map(Obj) ->
    Code = maps:get(<<"code">>, Obj, -32603),
    Message = to_bin(maps:get(<<"message">>, Obj, <<>>)),
    Details = details_list(maps:get(<<"data">>, Obj, [])),
    Type = type_from(Details, type_from_code(Code)),
    (new(Type, Message, Details))#{code => Code}.

%% @doc Rebuild an error from a REST error response.
-spec from_http(non_neg_integer(), barrel_a2a:json() | undefined) -> error().
from_http(Status, #{<<"error">> := Err}) when is_map(Err) ->
    Message = to_bin(maps:get(<<"message">>, Err, <<>>)),
    Details = details_list(maps:get(<<"details">>, Err, [])),
    Type = type_from(Details, type_from_status(Status)),
    (new(Type, Message, Details))#{http_status => Status};
from_http(Status, _) ->
    (new(type_from_status(Status), [<<"HTTP ">>, integer_to_binary(Status)]))#{
        http_status => Status
    }.

details_list(L) when is_list(L) -> [D || D <- L, is_map(D)];
details_list(_) -> [].

to_bin(B) when is_binary(B) -> B;
to_bin(Other) -> iolist_to_binary(io_lib:format("~0p", [Other])).

type_from(Details, Default) ->
    Reasons = [
        R
     || #{<<"@type">> := T, <<"reason">> := R} <- Details,
        T =:= ?ERROR_INFO_TYPE,
        is_binary(R)
    ],
    case Reasons of
        [Reason | _] -> type_from_reason(Reason, Default);
        [] -> Default
    end.

type_from_reason(Reason, Default) ->
    Known = [
        task_not_found,
        task_not_cancelable,
        push_notification_not_supported,
        unsupported_operation,
        content_type_not_supported,
        invalid_agent_response,
        extended_agent_card_not_configured,
        extension_support_required,
        version_not_supported,
        parse_error,
        invalid_request,
        method_not_found,
        invalid_params,
        internal_error,
        unauthenticated,
        permission_denied,
        rate_limited,
        unavailable,
        timeout
    ],
    case [T || T <- Known, reason(T) =:= Reason] of
        [T | _] -> T;
        [] -> Default
    end.

type_from_code(-32001) -> task_not_found;
type_from_code(-32002) -> task_not_cancelable;
type_from_code(-32003) -> push_notification_not_supported;
type_from_code(-32004) -> unsupported_operation;
type_from_code(-32005) -> content_type_not_supported;
type_from_code(-32006) -> invalid_agent_response;
type_from_code(-32007) -> extended_agent_card_not_configured;
type_from_code(-32008) -> extension_support_required;
type_from_code(-32009) -> version_not_supported;
type_from_code(-32010) -> unauthenticated;
type_from_code(-32011) -> permission_denied;
type_from_code(-32012) -> rate_limited;
type_from_code(-32013) -> unavailable;
type_from_code(-32014) -> timeout;
type_from_code(-32700) -> parse_error;
type_from_code(-32600) -> invalid_request;
type_from_code(-32601) -> method_not_found;
type_from_code(-32602) -> invalid_params;
type_from_code(_) -> internal_error.

type_from_status(401) -> unauthenticated;
type_from_status(403) -> permission_denied;
type_from_status(404) -> task_not_found;
type_from_status(400) -> invalid_params;
type_from_status(429) -> rate_limited;
type_from_status(503) -> unavailable;
type_from_status(504) -> timeout;
type_from_status(_) -> internal_error.

default_message(task_not_found) -> <<"Task not found">>;
default_message(task_not_cancelable) -> <<"Task cannot be canceled">>;
default_message(push_notification_not_supported) -> <<"Push notifications are not supported">>;
default_message(unsupported_operation) -> <<"This operation is not supported">>;
default_message(content_type_not_supported) -> <<"Incompatible content types">>;
default_message(invalid_agent_response) -> <<"Invalid agent response">>;
default_message(extended_agent_card_not_configured) -> <<"Extended agent card not configured">>;
default_message(extension_support_required) -> <<"A required extension is not supported">>;
default_message(version_not_supported) -> <<"Protocol version not supported">>;
default_message(parse_error) -> <<"Invalid JSON payload">>;
default_message(invalid_request) -> <<"Request payload validation error">>;
default_message(method_not_found) -> <<"Method not found">>;
default_message(invalid_params) -> <<"Invalid parameters">>;
default_message(internal_error) -> <<"Internal error">>;
default_message(unauthenticated) -> <<"Authentication required">>;
default_message(permission_denied) -> <<"Permission denied">>;
default_message(rate_limited) -> <<"Rate limit exceeded">>;
default_message(unavailable) -> <<"Service unavailable">>;
default_message(timeout) -> <<"Timed out">>;
default_message(transport) -> <<"Transport error">>;
default_message(Other) -> atom_to_binary(Other, utf8).
