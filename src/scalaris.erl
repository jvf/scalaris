% @copyright 2007-2012 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc Starting and stopping the scalaris app.
%% @version $Id$
-module(scalaris).
-author('schuett@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

%% functions called by Erlangs init module, triggered via command line
%% (bin/scalarisctl and erl ... '-s scalaris')
-export([start/0, stop/0]).
%% (bin/scalarisctl and erl ... '-s scalaris cli')
-export([cli/0, process/1]).

%% functions called by application:start(scalaris)
%% triggered by ?MODULE:start/0.
-behaviour(application).
-export([start/2, stop/1]).

%% functions called by Erlangs init module, triggered via command line
%% (bin/scalarisctl and erl ... '-s scalaris')
-spec start() -> ok | {error, Reason::term()}.
start() ->
    _ = application:load(
          {application, scalaris,
           [{description, "scalaris"},
            {vsn, ?SCALARIS_VERSION},
            {mod, {scalaris, []}},
            {registered, []},
            {applications, [kernel, stdlib]},
            {env, []}
           ]}),
    %% preload at least the API modules (for Erlang shell usage)
    _ = code:ensure_loaded(api_dht),
    _ = code:ensure_loaded(api_dht_raw),
    _ = code:ensure_loaded(api_monitor),
    _ = code:ensure_loaded(api_pubsub),
    _ = code:ensure_loaded(api_rdht),
    _ = code:ensure_loaded(api_tx),
    _ = code:ensure_loaded(api_vm),
    _ = code:ensure_loaded(api_autoscale),
    _ = code:ensure_loaded(api_mr),
    _ = code:ensure_loaded(trace_mpath),
    application:start(scalaris).

-spec stop() -> ok | {error, Reason::term()}.
stop() ->
    application:stop(scalaris).

%% functions called by application:start(scalaris)
%% triggered by ?MODULE:start/0.
-spec start(StartType::normal, StartArgs::[])
        -> {ok, Pid::pid()}.
start(normal, []) ->
    util:if_verbose("~nAlready registered: ~p.~n", [erlang:registered()]),
    util:if_verbose("Running with node name ~p.~n", [node()]),
    config:init([]),
    _ = pid_groups:start_link(),
    case sup_scalaris:start_link() of
        % ignore -> {error, ignore}; % no longer needed as dialyzer states
        X = {ok, Pid} when is_pid(Pid) -> X
    end.

-spec stop(any()) -> ok.
stop(_State) ->
    ok.

%% functions called by Erlangs init module, triggered via command line
%% (bin/scalarisctl and erl ... '-s scalaris cli')
-spec cli() -> ok.
cli() ->
    case init:get_plain_arguments() of
        [NodeName | Args] ->
            Node = list_to_atom(NodeName),
            io:format("~p~n", [Node]),
            case rpc:call(Node, ?MODULE, process, [Args]) of
                {badrpc, Reason} ->
                    io:format("badrpc to ~p: ~p~n", [Node, Reason]),
                    init:stop(1),
                    receive nothing -> ok end;
                _ ->
                    init:stop(0),
                    receive nothing -> ok end
            end;
        _ ->
            print_usage(),
            init:stop(1),
            receive nothing -> ok end
    end.

-spec print_usage() -> ok.
print_usage() ->
    io:format("usage info~n", []).

-spec process([string()]) -> ok.
process(["stop"]) ->
    init:stop();
process(Args) ->
    io:format("got process(~p)~n", [Args]).
