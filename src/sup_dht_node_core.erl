%  @copyright 2007-2012 Zuse Institute Berlin

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
%% @doc    Supervisor for each DHT node that is responsible for keeping
%%         processes running that are essential to the operation of the node.
%%
%%         If one of the supervised processes (dht_node, msg_delay or
%%         sup_dht_node_core_tx) fails, all will be re-started!
%%         Note that the DB is needed by the dht_node (and not vice-versa) and
%%         is thus started at first.
%% @end
%% @version $Id$
-module(sup_dht_node_core).
-author('schuett@zib.de').
-vsn('$Id$ ').

-behaviour(supervisor).

-export([start_link/2, init/1, check_config/0]).
-export([supspec/1, childs/1]).

-spec start_link(pid_groups:groupname(), Options::[tuple()]) ->
                        {ok, Pid::pid()} | ignore |
                        {error, Error::{already_started, Pid::pid()} |
                                       shutdown | term()}.
start_link(DHTNodeGroup, Options) ->
    supervisor:start_link(?MODULE, [DHTNodeGroup, Options]).

%% userdevguide-begin sup_dht_node_core:init
-spec init([{pid_groups:groupname(), Options::[tuple()]}]) ->
                  {ok, {{one_for_all, MaxRetries::pos_integer(),
                         PeriodInSeconds::pos_integer()},
                        [ProcessDescr::supervisor:child_spec()]}}.
init([DHTNodeGroup, _Options] = X) ->
    pid_groups:join_as(DHTNodeGroup, ?MODULE),
    supspec(X).
%% userdevguide-end sup_dht_node_core:init

-spec supspec(any()) -> {ok, {{one_for_all, MaxRetries::pos_integer(),
                         PeriodInSeconds::pos_integer()}, []}}.
supspec(_) ->
    {ok, {{one_for_all, 10, 1}, []}}.

-spec childs([{pid_groups:groupname(), Options::[tuple()]}]) ->
                    [ProcessDescr::supervisor:child_spec()].
childs([DHTNodeGroup, Options]) ->
    PaxosProcesses = util:sup_supervisor_desc(sup_paxos, sup_paxos,
                                              start_link, [{DHTNodeGroup, []}]),
    DHTNodeModule = config:read(dht_node),
    DHTNode = util:sup_worker_desc(dht_node, DHTNodeModule, start_link,
                                   [DHTNodeGroup, Options]),
    %% rbrcseq process working on the kv DB
    KV_RBRcseq = util:sup_worker_desc(
                   kv_rbrcseq, rbrcseq,
                   start_link,
                   [DHTNodeGroup,
                    _PidGroupsNameKV = kv_rbrcseq,
                    _DBSelectorKV = kv]),
    %% rbrcseq process working on the lease_db1 DB
    L1_RBRcseq = util:sup_worker_desc(
                   l1_rbrcseq, rbrcseq,
                   start_link,
                   [DHTNodeGroup,
                    _PidGroupsNameL1 = lease_db1,
                    _DBSelectorL1 = leases_1]),
    %% rbrcseq process working on the lease_db2 DB
    L2_RBRcseq = util:sup_worker_desc(
                   l2_rbrcseq, rbrcseq,
                   start_link,
                   [DHTNodeGroup,
                    _PidGroupsNameL2 = lease_db2,
                    _DBSelectorL2 = leases_2]),
    %% rbrcseq process working on the lease_db3 DB
    L3_RBRcseq = util:sup_worker_desc(
                   l3_rbrcseq, rbrcseq,
                   start_link,
                   [DHTNodeGroup,
                    _PidGroupsNameL3 = lease_db3,
                    _DBSelectorL3 = leases_3]),
    %% rbrcseq process working on the lease_db4 DB
    L4_RBRcseq = util:sup_worker_desc(
                   l4_rbrcseq, rbrcseq,
                   start_link,
                   [DHTNodeGroup,
                    _PidGroupsNameL4 = lease_db4,
                    _DBSelectorL4 = leases_4]),

    DHTNodeMonitor = util:sup_worker_desc(
                       dht_node_monitor, dht_node_monitor, start_link,
                       [DHTNodeGroup, Options]),
    TX =
        util:sup_supervisor_desc(sup_dht_node_core_tx, sup_dht_node_core_tx, start_link,
                                 [DHTNodeGroup]),
    [
     PaxosProcesses,
     KV_RBRcseq,
     L1_RBRcseq,
     L2_RBRcseq,
     L3_RBRcseq,
     L4_RBRcseq,
     DHTNodeMonitor,
     DHTNode,
     TX
    ].


%% @doc Checks whether config parameters for the sup_dht_node_core supervisor
%%      exist and are valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_module(dht_node).
