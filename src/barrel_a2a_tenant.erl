%%%-------------------------------------------------------------------
%%% @doc Tenant handling (specification 8.3.2 rule 4, proto
%%% `tenant' fields, `/{tenant}/' REST routes).
%%%
%%% A server may be configured with a tenant. Then the `tenant' field
%%% of every request, or the leading path segment on the REST binding,
%%% must equal it; other values are rejected as invalid parameters. A
%%% server without a tenant ignores the field.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_tenant).

-export([check/2, strip_prefix/2, request_tenant/1]).

-spec request_tenant(barrel_a2a:object()) -> binary() | undefined.
request_tenant(#{<<"tenant">> := T}) when is_binary(T), T =/= <<>> -> T;
request_tenant(_) -> undefined.

%% @doc Validate the request tenant against the configured one.
-spec check(binary() | undefined, binary() | undefined) ->
    ok | {error, barrel_a2a_error:error()}.
check(undefined, _Requested) ->
    ok;
check(Configured, Configured) ->
    ok;
check(_Configured, undefined) ->
    {error, barrel_a2a_error:invalid(<<"tenant">>, <<"tenant is required">>)};
check(_Configured, _Other) ->
    {error, barrel_a2a_error:invalid(<<"tenant">>, <<"unknown tenant">>)}.

%% @doc On the REST binding the tenant is the first path segment
%% after the base path: `/a2a/v1/{tenant}/tasks'. Returns the tenant
%% and the path with that segment removed when the server has a
%% tenant configured; otherwise the path unchanged.
-spec strip_prefix(binary() | undefined, {binary(), binary()}) ->
    {binary() | undefined, binary()}.
strip_prefix(undefined, {_Base, Path}) ->
    {undefined, Path};
strip_prefix(Tenant, {Base, Path}) ->
    Prefix = <<Base/binary, "/", Tenant/binary>>,
    PLen = byte_size(Prefix),
    case Path of
        <<Prefix:PLen/binary>> ->
            {Tenant, Base};
        <<Prefix:PLen/binary, $/, Rest/binary>> ->
            {Tenant, <<Base/binary, $/, Rest/binary>>};
        _ ->
            {undefined, Path}
    end.
