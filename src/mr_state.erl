%  @copyright 2012 Zuse Institute Berlin

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

%% @author Jan Fajerski <fajerski@zib.de>
%% @doc state for one map reduce job
%% @version $Id$
-module(mr_state).
-author('fajerski@zib.de').
-vsn('$Id$').

-define(TRACE(X, Y), ok).
%% -define(TRACE(X, Y), io:format(X, Y)).
%% -define(TRACE_SLIDE(X, Y), ok).
-define(TRACE_SLIDE(X, Y), io:format(X, Y)).

-define(DEF_OPTIONS, []).

-export([new/5
        , get/2
        , get_phase/1
        , is_acked_complete/1
        , set_acked/2
        , reset_acked/2
        , next_phase/1
        , is_last_phase/1
        , add_data_to_next_phase/2
        , accumulate_data/2
        , clean_up/1
        , split_slide_state/2
        , add_slide_data/1
        , get_slide_delta/2
        , add_slide_delta/2]).

-include("scalaris.hrl").
%% for ?required macro
-include("record_helpers.hrl").

-ifdef(with_export_type_support).
-export_type([data/0, jobid/0, state/0, fun_term/0, data_list/0]).
-endif.

-type(fun_term() :: {erlanon, fun()} | {jsanon, binary()}).

-type(data_list() :: [{?RT:key(), string(), term()}]).
%% data in ets table has the same format
-type(data_ets() :: ets:tab()).

-type(data() :: data_list() | data_ets()).

-type(phase() :: {PhaseNr::pos_integer(), map | reduce, fun_term(),
                     Input::data()}).

-type(jobid() :: nonempty_string()).

-record(state, {jobid       = ?required(state, jobid) :: jobid()
                , client    = null :: comm:mypid() | null
                , master    = null :: comm:mypid() | null
                , phases    = ?required(state, phases) :: [phase(),...]
                , options   = ?required(state, options) :: [mr:option()]
                , current   = 0 :: non_neg_integer()
                , acked     = {null, intervals:empty()} :: {null | uid:global_uid(),
                                                            intervals:interval()}
                , phase_res = ?required(state, phase_res) :: data()
               }).

-type(state() :: #state{}).

-spec get(state(), client | master) -> comm:mypid() | null;
         (state(), jobid)           -> nonempty_string();
         (state(), phases)          -> [phase()];
         (state(), options)         -> [mr:option()];
         (state(), phase_res)         -> db_ets:db();
         (state(), current)         -> non_neg_integer().
get(#state{client     = Client
           , master   = Master
           , jobid    = JobId
           , phases   = Phases
           , options  = Options
           , current  = Cur
           , phase_res  = PhaseRes
          }, Key) ->
    case Key of
        client   -> Client;
        master   -> Master;
        phases   -> Phases;
        options  -> Options;
        current  -> Cur;
        phase_res  -> PhaseRes;
        jobid    -> JobId
    end.

-spec new(jobid(), comm:mypid(), comm:mypid(), data_list(),
          mr:job_description()) ->
    state().
new(JobId, Client, Master, InitalData, {Phases, Options}) ->
    ?TRACE("mr_state: ~p~nnew state from: ~p~n", [comm:this(), {JobId, Client,
                                                                Master,
                                                                InitalData,
                                                                {Phases,
                                                                 Options}}]),
    InitalETS = ets:new(
                  list_to_atom(
                    lists:append(["mr_", JobId, "_1"])), [ordered_set]),
    ets:insert(InitalETS, InitalData),
    TmpETS = ets:new(
               list_to_atom(lists:append(["mr_", JobId, "_tmp"]))
               , [ordered_set, public]),
    ExtraData = [{1, InitalETS} |
                 [{I, ets:new(
                        list_to_atom(lists:flatten(io_lib:format("mr_~s_~p",
                                                                 [JobId, I])))
                        , [ordered_set])}
                  || I <- lists:seq(2, length(Phases))]],
    PhasesWithData = lists:zipwith(
            fun({MoR, Fun}, {Round, Data}) ->
                    {Round, MoR, Fun, Data}
            end, Phases, ExtraData),
    JobOptions = merge_with_default_options(Options, ?DEF_OPTIONS),
    NewState = #state{
                  jobid      = JobId
                  , client   = Client
                  , master   = Master
                  , phases   = PhasesWithData
                  , options  = JobOptions
                  , phase_res = TmpETS
          },
    NewState.

