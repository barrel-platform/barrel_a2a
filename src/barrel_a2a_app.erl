%%%-------------------------------------------------------------------
%%% @doc OTP application callback.
%%%
%%% Starting the application starts supervisors only. No listener, no
%%% server and no client is created until the embedding application
%%% asks for one, so `barrel_a2a' is safe to include in any release.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    barrel_a2a_sup:start_link().

stop(_State) ->
    ok.
