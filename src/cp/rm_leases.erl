% @copyright 2007-2013 Zuse Institute Berlin

%  Licensed under the Apache License, Version 2.0 (the "License");
%  you may not use this file except in compliance with the License.
%  You may obtain a copy of the License at
%
%      http://www.apache.org/licenses/LICENSE-2.0
%
%  Unless required by applicable law or agreed to in writing, software
%  distributed under the License is distributed on an "AS IS" BASIS,
%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%  See the License for the specific language governing permissions and
%  limitations under the License.

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc    Ring maintenance with leases.
%% @end
%% @version $$
-module(rm_leases).
-author('schuett@zib.de').
-vsn('$Id$').

-behaviour(gen_component).
-include("scalaris.hrl").
-include("record_helpers.hrl").

%% gen_component callbacks
-export([start_link/1, init/1, on/2]).

-record(state, {
          takeovers     = ?required(state, takeovers) :: gb_tree()
         }).

-type state_t() :: #state{}.

-type state() :: state_t().

%% gen_component functions
%% @doc Starts the failure detector server
-spec start_link(pid_groups:groupname()) -> {ok, pid()} | ignore.
start_link(ServiceGroup) ->
    case config:read(leases) of
        true ->
            gen_component:start_link(?MODULE, fun ?MODULE:on/2, [],
                                     [wait_for_init, {erlang_register, ?MODULE},
                                      {pid_groups_join_as, ServiceGroup, ?MODULE}]);
        _ ->
            ignore
    end.

%% @doc Initialises the module with an empty state.
-spec init([]) -> state().
init([]) ->
    FilterFun = fun (Old, New, Reason) ->
                        OldRange = nodelist:node_range(Old),
                        NewRange = nodelist:node_range(New),
                        %case OldRange =/= NewRange of
                        %    true ->
                        %        log:log("the range has changed: ~w -> ~w (~w)",
                        %                [OldRange, NewRange, Reason]);
                        %    false ->
                        %        ok
                        %end,
                        case Reason of
                            {slide_finished, _} ->
                                false;
                            {add_subscriber} ->
                                false;
                            {node_crashed, _} ->
                                OldRange =/= NewRange;
                            {node_discovery} ->
                                OldRange =/= NewRange;
                            {unknown} -> % @todo ?
                                false
                        end
                end,
    ExecFun = fun (Pid, _Tag, Old, New) ->
                      comm:send_local(Pid, {rm_change, nodelist:node_range(Old),
                                            nodelist:node_range(New)})
              end,
    rm_loop:subscribe(self(), ?MODULE, FilterFun, ExecFun, inf),
    #state{
       takeovers=gb_trees:empty()
      }.

%% @private
-spec on(comm:message(), state()) -> state().
on({rm_change, OldRange, NewRange}, State) ->
    log:log("the range has changed: ~w -> ~w", [OldRange, NewRange]),
    log:log("state: ~w", [State]),
    compare_and_fix_rm_with_leases(State);

on({read_after_rm_change, _MissingRange, Result}, State) ->
    log:log("read_after_rm_change ~w", [Result]),
    case Result of
        {qread_done, _ReqId, _Round, Lease} ->
            Pid = comm:reply_as(self(), 3, {takeover_after_rm_change, Lease, '_'}),
            l_on_cseq:lease_takeover(Lease, Pid),
            add_takeover(State, Lease);
        _ ->
            log:log("not so well-formed qread-response"),
            State
    end;

