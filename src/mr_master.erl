%% @copyright 2007-2013 Zuse Institute Berlin

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

%% @author Jan Fajerski <fajerski@informatik.hu-berlin.de>
%% @doc Map reduce master file
%%      The master is in charge of orchestrating the single phases of the job.
%% @end
%%      So far it is the single point of failure. It should be replicated and
%%      it should have a mechanism to recover to an earlier stage of the job
%% @version $Id$
-module(mr_master).
-author('fajerski@zib.de').
-vsn('$Id$ ').

-define(TRACE(X, Y), io:format(X, Y)).
%% -define(TRACE(X, Y), ok).

-export([
         init_job/4,
         on/2
        ]).

-include("scalaris.hrl").

-type state() :: {Id::?RT:key(),
                  AckedInterval::intervals:interval(),
                  CurrentRound::non_neg_integer()}.

-type(message() :: {mr_master, mr_state:jobid(), snapshot, {work_done, [term()]},
                    mr:job_description(), comm:mypid()} |
                   {mr_master, mr_state:jobid(), phase_completed, intervals:interval()} |
                   {mr_master, mr_state:jobid(), job_completed, intervals:interval()} |
                   {mr_master, mr_state:jobid(), job_error, intervals:interval()}).

-spec init_job(dht_node_state:state(), nonempty_string(), mr:job_description(),
              comm:mypid()) ->
    dht_node_state:state().
init_job(State, JobId, Job, Client) ->
    Reply = comm:reply_as(comm:this(), 4, {mr_master, JobId, snapshot, '_', Job,
                                          Client}),
    comm:send_local(pid_groups:get_my(wpool),
                    {do_work, Reply, {snapshot}}),
    dht_node_state:set_mr_master_state(State, JobId,
                                       {dht_node_state:get(State, node_id),[], 0}).

-spec on(message(), dht_node_state:state()) -> dht_node_state:state().
on({mr_master, JobId, snapshot, {work_done, Data}, Job, Client}, State) ->
    FilteredData = filter_data(Data, element(2, Job)),
    {Id, _Acked, _Round} = dht_node_state:get_mr_master_state(State, JobId),
    ?TRACE("mr_master: starting job ~p~n", [JobId]),
    bulkowner:issue_bulk_distribute(uid:get_global_uid(),
                                    dht_node, 7,
                                    {mr, job, JobId,
                                     Id,
                                     Client, Job, '_'},
                                    FilteredData),
    State;

on({mr_master, JobId, phase_completed, Range}, State) ->
    {Id, I, Round} = dht_node_state:get_mr_master_state(State, JobId),
    NewInterval = intervals:union(I, Range),
    NewMRState = case intervals:is_all(NewInterval) of
        false ->
            ?TRACE("mr_master_~s: phase ~p not yet completed...~n",
                     [JobId, Round]),
            {Id, NewInterval, Round};
        _ ->
            ?TRACE("mr_master_~s: phase ~p completed...initiating next phase~n",
                     [JobId, Round]),
            bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(),
                                       {mr, next_phase, JobId, Round + 1}),
            {Id, [], Round + 1}
    end,
    dht_node_state:set_mr_master_state(State, JobId, NewMRState);

on({mr_master, JobId, job_completed, Range}, State) ->
    {Id, I, Round} = dht_node_state:get_mr_master_state(State, JobId),
    NewInterval = intervals:union(I, Range),
    case intervals:is_all(NewInterval) of
        false ->
            dht_node_state:set_mr_master_state(State, JobId, {Id, NewInterval, Round});
        _ ->
            ?TRACE("mr_master_~s: job completed...shutting down~n",
                     [JobId]),
            bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(),
                                       {mr, terminate_job, JobId}),
            dht_node_state:delete_mr_master_state(State, JobId)
    end;

on({mr_master, JobId, job_error, _Range}, State) ->
    ?TRACE("mr_master_~s: job crashed...shutting down~n",
             [JobId]),
    bulkowner:issue_bulk_owner(uid:get_global_uid(), intervals:all(),
                               {mr, terminate_job, JobId}),
    dht_node_state:delete_mr_master_state(State, JobId);

on(Msg, State) ->
    ?TRACE("~p mr_master: revceived ~p~n",
           [comm:this(), Msg]),
    State.

-spec filter_data([{?RT:key(),
                   {{string(), term()} | {atom(), string(), term()}},
                   db_dht:version()}],
                  [mr:option()]) -> mr_state:data_list().
filter_data(Data, Options) ->
    case lists:keyfind(tag, 1, Options) of
        {tag, FilterTag} ->
            ?TRACE("Filtering! tag is ~p~ndata: ~p~n", [FilterTag, Data]),
            [{?RT:hash_key(K), K, V} || {_HashedKey, {Tag, K, V}, _Version} <- Data, Tag =:= FilterTag];
        false ->
            [{?RT:hash_key(K), K, V} || {_HashedKey, {K, V}, _Version} <- Data]
    end.
