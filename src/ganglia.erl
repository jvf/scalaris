% @copyright 2007-2011 Zuse Institute Berlin

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

%% @author Marie Hoffmann <hoffmann@zib.de>
%% @doc Ganglia monitoring interface.
%% @end
%% @version $Id$
-module(ganglia).
-author('hoffmann@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-export([start_link/0, start/0]).

-define(TRACE(X,Y), ok).
%-define(TRACE(X,Y), io:format(X, Y)).


-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case config:read(ganglia_enable) of
        true ->
            {ok, spawn_link(?MODULE, start, [])};
        false ->
            ignore
    end.

-spec start() -> no_return().
start() ->
    Last = erlang:now(),
    ganglia_loop(Last).

-spec ganglia_loop(PreviousTime::erlang_timestamp()) -> no_return().
ganglia_loop(_Last) ->
    % message statistics
    {Received, Sent, _Time} = comm_logger:dump(),
    update(Received, Sent),
    Now = erlang:now(),
    % transaction statistics
    % TODO: get statistics from the client monitor
%%     SinceLast = timer:now_diff(Now, Last),
%%     Timers = [],
%%     _ = [update_timer(Timer, SinceLast / 1000000.0) || Timer <- Timers],
    % vivaldi statistics
    monitor_per_dht_node(fun monitor_vivaldi_errors/2, pid_groups:groups_with(dht_node)),
    timer:sleep(config:read(ganglia_interval)),
    ganglia_loop(Now).

-spec update(Received::gb_tree(), Sent::gb_tree()) -> ok.
update(Received, Sent) ->
    _ = gmetric(both, "Erlang Processes", "int32", erlang:system_info(process_count), "Total Number"),
    _ = gmetric(both, "Memory used by Erlang processes", "int32", erlang:memory(processes_used), "Bytes"),
    _ = gmetric(both, "Memory used by ETS tables", "int32", erlang:memory(ets), "Bytes"),
    _ = gmetric(both, "Memory used by atoms", "int32", erlang:memory(atom), "Bytes"),
    _ = gmetric(both, "Memory used by binaries", "int32", erlang:memory(binary), "Bytes"),
    _ = gmetric(both, "Memory used by system", "int32", erlang:memory(system), "Bytes"),
    DHTNodesMemoryUsage = lists:sum([element(2, erlang:process_info(P, memory))
                                    || P <- pid_groups:find_all(dht_node)]),
    _ = gmetric(both, "Memory used by dht_nodes", "int32", DHTNodesMemoryUsage, "Bytes"),
    RRDMetrics = fetch_rrd_metrics(),
    LocalLoad = fetch_local_load(),
    case RRDMetrics of
        [] -> ok;
        _  ->  _ = [gmetric(both, Metric, Type, Value, Unit) || {Metric, Type, Value, Unit} <- RRDMetrics]
    end,
    _ = [gmetric(both, Metric, Type, Value, Unit) || {Metric, Type, Value, Unit} <- LocalLoad],
    traverse(received, gb_trees:iterator(Received)),
    traverse(sent, gb_trees:iterator(Sent)).

%% -spec update_timer({Timer::string(), Count::pos_integer(), Min::number(), Avg::number(), Max::number()}, SinceLast::number()) -> ok.
%% update_timer({Timer, Count, Min, Avg, Max}, SinceLast) ->
%%     _ = gmetric(both, lists:flatten(io_lib:format("~p_~s", [Timer, "min"])), "float", Min, "ms"),
%%     _ = gmetric(both, lists:flatten(io_lib:format("~p_~s", [Timer, "avg"])), "float", Avg, "ms"),
%%     _ = gmetric(both, lists:flatten(io_lib:format("~p_~s", [Timer, "max"])), "float", Max, "ms"),
%%     _ = gmetric(both, lists:flatten(io_lib:format("~p_~s", [Timer, "tp"])), "float", Count / SinceLast, "1/s"),
%%     ok.

-spec traverse(received | sent, Iter1::term()) -> ok.
traverse(RcvSnd, Iter1) ->
  case gb_trees:next(Iter1) of
    none -> ok;
    {Key, {Bytes, _Count}, Iter2} ->
      _ = gmetric(positive, lists:flatten(io_lib:format("~s ~p", [RcvSnd, Key])), "int32", Bytes, "Bytes"),
      traverse(RcvSnd, Iter2)
  end.

-spec gmetric(Slope::both | positive, Metric::string(), Type::string(), Value::number(), Unit::string()) -> string().
gmetric(Slope, Metric, Type, Value, Unit) ->
    Cmd = lists:flatten(io_lib:format("gmetric --slope ~p --name ~p --type ~p --value ~p --units ~p~n",
                         [Slope, Metric, Type, Value, Unit])),
    Res = os:cmd(Cmd),
    ?TRACE("~s: ~w~n", [Cmd, Res]),
    Res.

-spec monitor_vivaldi_errors(pid_groups:groupname(), non_neg_integer()) -> ok | string().
monitor_vivaldi_errors(Group, Idx) ->
    case pid_groups:pid_of(Group, vivaldi) of
        failed ->
            ok;
        Vivaldi ->
            comm:send_local(Vivaldi, {get_coordinate, comm:this()}),
            receive
                ?SCALARIS_RECV(
                    {vivaldi_get_coordinate_response, _, Error}, %% ->
                    gmetric(both, lists:flatten(io_lib:format("vivaldi_error_~p", [Idx])), "float", Error, "error")
                  )
            end
    end.

-spec monitor_per_dht_node(fun((pid_groups:groupname(), Idx::non_neg_integer()) -> any()),
                           [pid_groups:groupname(),...] | failed) -> non_neg_integer().
monitor_per_dht_node(F, Nodes) ->
    DHTNodes = lists:sort(Nodes),
    lists:foldl(fun (Group, Idx) ->
                        _ = F(Group, Idx),
                        Idx + 1
                end, 0, DHTNodes).

-spec fetch_rrd_metrics() -> list().
fetch_rrd_metrics() ->
    case pid_groups:pid_of("clients_group", monitor) of
        failed -> [];
        ClientMonitor ->
            case monitor:get_rrds(ClientMonitor, [{api_tx, 'req_list'}]) of
                undefined -> [];
                [{_, _, RRD}] ->
                    case rrd:dump(RRD) of
                        [H | _] ->
                            {From_, To_, Value} = H,
                            Diff_in_s = timer:now_diff(To_, From_) div 1000000,
                            {Sum, _Sum2, Count, _Min, _Max, _Hist} = Value,
                            AvgPerS = Count / Diff_in_s,
                            Avg = Sum / Count,
                            [{"tx latency", "float", Avg, "ms"},
                             {"transactions/s", "float", AvgPerS, "1/s"}];
                        _ -> []
                    end
            end
    end.

% @doc aggregate the number of key-value pairs stored in this VM
-spec fetch_local_load() -> list().
fetch_local_load() ->
    Pairs = lists:foldl(fun (Pid, Agg) ->
                                Agg + get_load(Pid)
                        end, 0, pid_groups:find_all(dht_node)),
    [{"kv pairs", "int32", Pairs, "pairs"}].

% @doc get number of key-value pairs stored in given node
-spec get_load(Pid::comm:erl_local_pid()) -> integer().
get_load(Pid) ->
    comm:send_local(Pid, {get_node_details, comm:this(), [load]}),
    receive
        ?SCALARIS_RECV(
            {get_node_details_response, Details}, %% ->
            node_details:get(Details, load)
          )
    after 2000 ->
            0
    end.