-spec next_phase(state()) -> state().
next_phase(State = #state{current = Cur}) ->
    State#state{current = Cur + 1}.

-spec is_last_phase(state()) -> boolean().
is_last_phase(#state{current = Cur, phases = Phases}) ->
    Cur =:= length(Phases).

-spec get_phase(state()) -> phase() | false.
get_phase(#state{phases = Phases, current = Cur}) ->
    lists:keyfind(Cur, 1, Phases).

-spec is_acked_complete(state()) -> boolean().
is_acked_complete(#state{acked = {_Ref, Interval}}) ->
    intervals:is_all(Interval).

-spec reset_acked(state(), uid:global_uid()) -> state().
reset_acked(State, NewRef) ->
    State#state{acked = {NewRef, intervals:empty()}}.

-spec set_acked(state(), {uid:global_uid(), intervals:interval()}) -> state().
set_acked(State = #state{acked = {Ref, Interval}}, {Ref, NewInterval}) ->
    State#state{acked = {Ref, intervals:union(Interval, NewInterval)}};
set_acked(State, _OldAck) ->
    State.

-spec add_data_to_next_phase(state(), data_list()) -> state().
add_data_to_next_phase(State = #state{phases = Phases, current = Cur}, NewData) ->
    case lists:keyfind(Cur + 1, 1, Phases) of
        {_Round, _MoR, _Fun, ETS} ->
            %% side effect is used here...only works with ets
            _ = accumulate_data(NewData, ETS),
            State;
        false ->
            %% someone tries to add data to nonexisting phase...do nothing
            State
    end.

-spec accumulate_data({?RT:client_key(), term()}, data_ets()) -> data_ets().
accumulate_data(Data, ETS) ->
    %%returns and handle V that are
    %%allready lists
    ?TRACE("accumulating ~p~n", [Data]),
    lists:foldl(fun({K, V}, ETSAcc) ->
                        HK = ?RT:hash_key(K),
                        acc_add_element(ETSAcc, {HK, K, V});
                   ({HK, K, V}, ETSAcc) ->
                        acc_add_element(ETSAcc, {HK, K, V})
                end,
                ETS,
                Data).

-spec acc_add_element(ets:tab(), {?RT:key(), ?RT:client_key(), term()} |
                                 {?RT:client_key(), term()}) ->
    ets:tab().
acc_add_element(ETS, {HK, K, V}) ->
    case ets:lookup(ETS, HK) of
        [] ->
            case is_list(V) of
                true ->
                    ets:insert(ETS, {HK, K, V});
                _ ->
                    ets:insert(ETS, {HK, K, [V]})
            end;
        [{HK, K, ExV}] ->
            case is_list(V) of
                true ->
                    ets:insert(ETS, {HK, K, V ++ ExV});
                _ ->
                    ets:insert(ETS, {HK, K, [V | ExV]})
            end
    end,
    ETS.

-spec merge_with_default_options(UserOptions::[mr:option()],
                                 DefaultOptions::[mr:option()]) ->
    JobOptions::[mr:option()].
merge_with_default_options(UserOptions, DefaultOptions) ->
    %% TODO merge by hand and skip everything that is not in DefaultOptions
    lists:keymerge(1,
                   lists:keysort(1, UserOptions),
                   lists:keysort(1, DefaultOptions)).

%% TODO fix types data as ets or list

-spec clean_up(state()) -> [true].
clean_up(#state{phases = Phases, phase_res = Tmp}) ->
    ets:delete(Tmp),
    lists:map(fun({_R, _MoR, _Fun, ETS}) ->
                      ets:delete(ETS)
              end, Phases).

-spec split_slide_state(state(), intervals:interval()) -> SlideState::state().
split_slide_state(#state{phases = Phases} = State, Interval) ->
    SlidePhases =
    lists:foldl(
      fun({Nr, MoR, Fun, ETS}, Slide) ->
              New = ets:foldl(fun({HK, _K, _V} = Entry, SlideAcc) ->
                                         case intervals:in(HK, Interval) of
                                             true ->
                                                 %% this creates a side effect...works
                                                 %% only with ets as data store
                                                 _ = db_ets:delete(ETS, HK),
                                                 [Entry | SlideAcc];
                                             false ->
                                                 SlideAcc
                                         end
                                 end,
                                 [], ETS),
              [{Nr, MoR, Fun, New} | Slide]
      end,
      [],
      Phases),
    ?TRACE_SLIDE("mr_ on ~p: sliding phases: ~p~n", [self(), SlidePhases]),
    State#state{phases = SlidePhases}.

-spec add_slide_data(state()) -> state().
add_slide_data(State = #state{phases = Phases, jobid = JobId}) ->
    ETSPhases = lists:map(fun({Round, MoR, Fun, List}) ->
                                 ETS = ets:new(
                                   list_to_atom(
                                     lists:flatten(io_lib:format("mr_~s_~p", [JobId, Round])))
                                   , [ordered_set]),
                                   _ = ets:insert(ETS, List),
                                  {Round, MoR, Fun, ETS}
                          end, Phases),
    TmpETS = ets:new(
               list_to_atom(lists:append(["mr_", JobId, "_tmp"]))
               , [ordered_set, public]),
    ?TRACE_SLIDE("mr_~p on ~p: received State: ~p~n", [JobId, self(), State]),
    State#state{phases = ETSPhases, phase_res = TmpETS}.


-spec get_slide_delta(state(), intervals:interval()) ->
    SlideData::{Round::pos_integer(), data()}.
get_slide_delta(#state{phases = Phases, current = Cur} = State, Interval) ->
    case lists:keyfind(Cur + 1, 1, Phases) of
        false ->
            {State, {Cur + 1, []}};
        {Nr, _MoR, _Fun, ETS} ->
            Moving = ets:foldl(fun({HK, _K, _V} = New, DeltaAcc) ->
                                          case intervals:in(HK, Interval) of
                                              true ->
                                                  %% this creates a side effect...works
                                                  %% only with ets as data store
                                                  _ = db_ets:delete(ETS, HK),
                                                  [New | DeltaAcc];
                                              false ->
                                                  DeltaAcc
                                          end
                                  end,
                                  [], ETS),
            {Nr, Moving}
    end.

-spec add_slide_delta(state(), Data::{Round::pos_integer(), [{string(),
                                                              term()}]}) ->
    state().
add_slide_delta(#state{phases = Phases} = State, {Round, SlideData}) ->
    case lists:keyfind(Round, 1, Phases) of
        false ->
            %% no further rounds; slide data should be empty in this case
            State;
        {_Round, _MoR, _Fun, ETS} ->
            _ = ets:insert(ETS, SlideData),
            State
    end.
