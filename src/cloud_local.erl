% @copyright 2013 Zuse Institute Berlin

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

%% @author Maximilian Michels <michels@zib.de>
%% @doc CLOUD LOCAL starts or stops local erlang vms based on alarms defined for
%%      the autoscale process.
%%      The module is used by autoscale if the following option has been set in
%%      scalaris.local.cfg:
%%        {as_cloud_module, cloud_local}
%%      The following options can also be set:
%%        {cloud_local_min_vms, integer()}.
%%        {cloud_local_max_vms, integer()}.
%% @end
%% @version $Id$
-module(cloud_local).
-author('michels@zib.de').
-vsn('$Id$').

-behavior(cloud_beh).

-include("scalaris.hrl").

-export([init/0, get_number_of_vms/0, add_vms/1, remove_vms/1]).


%%%%%%%%%%%%%%%%%%%%%
%%%% Behavior methods
%%%%%%%%%%%%%%%%%%%%%

-spec init() -> ok.
init() ->
    case config:read(cloud_local_min_vms) of
        failed ->
            config:write(cloud_local_min_vms, 1),
            config:write(cloud_local_max_vms, ?PLUS_INFINITY);
        X -> X
    end,
    ok.


-spec get_vms() -> [string()].
get_vms() ->
    % only include VMs started by autoscale:
    _VMs = [Name || {Name, _EpmdPort} <- erlang:element(2, erl_epmd:names()),
                    re:run(Name, "autoscale_.*") =/= nomatch].

-spec get_number_of_vms() -> non_neg_integer().
get_number_of_vms() ->
    length(get_vms()).

-spec add_vms(integer()) -> ok.
add_vms(N) ->
    BaseScalarisPort = config:read(port),
    BaseYawsPort = config:read(yaws_port),
    {Mega, Secs, _} = now(),
    Time = Mega * 1000000 + Secs,
    SpawnFun = 
        fun (X) -> 
                 Port = find_free_port(BaseScalarisPort),
                 YawsPort = find_free_port(BaseYawsPort),
                 NodeName = lists:flatten(io_lib:format("autoscale_~p_~p", [Time, X])),
                 Cmd = lists:flatten(io_lib:format("./../bin/scalarisctl -e -detached -s -p ~p -y ~p -n ~s start", 
                                                   [Port, YawsPort, NodeName])),
                 io:format("Executing: ~p~n", [Cmd]),
                 NumberVMs = get_number_of_vms(),
                 _ = os:cmd(Cmd),
                 util:wait_for(fun() -> get_number_of_vms() =:= NumberVMs + 1 end),
                 timer:sleep(200)
        end,
    _ = [SpawnFun(X) || X <- lists:seq(1, N), get_number_of_vms() < config:read(cloud_local_max_vms)],
    ok.

-spec remove_vms(integer()) -> ok.
remove_vms(N) ->
    VMs = get_vms(),
    RemoveFun = 
        fun(NodeName) ->						
                Cmd = lists:flatten(io_lib:format("./../bin/scalarisctl -n ~s gstop", 
                                                  [NodeName])),
                NumberVMs = get_number_of_vms(),
                io:format("Executing: ~p~n", [Cmd]),
                _ = os:cmd(Cmd),
                util:wait_for(fun() -> get_number_of_vms() =:= NumberVMs - 1 end)
        end,
    _ = [RemoveFun(NodeName) || NodeName <- lists:sublist(VMs, N),
                                get_number_of_vms() > config:read(cloud_local_min_vms)],
    ok.

%%%%%%%%%%%%%%%%%%%
%%%% Helper methods
%%%%%%%%%%%%%%%%%%%
-spec find_free_port(comm_server:tcp_port() | [comm_server:tcp_port()] |
                         {From::comm_server:tcp_port(), To::comm_server:tcp_port()})
        -> comm_server:tcp_port().
find_free_port({From, To}) ->
    find_free_port(lists:seq(From, To));
find_free_port([Port | Rest]) when is_integer(Port) andalso Port >= 0 andalso Port =< 65535 ->
    case gen_tcp:listen(Port, []) of
        {ok, Socket} -> gen_tcp:close(Socket), 
                        Port;
        _ when Rest =:= [] -> find_free_port([Port+1]);
        _ -> find_free_port(Rest)
    end;
find_free_port([]) ->
    find_free_port([0]);
find_free_port(Port) ->
    find_free_port([Port]).