on({takeover_after_rm_change, _Lease, Result}, State) ->
    log:log("takeover_after_rm_change ~w", [Result]),
    case Result of
        {takeover, failed, L, Error} ->
            case Error of
                {content_check_failed,lease_is_still_valid} ->
                    case is_current_takeover(State, L) of
                        {value, L2} ->
                            case l_on_cseq:get_timeout(L) =:= l_on_cseq:get_timeout(L2) of
                                true ->
                                    log:log("retry ~s", [lists:flatten(l_on_cseq:get_pretty_timeout(L))]),
                                    LeaseTimeout = l_on_cseq:get_timeout(L),
                                    Pid = comm:reply_as(self(), 3, {takeover_after_rm_change, L, '_'}),
                                    WaitTime = timer:now_diff(LeaseTimeout, os:timestamp()),
                                    log:log("retry ~s ~w", [lists:flatten(l_on_cseq:get_pretty_timeout(L)), WaitTime]),
                                    case WaitTime < 500*1000 of
                                        true ->
                                            l_on_cseq:lease_takeover(L, Pid);
                                        false ->
                                            PostponeBy = trunc(0.5 + WaitTime / (1000*1000)),
                                            log:log("delaying takeover by ~ws", [PostponeBy]),
                                            l_on_cseq:lease_takeover_after(PostponeBy, L, Pid)
                                    end,
                                    State;
                                false ->
                                    propose_new_neighbors(l_on_cseq:get_owner(L)),
                                    remove_takeover(State, L)
                            end;
                        none ->
                            propose_new_neighbors(l_on_cseq:get_owner(L)),
                            remove_takeover(State, L)
                    end;
                _ ->
                    propose_new_neighbors(l_on_cseq:get_owner(L)),
                    %log:log("unknown error in takeover_after_rm_change ~w", [Error]),
                    State
            end;
        {takeover, success, L2} ->
            log:log("takeover_after_rm_change success"),
            % @todo we call receive in an on-handler ?!?
            comm:send_local(pid_groups:get_my(dht_node), {get_state, comm:this(), lease_list}),
            LeaseList = receive
                            {get_state_response, L} ->
                                L
                        end,
            ActiveLease = lease_list:get_active_lease(LeaseList),
            Pid = comm:reply_as(self(), 4, {merge_after_rm_change, L2, ActiveLease, '_'}),
            l_on_cseq:lease_merge(L2, ActiveLease, Pid),
            State
    end;

on({merge_after_rm_change, _L2, _ActiveLease, Result}, State) ->
    log:log("merge after rm_change: ~w", [Result]),
    State;

on({merge_after_leave, _NewLease, _OldLease, Result}, State) ->
    log:log("merge after finish done: ~w", [Result]),
    State;

on({get_node_for_new_neighbor, {get_state_response, Node}}, State) ->
    rm_loop:propose_new_neighbors([Node]),
    State.

-spec compare_and_fix_rm_with_leases(state()) -> state().
compare_and_fix_rm_with_leases(State) ->
    % @todo we call receive in an on-handler ?!?
    comm:send_local(pid_groups:get_my(dht_node), {get_state, comm:this(), [lease_list, my_range]}),
    {LeaseList, MyRange} = receive
            {get_state_response, [{lease_list, L}, {my_range, Range}]} ->
                {L, Range}
             end,
    log:log("lease list ~w", [LeaseList]),
    ActiveRange = lease_list:get_active_range(LeaseList),
    MissingRange = intervals:minus(MyRange, ActiveRange),
    case intervals:is_empty(MissingRange) of
        true ->
            State;
        false ->
            log:log("missing range: ~w", [MissingRange]),
            LeaseId = l_on_cseq:id(MissingRange),
            Pid = comm:reply_as(self(), 3, {read_after_rm_change, MissingRange, '_'}),
            l_on_cseq:read(LeaseId, Pid),
            %#op{missing_range = MissingRange, found_leases = []};
            State
    end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% state management
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec add_takeover(state(), l_on_cseq:lease_t()) -> state().
add_takeover(#state{takeovers=Takeovers} = State, Lease) ->
    Id = l_on_cseq:get_id(Lease),
    case gb_trees:lookup(Id, Takeovers) of
        {value, _Val} ->
            % @todo ?!?
            State;
        none ->
            NewTakeovers = gb_trees:insert(Id, Lease, Takeovers),
            State#state{takeovers=NewTakeovers}
    end.

-spec remove_takeover(state(), l_on_cseq:lease_t()) -> state().
remove_takeover(#state{takeovers=Takeovers} = State, Lease) ->
    Id = l_on_cseq:get_id(Lease),
    NewTakeovers = gb_trees:delete_any(Id, Takeovers),
    State#state{takeovers=NewTakeovers}.

% @doc the given lease is the one we recorded earlier
-spec is_current_takeover(state(), l_on_cseq:lease_t()) -> {value, l_on_cseq:lease_t()} | none.
is_current_takeover(#state{takeovers=Takeovers}, L) ->
    Id = l_on_cseq:get_id(L),
    gb_trees:lookup(Id, Takeovers).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% utilities
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec propose_new_neighbors(comm:mypid() | nil) -> ok.
propose_new_neighbors(PidOrNil) ->
    log:log("somebody else updated this lease"),
    case PidOrNil of
        nil ->
            ok;
        Pid ->
            ReplyPid = comm:reply_as(comm:this(), 2, {get_node_for_new_neighbor, '_'}),
            comm:send(Pid, {get_state, ReplyPid, node}),
            ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% todo
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
