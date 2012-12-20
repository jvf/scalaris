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

%%% @author Thorsten Schuett <schuett@zib.de>
%%% @doc    Utility Functions.
%%% @end
%% @version $Id$
-module(util).

-author('schuett@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-include_lib("common_test/include/ct.hrl").

-ifdef(with_export_type_support).
-export_type([time/0, time_utc/0]).
-endif.
-export([escape_quotes/1,
         min/2, max/2, log/2, log2/1, ceil/1, floor/1,
         logged_exec/1,
         randomelem/1, pop_randomelem/1, pop_randomelem/2,
         first_matching/2,
         get_stacktrace/0, get_linetrace/0, get_linetrace/1,
         dump/0, dump2/0, dump3/0, dumpX/1, dumpX/2,
         topDumpX/1, topDumpX/3,
         topDumpXEvery/3, topDumpXEvery/5, topDumpXEvery_helper/4,
         minus_all/2, minus_first/2,
         delete_if_exists/2,
         map_with_nr/3,
         par_map/2, par_map/3,
         lists_split/2, lists_keystore2/5,
         lists_partition3/2,
         lists_remove_at_indices/2,
         sleep_for_ever/0, shuffle/1, get_proc_in_vms/1,random_subset/2,
         gb_trees_largest_smaller_than/2, gb_trees_foldl/3, pow/2,
         zipfoldl/5, safe_split/2, '=:<'/2,
         split_unique/2, split_unique/3, split_unique/4,
         ssplit_unique/2, ssplit_unique/3, ssplit_unique/4,
         smerge2/2, smerge2/3, smerge2/4,
         is_unittest/0, make_filename/1,
         app_get_env/2,
         timestamp2us/1, us2timestamp/1,
         time_plus_s/2, time_plus_ms/2, time_plus_us/2,
         readable_utc_time/1,
         for_to/3, for_to_ex/3, for_to_ex/4, for_to_fold/5,
         collect_while/1]).
-export([list_set_nth/3]).
-export([debug_info/0, debug_info/1]).
-export([print_bits/2, bin_xor/2]).
-export([if_verbose/1, if_verbose/2]).
-export([sup_worker_desc/3,
         sup_worker_desc/4,
         sup_supervisor_desc/3,
         sup_supervisor_desc/4,
         tc/3, tc/2, tc/1]).
-export([supervisor_terminate/1,
         supervisor_terminate_childs/1,
         wait_for/1, wait_for/2,
         wait_for_process_to_die/1,
         wait_for_table_to_disappear/2,
         ets_tables_of/1]).

-export([repeat/3, repeat/4, parallel_run/5]).

-export([empty/1]).

-export([extint2atom/1]).

% RRD helpers which don't belong to the rrd datastructure
-export([ rrd_combine_timing_slots/3
         , rrd_combine_timing_slots/4
    ]).

% feeder for tester
-export([readable_utc_time_feeder/1]).
-export([map_with_nr_feeder/3]).
-export([par_map_feeder/2, par_map_feeder/3]).
-export([lists_partition3_feeder/1]).

-export([sets_map/2]).

-type time() :: {MegaSecs::non_neg_integer(),
                 Secs::non_neg_integer(),
                 MicroSecs::non_neg_integer()}.

-type us_timestamp() :: non_neg_integer(). % micro seconds since Epoch

-type time_utc() :: {{1970..10000, 1..12, 1..31}, {0..23, 0..59, 0..59}}.

-type args() :: [term()].
-type accumulatorFun(T, U) :: fun((T, U) -> U).
-type repeat_params() :: parallel |
                         collect |
                         {accumulate, accumulatorFun(any(), R), R}. %{accumulate, fun, accumulator init value}

%% @doc Creates a worker description for a supervisor.
-spec sup_worker_desc(Name::atom() | string(), Module::module(), Function::atom())
        -> {Name::atom() | string(), {Module::module(), Function::atom(), Options::[]},
            permanent, brutal_kill, worker, []}.
sup_worker_desc(Name, Module, Function) ->
    sup_worker_desc(Name, Module, Function, []).

%% @doc Creates a worker description for a supervisor.
-spec sup_worker_desc(Name::atom() | string(), Module::module(), Function::atom(), Options::list())
        -> {Name::atom() | string(), {Module::module(), Function::atom(), Options::list()},
            permanent, brutal_kill, worker, []}.
sup_worker_desc(Name, Module, Function, Options) ->
    {Name, {Module, Function, Options}, permanent, brutal_kill, worker, []}.

%% @doc Creates a supervisor description for a supervisor.
-spec sup_supervisor_desc(Name::atom() | string(), Module::module(), Function::atom())
        -> {Name::atom() | string(), {Module::module(), Function::atom(), Options::[]},
            permanent, brutal_kill, supervisor, []}.
sup_supervisor_desc(Name, Module, Function) ->
    sup_supervisor_desc(Name, Module, Function, []).

%% @doc Creates a supervisor description for a supervisor.
-spec sup_supervisor_desc(Name::atom() | string(), Module::module(), Function::atom(), Options::list())
        -> {Name::atom() | string(), {Module::module(), Function::atom(), Options::list()},
            permanent, brutal_kill, supervisor, []}.
sup_supervisor_desc(Name, Module, Function, Args) ->
    {Name, {Module, Function, Args}, permanent, brutal_kill, supervisor, []}.


-spec supervisor_terminate(Supervisor::pid() | atom()) -> ok.
supervisor_terminate(SupPid) ->
    supervisor_terminate_childs(SupPid),
    case is_pid(SupPid) of
        true -> exit(SupPid, kill);
        false -> exit(whereis(SupPid), kill)
    end,
    wait_for_process_to_die(SupPid),
    ok.

-spec supervisor_terminate_childs(Supervisor::pid() | atom()) -> ok.
supervisor_terminate_childs(SupPid) ->
    ChildSpecs = supervisor:which_children(SupPid),
    Self = self(),
    _ = [ begin
              case Self =/= Pid andalso gen_component:is_gen_component(Pid) of
                  true ->
                      gen_component:bp_set_cond(Pid, fun(_M, _S) -> true end,
                                                about_to_kill);
                  _ -> ok
              end
          end ||  {_Id, Pid, _Type, _Module} <- ChildSpecs,
                  Pid =/= undefined ],
    _ = [ begin
              case Type of
                  supervisor ->
                      supervisor_terminate_childs(Pid);
                  _ -> ok
              end,
              Tables = ets_tables_of(Pid),
              _ = supervisor:terminate_child(SupPid, Id),
              wait_for_process_to_die(Pid),
              _ = [ wait_for_table_to_disappear(Pid, Tab) || Tab <- Tables ],
              supervisor:delete_child(SupPid, Id)
          end ||  {Id, Pid, Type, _Module} <- ChildSpecs,
                  Pid =/= undefined ],
    ok.

-spec wait_for(fun(() -> any())) -> ok.
wait_for(F) -> wait_for(F, 10).

-spec wait_for(fun(() -> any()), WaitTimeInMs::pos_integer()) -> ok.
wait_for(F, WaitTime) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(WaitTime),
                 wait_for(F)
    end.

-spec wait_for_process_to_die(pid() | atom()) -> ok.
wait_for_process_to_die(Name) when is_atom(Name) ->
    wait_for(fun() ->
                     case erlang:whereis(Name) of
                         undefined -> true;
                         Pid       -> not is_process_alive(Pid)
                     end
             end);
wait_for_process_to_die(Pid) ->
    wait_for(fun() -> not is_process_alive(Pid) end).

-spec wait_for_table_to_disappear(Pid::pid(), tid() | atom()) -> ok.
wait_for_table_to_disappear(Pid, Table) ->
    wait_for(fun() ->
                     case ets:info(Table, owner) of
                         undefined -> true;
                         Pid -> false;
                         _ -> true
                     end
             end).

-spec ets_tables_of(pid()) -> list().
ets_tables_of(Pid) ->
    Tabs = ets:all(),
    [ Tab || Tab <- Tabs, ets:info(Tab, owner) =:= Pid ].

%% @doc Escapes quotes in the given string.
-spec escape_quotes(String::string()) -> string().
escape_quotes(String) ->
    lists:foldr(fun escape_quotes_/2, [], String).

%-spec escape_quotes_(String::string(), Rest::string()) -> string().
-spec escape_quotes_(char(), string()) -> string().
escape_quotes_($", Rest) -> [$\\, $" | Rest];
escape_quotes_(Ch, Rest) -> [Ch | Rest].

%% @doc Variant of erlang:max/2 also taking ?PLUS_INFINITY_TYPE and
%%      ?MINUS_INFINITY_TYPE into account, e.g. for comparing keys.
%% @end
%%-spec max(?PLUS_INFINITY_TYPE, any()) -> ?PLUS_INFINITY_TYPE;
%%         (any(), ?PLUS_INFINITY_TYPE) -> ?PLUS_INFINITY_TYPE;
%%         (T | ?MINUS_INFINITY_TYPE, T | ?MINUS_INFINITY_TYPE) -> T.
-spec max(any(), any()) -> any().
max(?PLUS_INFINITY, _) -> ?PLUS_INFINITY;
max(_, ?PLUS_INFINITY) -> ?PLUS_INFINITY;
max(?MINUS_INFINITY, X) -> X;
max(X, ?MINUS_INFINITY) -> X;
max(A, B) ->
    case A > B of
        true -> A;
        false -> B
    end.

%% @doc Variant of erlang:min/2 also taking ?PLUS_INFINITY_TYPE and
%%      ?MINUS_INFINITY_TYPE into account, e.g. for comparing keys.
%% @end
%%-spec min(?MINUS_INFINITY_TYPE, any()) -> ?MINUS_INFINITY_TYPE;
%%         (any(), ?MINUS_INFINITY_TYPE) -> ?MINUS_INFINITY_TYPE;
%%         (T | ?PLUS_INFINITY_TYPE, T | ?PLUS_INFINITY_TYPE) -> T.
-spec min(any(), any()) -> any().
min(?MINUS_INFINITY, _) -> ?MINUS_INFINITY;
min(_, ?MINUS_INFINITY) -> ?MINUS_INFINITY;
min(?PLUS_INFINITY, X) -> X;
min(X, ?PLUS_INFINITY) -> X;
min(A, B) ->
    case A < B of
        true -> A;
        false -> B
    end.

-spec pow(integer(), non_neg_integer()) -> integer();
         (float(), non_neg_integer()) -> number().
pow(_X, 0) ->
    1;
pow(X, 1) ->
    X;
pow(X, 2) ->
    X * X;
pow(X, 3) ->
    X * X * X;
pow(X, Y) ->
    case Y rem 2 of
        0 ->
            Half = pow(X, Y div 2),
            Half * Half;
        1 ->
            Half = pow(X, Y div 2),
            Half * Half * X
    end.

%% @doc Logarithm of X to the base of Base.
-spec log(X::number(), Base::number()) -> float().
log(X, B) -> math:log10(X) / math:log10(B).

%% @doc Logarithm of X to the base of 2.
-spec log2(X::number()) -> float().
log2(X) -> log(X, 2).

%% @doc Returns the largest integer not larger than X. 
-spec floor(X::number()) -> integer().
floor(X) when X >= 0 ->
    erlang:trunc(X);
floor(X) ->
    T = erlang:trunc(X),
    case T == X of
        true -> T;
        _    -> T - 1
    end.

%% @doc Returns the smallest integer not smaller than X. 
-spec ceil(X::number()) -> integer().
ceil(X) when X < 0 ->
    erlang:trunc(X);
ceil(X) ->
    T = erlang:trunc(X),
    case T == X of
        true -> T;
        _    -> T + 1
    end.

-spec logged_exec(Cmd::string() | atom()) -> ok.
logged_exec(Cmd) ->
    Output = os:cmd(Cmd),
    OutputLength = length(Output),
    if
        OutputLength > 10 ->
            log:log(info, "exec", Cmd),
            log:log(info, "exec", Output),
            ok;
        true ->
            ok
    end.

%% @doc Gets the current stack trace. Use this method in order to get a stack
%%      trace if no exception was thrown.
-spec get_stacktrace() -> [{Module::atom(), Function::atom(), ArityOrArgs::byte() | [term()]} |
                           {Module::atom(), Function::atom(), ArityOrArgs::byte() | [term()], Sources::[term()]}].
get_stacktrace() ->
    % throw an exception for erlang:get_stacktrace/0 to return the actual stack trace
    case (try erlang:exit(a)
          catch exit:_ -> erlang:get_stacktrace()
          end) of
        % erlang < R15 : {util, get_stacktrace, 0}
        % erlang >= R15: {util, get_stacktrace, 0, _}
        %% drop head element as it was generated just above
        [T | ST] when erlang:element(1, T) =:= util andalso
                          erlang:element(2, T) =:= get_stacktrace andalso
                          erlang:element(3, T) =:= 0 -> ok;
        ST -> ST % just in case
    end,
    ST.

-spec get_linetrace() -> term() | undefined.
get_linetrace() ->
    erlang:get(test_server_loc).

-spec get_linetrace(Pid::pid()) -> term() | undefined.
get_linetrace(Pid) ->
    {dictionary, Dict} = erlang:process_info(Pid, dictionary),
    dump_extract_from_list_may_not_exist(Dict, test_server_loc).

%% @doc Extracts a given ItemInfo from an ItemList that has been returned from
%%      e.g. erlang:process_info/2 for the dump* methods.
-spec dump_extract_from_list
        ([{Item::atom(), Info::term()}], ItemInfo::memory | message_queue_len | stack_size | heap_size) -> non_neg_integer();
        ([{Item::atom(), Info::term()}], ItemInfo::messages) -> [tuple()];
        ([{Item::atom(), Info::term()}], ItemInfo::current_function) -> Fun::mfa();
        ([{Item::atom(), Info::term()}], ItemInfo::dictionary) -> [{Key::term(), Value::term()}].
dump_extract_from_list(List, Key) ->
    element(2, lists:keyfind(Key, 1, List)).

%% @doc Extracts a given ItemInfo from an ItemList or returns 'undefined' if
%%      there is no such item.
-spec dump_extract_from_list_may_not_exist
        ([{Item::term(), Info}], ItemInfo::term()) -> Info | undefined.
dump_extract_from_list_may_not_exist(List, Key) ->
    case lists:keyfind(Key, 1, List) of
        false -> undefined;
        X     -> element(2, X)
    end.

%% @doc Returns a list of all currently executed functions and the number of
%%      instances for each of them.
-spec dump() -> [{Fun::mfa(), FunExecCount::pos_integer()}].
dump() ->
    Info = [element(2, Fun) || X <- processes(),
                               Fun <- [process_info(X, current_function)],
                               Fun =/= undefined],
    FunCnt = dict:to_list(lists:foldl(fun(Fun, DictIn) ->
                                              dict:update_counter(Fun, 1, DictIn)
                                      end, dict:new(), Info)),
    lists:reverse(lists:keysort(2, FunCnt)).

%% @doc Returns information about all processes' memory usage.
-spec dump2() -> [{PID::pid(), [pos_integer() | mfa() | any()]}].
dump2() ->
    dumpX([memory, current_function, dictionary],
          fun(K, Value) ->
                  case K of
                      dictionary -> dump_extract_from_list_may_not_exist(Value, test_server_loc);
                      _          -> Value
                  end
          end).

%% @doc Returns various data about all processes.
-spec dump3() -> [{PID::pid(), Mem::non_neg_integer(), MsgQLength::non_neg_integer(),
                   StackSize::non_neg_integer(), HeapSize::non_neg_integer(),
                   Messages::[atom()], Fun::mfa()}].
dump3() ->
    dumpX([memory, message_queue_len, stack_size, heap_size, messages, current_function],
          fun(K, Value) ->
                  case K of
                      messages -> [element(1, V) || V <- Value];
                      _        -> Value
                  end
          end).

-spec default_dumpX_val_fun(K::atom(), Value::term()) -> term().
default_dumpX_val_fun(K, Value) ->
    case K of
        messages -> [element(1, V) || V <- Value];
        dictionary -> [element(1, V) || V <- Value];
        registered_name when Value =:= [] -> undefined;
        _        -> Value
    end.

%% @doc Returns various data about all processes.
-spec dumpX([ItemInfo::atom(),...]) -> [tuple(),...].
dumpX(Keys) ->
    dumpX(Keys, fun default_dumpX_val_fun/2).

%% @doc Returns various data about all processes.
-spec dumpX([ItemInfo::atom(),...], ValueFun::fun((atom(), term()) -> term())) -> [tuple(),...].
dumpX(Keys, ValueFun) ->
    lists:reverse(lists:keysort(2, dumpXNoSort(Keys, ValueFun))).

-spec dumpXNoSort([ItemInfo::atom(),...], ValueFun::fun((atom(), term()) -> term())) -> [tuple(),...].
dumpXNoSort(Keys, ValueFun) ->
    [{Pid, [ValueFun(Key, dump_extract_from_list(Data, Key)) || Key <- Keys]}
     || Pid <- processes(),
        undefined =/= (Data = process_info(Pid, Keys))].

%% @doc Convenience wrapper to topDumpX/3.
-spec topDumpX(Keys | Seconds | ValueFun) -> [{pid(), [Reductions | RegName | term(),...]},...]
        when is_subtype(Keys, [ItemInfo::atom()]),
             is_subtype(Seconds, pos_integer()),
             is_subtype(ValueFun, fun((atom(), term()) -> term())),
             is_subtype(Reductions, non_neg_integer()),
             is_subtype(RegName, atom()).
topDumpX(Keys) when is_list(Keys) ->
    topDumpX(Keys, fun default_dumpX_val_fun/2, 5);
topDumpX(Seconds) when is_integer(Seconds) ->
    topDumpX([], fun default_dumpX_val_fun/2, Seconds);
topDumpX(ValueFun) when is_function(ValueFun, 2) ->
    topDumpX([], ValueFun, 5).

%% @doc Gets the number of reductions for each process within the next Seconds
%%      and dumps some process data defined by Keys (sorted by the number of
%%      reductions).
-spec topDumpX(Keys, ValueFun, Seconds) -> [{pid(), [Reductions | RegName | term(),...]},...]
        when is_subtype(Keys, [ItemInfo::atom()]),
             is_subtype(Seconds, pos_integer()),
             is_subtype(ValueFun, fun((atom(), term()) -> term())),
             is_subtype(Reductions, non_neg_integer()),
             is_subtype(RegName, atom()).
topDumpX(Keys, ValueFun, Seconds) when is_integer(Seconds) andalso Seconds >= 1 ->
    Start = lists:keysort(1, dumpXNoSort([reductions, registered_name], ValueFun)),
    timer:sleep(1000 * Seconds),
    End = lists:keysort(1, dumpXNoSort([reductions, registered_name | Keys], ValueFun)),
    Self = self(),
    lists:reverse(
      lists:keysort(
        2, smerge2(Start, End,
                   fun(T1, T2) -> element(1, T1) =< element(1, T2) end,
                   fun(T1, T2) ->
                           % {<0.77.0>,[250004113,comm_server,692064]}
                           % io:format("T1=~.0p~nT2=~.0p~n", [T1, T2]),
                           {Pid, [Red1, RName]} = T1,
                           {Pid, [Red2, RName | Rest2]} = T2,
                           case Pid of
                               Self -> [];
                               _    -> [{Pid, [(Red2 - Red1), RName | Rest2]}]
                           end
                   end,
                   fun(_T1) -> [] end, % omit processes not alive at the end any more
                   fun(T2) -> [T2] end))).

%% @doc Convenience wrapper to topDumpXEvery/5.
-spec topDumpXEvery(Keys | Seconds | ValueFun, Subset::pos_integer(), StopAfter::pos_integer()) -> timer:tref()
        when is_subtype(Keys, [ItemInfo::atom()]),
             is_subtype(Seconds, pos_integer()),
             is_subtype(ValueFun, fun((atom(), term()) -> term())).
topDumpXEvery(Keys, Subset, StopAfter) when is_list(Keys) ->
    topDumpXEvery(Keys, fun default_dumpX_val_fun/2, 1, Subset, StopAfter);
topDumpXEvery(Seconds, Subset, StopAfter) when is_integer(Seconds) ->
    topDumpXEvery([], fun default_dumpX_val_fun/2, Seconds, Subset, StopAfter);
topDumpXEvery(ValueFun, Subset, StopAfter) when is_function(ValueFun, 2) ->
    topDumpXEvery([], ValueFun, 1, Subset, StopAfter).

%% @doc Calls topDumpX/3 every Seconds and prints the top Subset processes with
%%      the highest number of reductions. Stops after StopAfter seconds.
-spec topDumpXEvery(Keys, ValueFun, Seconds, Subset::pos_integer(), StopAfter::pos_integer()) -> timer:tref()
        when is_subtype(Keys, [ItemInfo::atom()]),
             is_subtype(Seconds, pos_integer()),
             is_subtype(ValueFun, fun((atom(), term()) -> term())).
topDumpXEvery(Keys, ValueFun, IntervalS, Subset, StopAfter)
  when is_integer(IntervalS) andalso IntervalS >= 1 andalso
           is_integer(Subset) andalso Subset >= 1 andalso
           is_integer(StopAfter) andalso StopAfter >= IntervalS ->
    {ok, TRef} = timer:apply_interval(1000 * IntervalS, ?MODULE, topDumpXEvery_helper,
                                      [Keys, ValueFun, IntervalS, Subset]),
    {ok, _} = timer:apply_after(1000 * StopAfter, timer, cancel, [TRef]),
    TRef.

%% @doc Helper function for topDumpXEvery/5 (export needed for timer:apply_after/4).
-spec topDumpXEvery_helper(Keys, ValueFun, Seconds, Subset::pos_integer()) -> ok
        when is_subtype(Keys, [ItemInfo::atom()]),
             is_subtype(Seconds, pos_integer()),
             is_subtype(ValueFun, fun((atom(), term()) -> term())).
topDumpXEvery_helper(Keys, ValueFun, Seconds, Subset) ->
    io:format("-----~n~.0p~n", [lists:sublist(topDumpX(Keys, ValueFun, Seconds), Subset)]).

%% @doc minus_all(M,N) : { x | x in M and x notin N}
-spec minus_all(List::[T], Excluded::[T]) -> [T].
minus_all([_|_] = L, [Excluded]) ->
    [E || E <- L, E =/= Excluded];
minus_all([_|_] = L, ExcludeList) ->
    ExcludeSet = sets:from_list(ExcludeList),
    [E || E <- L, not sets:is_element(E, ExcludeSet)];
minus_all([], _ExcludeList) ->
    [].

%% @doc Deletes the first occurrence of each element in Excluded from List.
%%      Similar to lists:foldl(fun lists:delete/2, NewValue1, ToDel) but more
%%      performant for out case.
-spec minus_first(List::[T], Excluded::[T]) -> [T].
minus_first([_|_] = L, [Excluded]) ->
    lists:delete(Excluded, L);
minus_first([_|_] = L, ExcludeList) ->
    minus_first2(L, ExcludeList, []);
minus_first([], _ExcludeList) ->
    [].

%% @doc Removes every item in Excluded only once from List.
-spec minus_first2(List::[T], Excluded::[T], Result::[T]) -> [T].
minus_first2([H | T], [_|_] = Excluded, Result) ->
    case delete_if_exists(Excluded, H, []) of
        {true,  Excluded2} -> minus_first2(T, Excluded2, Result);
        {false, Excluded2} -> minus_first2(T, Excluded2, [H | Result])
    end;
minus_first2([], _Excluded, Result) ->
    lists:reverse(Result);
minus_first2(L, [], Result) ->
    lists:reverse(Result, L).

%% @doc Removes Del from List if it is found. Stops on first occurrence.
-spec delete_if_exists(Del::T, List::[T]) -> {Found::boolean(), [T]}.
delete_if_exists(Del, List) ->
    delete_if_exists(List, Del, []).

%% @doc Removes Del from List if it is found. Stops on first occurrence.
-spec delete_if_exists(List::[T], Del::T, Result::[T]) -> {Found::boolean(), [T]}.
delete_if_exists([Del | T], Del, Result) ->
    {true, lists:reverse(Result, T)};
delete_if_exists([H | T], Del, Result) ->
    delete_if_exists(T, Del, [H | Result]);
delete_if_exists([], _Del, Result) ->
    {false, lists:reverse(Result)}.

-spec get_proc_in_vms(atom()) -> [comm:mypid()].
get_proc_in_vms(Proc) ->
    mgmt_server:node_list(),
    Nodes =
        receive
            ?SCALARIS_RECV({get_list_response, X}, X)
        after 2000 ->
            log:log(error,"[ util ] Timeout getting node list from mgmt server"),
            throw('mgmt_server_timeout')
        end,
    lists:usort([comm:get(Proc, DHTNode) || DHTNode <- Nodes]).

-spec sleep_for_ever() -> no_return().
sleep_for_ever() ->
    timer:sleep(5000),
    sleep_for_ever().

%% @doc Returns a random element from the given (non-empty!) list according to
%%      a uniform distribution.
-spec randomelem(List::[X,...]) -> X.
randomelem(List)->
    Length = length(List) + 1,
    RandomNum = randoms:rand_uniform(1, Length),
    lists:nth(RandomNum, List).
    
%% @doc Removes a random element from the (non-empty!) list and returns the
%%      resulting list and the removed element.
-spec pop_randomelem(List::[X,...]) -> {NewList::[X], PoppedElement::X}.
pop_randomelem(List) ->
    pop_randomelem(List, length(List)).
    
%% @doc Removes a random element from the first Size elements of a (non-empty!)
%%      list and returns the resulting list and the removed element. 
-spec pop_randomelem(List::[X,...], Size::non_neg_integer()) -> {NewList::[X], PoppedElement::X}.
pop_randomelem(List, Size) ->
    {Leading, [H | T]} = lists:split(randoms:rand_uniform(0, Size), List),
    {lists:append(Leading, T), H}.

%% @doc Returns a random subset of Size elements from the given list.
-spec random_subset(Size::pos_integer(), [T]) -> [T].
random_subset(0, _List) ->
    % having this special case here prevents unnecessary calls to erlang:length()
    [];
random_subset(Size, List) ->
    ListSize = length(List),
    shuffle_helper(List, [], Size, ListSize).

%% @doc Fisher-Yates shuffling for lists.
-spec shuffle([T]) -> [T].
shuffle(List) ->
    ListSize = length(List),
    shuffle_helper(List, [], ListSize, ListSize).

%% @doc Fisher-Yates shuffling for lists helper function: creates a shuffled
%%      list of length ShuffleSize.
-spec shuffle_helper(List::[T], AccResult::[T], ShuffleSize::non_neg_integer(), ListSize::non_neg_integer()) -> [T].
shuffle_helper([_|_] = _List, Acc, 0, _ListSize) ->
    Acc;
shuffle_helper([_|_] = List, Acc, Size, ListSize) ->
    {Leading, [H | T]} = lists:split(randoms:rand_uniform(0, ListSize), List),
    shuffle_helper(lists:append(Leading, T), [H | Acc], Size - 1, ListSize - 1);
shuffle_helper([], Acc, _Size, _ListSize) ->
    Acc.

-spec first_matching(List::[T], Pred::fun((T) -> boolean())) -> {ok, T} | failed.
first_matching([H | R], Pred) ->
    case Pred(H) of
        true -> {ok, H};
        _    -> first_matching(R, Pred)
    end;
first_matching([], _Pred) -> failed.

%% @doc Find the largest key in GBTree that is smaller than Key.
%%      Note: gb_trees offers only linear traversal or lookup of exact keys -
%%      we implement a more flexible binary search here despite gb_tree being
%%      defined as opaque.
-spec gb_trees_largest_smaller_than(Key, gb_tree()) -> {value, Key, Value::any()} | nil.
gb_trees_largest_smaller_than(_Key, {0, _Tree}) ->
    nil;
gb_trees_largest_smaller_than(MyKey, {_Size, InnerTree}) ->
    gb_trees_largest_smaller_than_iter(MyKey, InnerTree, true).

-spec gb_trees_largest_smaller_than_iter(Key, {Key, Value, Smaller::term(), Bigger::term()}, RightTree::boolean()) -> {value, Key, Value} | nil.
gb_trees_largest_smaller_than_iter(SearchKey, {Key, Value, Smaller, Bigger}, RightTree) ->
    case Key < SearchKey of
        true when RightTree andalso Bigger =:= nil ->
            % we reached the right end of the whole tree
            % -> there is no larger item than the current item
            {value, Key, Value};
        true ->
            case gb_trees_largest_smaller_than_iter(SearchKey, Bigger, RightTree) of
                {value, _, _} = AValue -> AValue;
                nil -> {value, Key, Value}
            end;
        _ ->
            gb_trees_largest_smaller_than_iter(SearchKey, Smaller, false)
    end;
gb_trees_largest_smaller_than_iter(_SearchKey, nil, _RightTree) ->
    nil.

%% @doc Foldl over gb_trees.
-spec gb_trees_foldl(fun((Key::any(), Value::any(), Acc) -> Acc), Acc, gb_tree()) -> Acc.
gb_trees_foldl(F, Acc, GBTree) ->
    gb_trees_foldl_iter(F, Acc, gb_trees:next(gb_trees:iterator(GBTree))).

-spec gb_trees_foldl_iter(fun((Key, Value, Acc) -> Acc), Acc,
                          {Key, Value, Iter::term()} | none) -> Acc.
gb_trees_foldl_iter(_F, Acc, none) ->
    Acc;
gb_trees_foldl_iter(F, Acc, {Key, Val, Iter}) ->
    gb_trees_foldl_iter(F, F(Key, Val, Acc), gb_trees:next(Iter)).

%% @doc Measures the execution time (in microseconds) for an MFA
%%      (does not catch exceptions as timer:tc/3 in older Erlang versions).
-spec tc(module(), atom(), list()) -> {integer(), term()}.
tc(M, F, A) ->
    Before = os:timestamp(),
    Val = apply(M, F, A),
    After = os:timestamp(),
    {timer:now_diff(After, Before), Val}.

%% @doc Measures the execution time (in microseconds) for Fun(Args)
%%      (does not catch exceptions as timer:tc/3 in older Erlang versions).
-spec tc(Fun::fun(), Args::list()) -> {integer(), term()}.
tc(Fun, Args) ->
    Before = os:timestamp(),
    Val = apply(Fun, Args),
    After = os:timestamp(),
    {timer:now_diff(After, Before), Val}.

%% @doc Measures the execution time (in microseconds) for Fun()
%%      (does not catch exceptions as timer:tc/3 in older Erlang versions).
-spec tc(Fun::fun()) -> {integer(), term()}.
tc(Fun) ->
    Before = os:timestamp(),
    Val = Fun(),
    After = os:timestamp(),
    {timer:now_diff(After, Before), Val}.

-spec zipfoldl(ZipFun::fun((X, Y) -> Z), FoldFun::fun((Z, Acc) -> Acc), L1::[X], L2::[Y], Acc) -> Acc.
zipfoldl(ZipFun, FoldFun, [L1H | L1R], [L2H | L2R], AccIn) ->
    zipfoldl(ZipFun, FoldFun, L1R, L2R, FoldFun(ZipFun(L1H, L2H), AccIn));
zipfoldl(_ZipFun, _FoldFun, [], [], AccIn) ->
    AccIn.

%% @doc Sorts like erlang:'=&lt;'/2 but also defines the order of integers/floats
%%      representing the same value.
-spec '=:<'(T, T) -> boolean().
'=:<'(T1, T2) ->
    case (T1 == T2) andalso (T1 =/= T2) of
        true when erlang:is_number(T1) andalso erlang:is_number(T2) ->
            erlang:is_integer(T1);
        true when erlang:is_tuple(T1) andalso erlang:is_tuple(T2) ->
            '=:<'(erlang:tuple_to_list(T1), erlang:tuple_to_list(T2));
        true when erlang:is_list(T1) andalso erlang:is_list(T2) ->
            % recursively check '=<'
            '=:<_lists'(T1, T2);
        _ -> erlang:'=<'(T1, T2)
    end.

%% @doc Compare two lists which are equal based on erlang:'=='/2.
-spec '=:<_lists'(T::list(), T::list()) -> boolean().
'=:<_lists'([H1 | R1], [H2 | R2]) ->
    case (H1 == H2) andalso (H1 =/= H2) of
        true  -> '=:<'(H1, H2);
        false -> '=:<_lists'(R1, R2)
    end;
'=:<_lists'([], []) -> true.

%% @doc Splits off N elements from List. If List is not large enough, the whole
%%      list is returned.
-spec safe_split(non_neg_integer(), [T]) -> {FirstN::[T], Rest::[T]}.
safe_split(N, List) when is_integer(N), N >= 0, is_list(List) ->
    safe_split(N, List, []).

-spec safe_split(non_neg_integer(), [T], [T]) -> {FirstN::[T], Rest::[T]}.
safe_split(0, L, R) ->
    {lists:reverse(R, []), L};
safe_split(N, [H | T], R) ->
    safe_split(N - 1, T, [H | R]);
safe_split(_N, [], R) ->
    {lists:reverse(R, []), []}.

%% @doc Splits L1 into a list of elements that are not contained in L2, a list
%%      of elements that both lists share and a list of elements unique to L2.
%%      Returned lists are sorted and contain no duplicates.
-spec split_unique(L1::[X], L2::[X]) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
split_unique(L1, L2) ->
    split_unique(L1, L2, fun erlang:'=<'/2).

%% @doc Splits L1 into a list of elements that are not contained in L2, a list
%%      of elements that are equal in both lists (according to the ordering
%%      function Lte) and a list of elements unique to L2.
%%      When two elements compare equal, the element from List1 is picked.
%%      Lte(A, B) should return true if A compares less than or equal to B in
%%      the ordering, false otherwise.
%%      Returned lists are sorted according to Lte and contain no duplicates.
-spec split_unique(L1::[X], L2::[X], Lte::fun((X, X) -> boolean())) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
split_unique(L1, L2, Lte) ->
    split_unique(L1, L2, Lte, fun(E1, _E2) -> E1 end).

%% @doc Splits L1 into a list of elements that are not contained in L2, a list
%%      of elements that are equal in both lists (according to the ordering
%%      function Lte) and a list of elements unique to L2.
%%      When two elements compare equal, EqSelect(element(L1), element(L2))
%%      chooses which of them to take.
%%      Lte(A, B) should return true if A compares less than or equal to B in
%%      the ordering, false otherwise.
%%      Returned lists are sorted according to Lte and contain no duplicates.
-spec split_unique(L1::[X], L2::[X], Lte::fun((X, X) -> boolean()), EqSelect::fun((X, X) -> X)) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
split_unique(L1, L2, Lte, EqSelect) ->
    L1Sorted = lists:usort(Lte, L1),
    L2Sorted = lists:usort(Lte, L2),
    ssplit_unique_helper(L1Sorted, L2Sorted, Lte, EqSelect, {[], [], []}).

%% @doc Splits L1 into a list of elements that are not contained in L2, a list
%%      of elements that both lists share and a list of elements unique to L2.
%%      Both lists must be sorted. Returned lists are sorted as well.
-spec ssplit_unique(L1::[X], L2::[X]) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
ssplit_unique(L1, L2) ->
    ssplit_unique(L1, L2, fun erlang:'=<'/2).

%% @doc Splits L1 into a list of elements that are not contained in L2, a list
%%      of elements that are equal in both lists (according to the ordering
%%      function Lte) and a list of elements unique to L2.
%%      When two elements compare equal, the element from List1 is picked.
%%      Both lists must be sorted according to Lte. Lte(A, B) should return
%%      true if A compares less than or equal to B in the ordering, false
%%      otherwise.
%%      Returned lists are sorted according to Lte.
-spec ssplit_unique(L1::[X], L2::[X], Lte::fun((X, X) -> boolean())) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
ssplit_unique(L1, L2, Lte) ->
    ssplit_unique(L1, L2, Lte, fun(E1, _E2) -> E1 end).

%% @doc Splits L1 into a list of elements that are not contained in L2, a list
%%      of elements that are equal in both lists (according to the ordering
%%      function Lte) and a list of elements unique to L2.
%%      When two elements compare equal, EqSelect(element(L1), element(L2))
%%      chooses which of them to take.
%%      Both lists must be sorted according to Lte. Lte(A, B) should return true
%%      if A compares less than or equal to B in the ordering, false otherwise.
%%      Returned lists are sorted according to Lte.
-spec ssplit_unique(L1::[X], L2::[X], Lte::fun((X, X) -> boolean()), EqSelect::fun((X, X) -> X)) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
ssplit_unique(L1, L2, Lte, EqSelect) ->
    ssplit_unique_helper(L1, L2, Lte, EqSelect, {[], [], []}).

%% @doc Helper function for ssplit_unique/4.
-spec ssplit_unique_helper(L1::[X], L2::[X], Lte::fun((X, X) -> boolean()), EqSelect::fun((X, X) -> X), {UniqueOldL1::[X], SharedOld::[X], UniqueOldL2::[X]}) -> {UniqueL1::[X], Shared::[X], UniqueL2::[X]}.
ssplit_unique_helper(L1 = [H1 | T1], L2 = [H2 | T2], Lte, EqSelect, {UniqueL1, Shared, UniqueL2}) ->
    LteH1H2 = Lte(H1, H2),
    LteH2H1 = Lte(H2, H1),
    case LteH1H2 andalso LteH2H1 of
        true ->
            ssplit_unique_helper(T1, L2, Lte, EqSelect, {UniqueL1, [EqSelect(H1, H2) | Shared], UniqueL2});
        false when LteH1H2 ->
            ssplit_unique_helper(T1, L2, Lte, EqSelect, {[H1 | UniqueL1], Shared, UniqueL2});
        false when LteH2H1 ->
            % the top of the shared list could be the same as the top of L2!
            case (Shared =:= []) orelse not (Lte(hd(Shared), H2) andalso Lte(H2, hd(Shared))) of
                true  -> ssplit_unique_helper(L1, T2, Lte, EqSelect, {UniqueL1, Shared, [H2 | UniqueL2]});
                false -> ssplit_unique_helper(L1, T2, Lte, EqSelect, {UniqueL1, Shared, UniqueL2})
            end
    end;
ssplit_unique_helper(L1, [], _Lte, _EqSelect, {UniqueL1, Shared, UniqueL2}) ->
    {lists:reverse(UniqueL1, L1), lists:reverse(Shared), lists:reverse(UniqueL2)};
ssplit_unique_helper([], L2 = [H2 | T2], Lte, EqSelect, {UniqueL1, Shared, UniqueL2}) ->
    % the top of the shared list could be the same as the top of L2 since
    % elements are only removed from L2 if an element of L1 is larger
    case Shared =:= [] orelse not (Lte(hd(Shared), H2) andalso Lte(H2, hd(Shared))) of
        true  ->
            {lists:reverse(UniqueL1), lists:reverse(Shared), lists:reverse(UniqueL2, L2)};
        false ->
            ssplit_unique_helper([], T2, Lte, EqSelect, {UniqueL1, Shared, UniqueL2})
    end.

%% @doc Merges two unique sorted lists into a single list.
-spec smerge2(L1::[X], L2::[X]) -> MergedList::[X].
smerge2(L1, L2) ->
    smerge2(L1, L2, fun erlang:'=<'/2).

%% @doc Merges two unique Lte-sorted lists into a single list.
-spec smerge2(L1::[X], L2::[X], Lte::fun((X, X) -> boolean())) -> MergedList::[X].
smerge2(L1, L2, Lte) ->
    smerge2(L1, L2, Lte, fun(E1, _E2) -> [E1] end).

%% @doc Merges two unique Lte-sorted lists into a single list.
-spec smerge2(L1::[X], L2::[X], Lte::fun((X, X) -> boolean()), EqSelect::fun((X, X) -> [X])) -> MergedList::[X].
smerge2(L1, L2, Lte, EqSelect) ->
    smerge2(L1, L2, Lte, EqSelect, fun(X) -> [X] end, fun(X) -> [X] end).

%% @doc Merges two unique Lte-sorted lists into a single list.
-spec smerge2(L1::[X], L2::[X], Lte::fun((X, X) -> boolean()), EqSelect::fun((X, X) -> [X]),
              FirstExist::fun((X) -> [X]), SecondExist::fun((X) -> [X])) -> MergedList::[X].
smerge2(L1, L2, Lte, EqSelect, FirstExist, SecondExist) ->
    smerge2_helper(L1, L2, Lte, EqSelect, FirstExist, SecondExist, []).

%% @doc Helper function for merge2/4.
-spec smerge2_helper(L1::[X], L2::[X], Lte::fun((X, X) -> boolean()),
        EqSelect::fun((X, X) -> [X]), FirstExist::fun((X) -> [X]),
        SecondExist::fun((X) -> [X]), OldMergedList::[X]) -> MergedList::[X].
smerge2_helper(L1 = [H1 | T1], L2 = [H2 | T2], Lte, EqSelect, FirstExist, SecondExist, ML) ->
    LteH1H2 = Lte(H1, H2),
    LteH2H1 = Lte(H2, H1),
    % note: need to reverse the results of EqSelect, FirstExist, SecondExist since ML is reversed
    if LteH1H2 andalso LteH2H1 ->
           smerge2_helper(T1, T2, Lte, EqSelect, FirstExist, SecondExist, lists:reverse(EqSelect(H1, H2)) ++ ML);
       LteH1H2 ->
           smerge2_helper(T1, L2, Lte, EqSelect, FirstExist, SecondExist, lists:reverse(FirstExist(H1)) ++ ML);
       LteH2H1 ->
           smerge2_helper(L1, T2, Lte, EqSelect, FirstExist, SecondExist, lists:reverse(SecondExist(H2)) ++ ML)
    end;
smerge2_helper(L1, [], _Lte, _EqSelect, FirstExist, _SecondExist, ML) ->
    lists:reverse(ML, lists:append([FirstExist(X) || X <- L1]));
smerge2_helper([], L2, _Lte, _EqSelect, _FirstExist, SecondExist, ML) ->
    lists:reverse(ML, lists:append([SecondExist(X) || X <- L2])).

%% @doc Try to check whether common-test is running.
-spec is_unittest() -> boolean().
is_unittest() ->
    Pid = self(),
    spawn(fun () ->
                  case catch ct:get_status() of
                      no_tests_running -> Pid ! {is_unittest, false};
                      {error, _} -> Pid ! {is_unittest, false};
                      {'EXIT', {undef, _}} -> Pid ! {is_unittest, false};
                      _ -> Pid ! {is_unittest, true}
                  end
          end),
    receive
        ?SCALARIS_RECV({is_unittest, Result}, Result)
    end.

-spec make_filename([byte()]) -> string().
make_filename(Name) ->
    re:replace(Name, "[^a-zA-Z0-9\-_@\.]", "_", [{return, list}, global]).

%% @doc Get an application environment variable. If it is undefined, Default is
%%      returned.
-spec app_get_env(Var::atom(), Default::T) -> T.
app_get_env(Var, Default) ->
    case application:get_env(Var) of
        {ok, Val} -> Val;
        _         -> app_check_known(),
                     Default
    end.

-spec app_check_known() -> ok.
app_check_known() ->
    case application:get_application() of
        {ok, scalaris } -> ok;
        undefined ->
            case is_unittest() of
                true -> ok;
                _    ->
                    %% error_logger:warning_msg("undefined application but no unittest~n"),
                    ok
            end;
        {ok, App} ->
            error_logger:warning_msg("unknown application: ~.0p~n", [App]),
            ok
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% time calculations
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% @doc convert os:timestamp() to microsecs
% See http://erlang.org/pipermail/erlang-questions/2008-December/040368.html
-spec timestamp2us(time()) -> us_timestamp().
timestamp2us({MegaSecs, Secs, MicroSecs}) ->
    (MegaSecs*1000000 + Secs)*1000000 + MicroSecs.

% @doc convert microsecs to os:timestamp()
-spec us2timestamp(us_timestamp()) -> time().
us2timestamp(Time) ->
    MicroSecs = Time rem 1000000,
    Time2 = (Time - MicroSecs) div 1000000,
    Secs = Time2 rem 1000000,
    MegaSecs = (Time2 - Secs) div 1000000,
    {MegaSecs, Secs, MicroSecs}.

-spec time_plus_us(Time::time(), Delta_MicroSeconds::integer()) -> time().
time_plus_us({MegaSecs, Secs, MicroSecs}, Delta) ->
    MicroSecs1 = MicroSecs + Delta,
    NewMicroSecs = MicroSecs1 rem 1000000,
    Secs1 = Secs + (MicroSecs1 div 1000000),
    NewSecs = Secs1 rem 1000000,
    MegaSecs1 = MegaSecs + (Secs1 div 1000000),
    NewMegaSecs = MegaSecs1 rem 1000000,
    {NewMegaSecs, NewSecs, NewMicroSecs}.

-spec time_plus_ms(Time::time(), Delta_MilliSeconds::integer()) -> time().
time_plus_ms(Time, Delta) ->
    time_plus_us(Time, Delta * 1000).

-spec time_plus_s(Time::time(), Delta_Seconds::integer()) -> time().
time_plus_s({MegaSecs, Secs, MicroSecs}, Delta) ->
    Secs1 = Secs + Delta,
    NewSecs = Secs1 rem 1000000,
    MegaSecs1 = MegaSecs + (Secs1 div 1000000),
    NewMegaSecs = MegaSecs1 rem 1000000,
    {NewMegaSecs, NewSecs, MicroSecs}.

-spec readable_utc_time_feeder({0..1000, 0..1000, 0..1000}) -> {erlang_timestamp()}.
readable_utc_time_feeder({A, B, C}) ->
    {{A, B, C}}.

-spec readable_utc_time(erlang_timestamp()) -> tuple().
readable_utc_time(TimeTriple) ->
    DateTime = calendar:now_to_universal_time(TimeTriple),
    erlang:append_element(DateTime, element(3, TimeTriple)).

%% acc=AccIn, for(i; I<=n; i++) { acc=AccFun(fun(i), acc) }
-spec for_to_fold(integer(), integer(), fun((integer()) -> X),
                  AccFun::fun((X, Acc) -> Acc), AccIn::Acc) -> Acc.
for_to_fold(I, N, Fun, AccFun, AccIn) when I =< N ->
    AccOut = AccFun(Fun(I), AccIn),
    for_to_fold(I + 1, N, Fun, AccFun, AccOut);
for_to_fold(_I, _N, _Fun, _AccFun, AccIn) ->
    AccIn.

%% for(i; I<=n; i++) { fun(i) }
-spec for_to(integer(), integer(), fun((integer()) -> any())) -> ok.
for_to(I, N, Fun) when I =< N ->
    Fun(I),
    for_to(I + 1, N, Fun);
for_to(_I, _N, _Fun) ->
    ok.

%% for(i; i<=n; i++) { Acc = [fun(i)|Acc] }
-spec for_to_ex(integer(), integer(), fun((integer()) -> T), [T]) -> [T].
for_to_ex(I, N, Fun, Acc) ->
    for_to_fold(I, N, Fun, fun(X, XAcc) -> [X | XAcc] end, Acc).

-spec for_to_ex(integer(), integer(), fun((integer()) -> T)) -> [T].
for_to_ex(I, N, Fun) ->
    for_to_ex(I, N, Fun, []).

-spec map_with_nr_feeder(1..2, [number()], integer()) -> {Fun::fun((number(), integer()) -> number()), List::[number()], integer()}.
map_with_nr_feeder(1, List, StartNr) ->
    {fun(X, I) -> X * I end, List, StartNr};
map_with_nr_feeder(2, List, StartNr) ->
    {fun(X, I) -> X + I end, List, StartNr}.

%% @doc Similar to lists:map/2 but also passes the current number to the fun:
%%      <tt>[a, b, c,...]</tt> maps to
%%      <tt>[fun(a, StartNr), fun(b, StartNr+1), fun(c, StartNr+2),...]</tt>
-spec map_with_nr(fun((A, integer()) -> B), List::[A], StartNr::integer()) -> [B].
map_with_nr(F, [H | T], Nr) ->
    [F(H, Nr) | map_with_nr(F, T, Nr + 1)];
map_with_nr(F, [], _Nr) when is_function(F, 2) -> [].

-type try_catch_result() :: ok | throw | error | exit.

%% @doc Helper for par_map/2.
-spec par_map_recv(Id::term(), {try_catch_result(), [B]}) -> {try_catch_result(), [B]}.
par_map_recv(E, {ErrorX, ListX}) ->
    receive ?SCALARIS_RECV({parallel_result, E, {ok, ResultY}},
                           {ErrorX, [ResultY | ListX]});
            ?SCALARIS_RECV({parallel_result, E, ErrorY},
                           {ErrorY, ListX})
    end.

-spec par_map_feeder(1..2, [number()]) -> {Fun::fun((number()) -> number()), List::[number()]}.
par_map_feeder(1, List) ->
    {fun(X) -> X * X end, List};
par_map_feeder(2, List) ->
    {fun(X) -> X + X end, List}.

%% @doc Parallel version of lists:map/2. Spawns a new process for each element
%%      in the list!
-spec par_map(Fun::fun((A) -> B), List::[A]) -> [B].
par_map(Fun, [E]) -> [Fun(E)];
par_map(Fun, [_|_] = List) ->
    _ = [erlang:spawn(?MODULE, parallel_run, [self(), Fun, [E], true, E]) || E <- List],
    case lists:foldr(fun par_map_recv/2, {{ok, ok}, []}, List) of
        {{ok, ok}, Result}   -> Result;
        {{Level, Reason}, _} -> erlang:Level(Reason) % throw the error here again
    end;
par_map(Fun, []) when is_function(Fun, 1)-> [].

%% @doc Helper for par_map/3.
-spec par_map_recv2(ListElem::term(), {try_catch_result(), [B], Id::non_neg_integer()})
        -> {try_catch_result(), [B], Id::non_neg_integer()}.
par_map_recv2(_E, {ErrorX, ListX, Id}) ->
    receive ?SCALARIS_RECV({parallel_result, Id, {ok, ResultY}},
                           {ErrorX, lists:reverse(ResultY, ListX), Id + 1});
            ?SCALARIS_RECV({parallel_result, Id, ErrorY},
                           {ErrorY, ListX, Id + 1})
    end.

-spec par_map_feeder(1..2, [number()], 1..50) -> {Fun::fun((number()) -> number()), List::[number()], 1..50}.
par_map_feeder(FunNr, List, MaxThreads) ->
    {Fun, List} = par_map_feeder(FunNr, List),
    {Fun, List, MaxThreads}.

%% @doc Parallel version of lists:map/2 with the possibility to limit the
%%      maximum number of processes being spawned.
-spec par_map(Fun::fun((A) -> B), List::[A], MaxThreads::pos_integer()) -> [B].
par_map(Fun, [E], _MaxThreads) -> [Fun(E)];
par_map(Fun, [_|_] = List, 1) -> lists:map(Fun, List);
par_map(Fun, [_|_] = List, MaxThreads) ->
    SplitList = lists_split(List, MaxThreads),
    lists:foldl(
      fun(E, Id) ->
              erlang:spawn(?MODULE, parallel_run,
                           [self(), fun(X) -> lists:map(Fun, X) end, [E], true, Id]),
              Id + 1
      end, 0, SplitList),
    % note: lists are reversed!
    case lists:foldl(fun par_map_recv2/2, {{ok, ok}, [], 0}, SplitList) of
        {{ok, ok}, Result, _}   -> Result;
        {{Level, Reason}, _, _} -> erlang:Level(Reason) % throw the error here again
    end;
par_map(Fun, [], _MaxThreads) when is_function(Fun, 1) -> [].

%% @doc Splits the given list into several partitions, returning a list of parts
%%      of the original list. Both the parts and their contents are reversed
%%      compared to the original list!
-spec lists_split([A], Partitions::pos_integer()) -> [[A]].
lists_split([X], _Partitions) -> [[X]];
lists_split([_|_] = List, 1) -> [lists:reverse(List)];
lists_split([_|_] = List, Partitions) ->
    BlockSize = length(List) div Partitions,
    case BlockSize < 1 of
        true -> lists:foldl(fun(E, Acc) -> [[E] | Acc] end, [], List);
        _    -> lists_split(List, BlockSize, 0, [], [])
    end;
lists_split([], _Partitions) -> [].

%% @doc Helper for lists_split/2.
-spec lists_split([A], BlockSize::pos_integer(), CurBlockSize::non_neg_integer(), [A], [[A]]) -> [[A]].
lists_split([_|_] = List, BlockSize, BlockSize, CurBlock, Result) ->
    lists_split(List, BlockSize, 0, [], [CurBlock | Result]);
lists_split([H | T], BlockSize, CurBlockSize, CurBlock, Result) ->
    lists_split(T, BlockSize, CurBlockSize + 1, [H | CurBlock], Result);
lists_split([], _BlockSize, _CurBlockSize, CurBlock, Result) ->
    [CurBlock | Result].

-spec lists_keystore2(Key::term(), NC::pos_integer(), List::[tuple()],
                      NS::pos_integer(), NewValue::term()) -> [tuple()].
lists_keystore2(Key, NC, [H | T], NS, NewValue) when element(NC, H) == Key ->
    [setelement(NS, H, NewValue) | T];
lists_keystore2(Key, NC, [H | T], NS, NewValue) ->
    [H | lists_keystore2(Key, NC, T, NS, NewValue)];
lists_keystore2(_Key, _N, [], _NS, _NewValue) ->
    [].

-spec lists_partition3_feeder([integer()])
        -> {fun((integer()) -> 1..3), [integer()]}.
lists_partition3_feeder(List) ->
    {fun(I) -> (I rem 3) + 1 end, List}.

-spec lists_partition3(Pred::fun((Elem :: T) -> 1..3), List::[T])
    -> {Pred1::[T], Pred2::[T], Pred3::[T]}.
lists_partition3(Pred, L) ->
    lists_partition3(Pred, L, [], [], []).

-spec lists_partition3_feeder([integer()], [integer()], [integer()], [integer()])
        -> {fun((integer()) -> 1..3), [integer()], [integer()], [integer()], [integer()]}.
lists_partition3_feeder(List, As, Bs, Cs) ->
    {fun(I) -> (I rem 3) + 1 end, List, As, Bs, Cs}.

lists_partition3(Pred, [H | T], As, Bs, Cs) ->
    case Pred(H) of
        1 -> lists_partition3(Pred, T, [H | As], Bs, Cs);
        2 -> lists_partition3(Pred, T, As, [H | Bs], Cs);
        3 -> lists_partition3(Pred, T, As, Bs, [H | Cs])
    end;
lists_partition3(Pred, [], As, Bs, Cs) when is_function(Pred, 1) ->
    {lists:reverse(As), lists:reverse(Bs), lists:reverse(Cs)}.

-spec lists_remove_at_indices([any(),...], [non_neg_integer(),...]) -> [any()].
lists_remove_at_indices([_|_] = List, [_|_] = Indices) -> lists_remove_at_indices(List, [], Indices, 0).

% PRED: Indices list should be non-empty
-spec lists_remove_at_indices([any()], [any()], [non_neg_integer()], non_neg_integer()) -> [any()].
lists_remove_at_indices(List, AccList, [], _CurrentIndex) ->
    lists:reverse(lists_prepend_reversed(List, AccList));
lists_remove_at_indices([_|ListTail], AccList, [CurrentIndex|IndexTail], CurrentIndex) ->
    lists_remove_at_indices(ListTail, AccList, IndexTail, CurrentIndex + 1);
lists_remove_at_indices([X|L], AccList, Indices, CurrentIndex) ->
    lists_remove_at_indices(L, [X | AccList], Indices, CurrentIndex + 1).

% prepend a list in reversed order to another list
-spec lists_prepend_reversed([any()], [any()]) -> [any()].
lists_prepend_reversed(L, To) -> lists:foldl(fun(El, Acc) -> [El | Acc] end, To, L).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% repeat
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Sequencial (default) or parallel run of function FUN with arguments ARGS TIMES-fold.
%%      Options as list/propertylist: collect, parallel, accumulate
%%          * collect (atom): all results of FUN will returned as a list
%%          * accumulate (tuple): {accumulate, accFun, accInit}
%%                                all results will be accumulated with accFun
%%          * parallel (atom): FUN will be called TIMES-fold in parallel.
%%                             Combination with collect and accumulate is supported.
%% @end
-spec repeat(fun(), args(), pos_integer()) -> ok.
repeat(Fun, Args, Times) ->
    i_repeat(Fun, Args, Times, [], none).
-spec repeat(fun(), args(), pos_integer(), [repeat_params()]) -> ok | any().
repeat(Fun, Args, Times, Params) ->
    NewParams = case proplists:is_defined(collect, Params) of
                    false -> Params;
                    _ -> [{accumulate, fun(I, R) -> [I | R] end, []} | 
                              proplists:delete(accumulate, Params)]
                end,
    Acc = lists:keyfind(accumulate, 1, NewParams),
    case proplists:is_defined(parallel, NewParams) of
        true -> 
            repeat(fun spawn/3, [?MODULE, parallel_run, [self(), Fun, Args, Acc =/= false, ok]], Times),
            case Acc of
                false -> ok;
                {_, AccFun, AccInit} -> parallel_collect(Times, AccFun, AccInit)
            end;
        _ -> i_repeat(Fun, Args, Times, NewParams, case Acc of
                                                       false -> none;
                                                       {_, _, I} -> I
                                                   end)
    end.

%-spec i_repeat(fun(), args(), non_neg_integer(), any()) -> ok | any().
i_repeat(_, _, 0, Params, Acc) ->
    case proplists:is_defined(accumulate, Params) of
        true -> Acc;
        _ -> ok
    end;
i_repeat(Fun, Args, Times, Params, Acc) ->    
    R = apply(Fun, Args),
    NewAcc = case lists:keyfind(accumulate, 1, Params) of
                 false -> Acc;
                 {_, AccFun, _} -> AccFun(R, Acc)
             end,
    i_repeat(Fun, Args, Times - 1, Params, NewAcc).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% parallel repeat helper functions 
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec parallel_run(pid(), fun(), args(), boolean(), Id::any()) -> ok.
parallel_run(SrcPid, Fun, Args, DoAnswer, Id) ->
    Res = try {ok, apply(Fun, Args)}
          catch Level:Reason -> {Level, Reason}
          end,
    case DoAnswer of
        true -> comm:send_local(SrcPid, {parallel_result, Id, Res});
        _ -> ok 
    end,
    ok.

-spec parallel_collect(non_neg_integer(), accumulatorFun(any(), U), U) -> U.
parallel_collect(0, _, Accumulator) ->
    Accumulator;
parallel_collect(ExpectedResults, AccuFun, Accumulator) ->
    receive ?SCALARIS_RECV({parallel_result, ok, {ok, Result}}, ok);
            ?SCALARIS_RECV({parallel_result, ok, Result}, ok) % TODO: throw the error here again?
    end,
    parallel_collect(ExpectedResults - 1, AccuFun, AccuFun(Result, Accumulator)).

-spec collect_while(GatherFun::fun((non_neg_integer()) -> {boolean(), T} | boolean())) -> [T].
collect_while(GatherFun) ->
    collect_while(GatherFun, 0).

-spec collect_while(GatherFun::fun((non_neg_integer()) -> {boolean(), T} | boolean()), non_neg_integer()) -> [T].
collect_while(GatherFun, Count) ->
    case GatherFun(Count) of
        {true, Data}  -> [Data | GatherFun(Count + 1)];
        {false, Data} -> [Data];
        true          -> GatherFun(Count + 1);
        false         -> []
    end.

-spec list_set_nth([A], pos_integer(), B) -> [A | B].
list_set_nth(L, Pos, Val) ->
    list_set_nth(L, Pos, Val, 1).

-spec list_set_nth([A], pos_integer(), B, pos_integer()) -> [A | B].
list_set_nth([_H | T], Pos, Val, Pos) ->
    [Val | T];
list_set_nth([H | T], Pos, Val, Cur) ->
    [H | list_set_nth(T, Pos, Val, Cur + 1)];
list_set_nth([], _Pos, _Val, _Cur) -> [].

-spec debug_info() -> [[{string(), term()}]].
debug_info() ->
    [ [ debug_info(Y) || Y <- pid_groups:members(X)] || X <- pid_groups:groups()].

-spec debug_info(pid()) -> [{string(), term()}];
                (atom() | string()) -> [[{string(), term()}]].
debug_info(PidName) when is_atom(PidName) ->
    [ debug_info(X) || X <- pid_groups:find_all(PidName)];
debug_info(Group) when is_list(Group) ->
    [ debug_info(X) || X <- pid_groups:members(Group)];
debug_info(Pid) when is_pid(Pid) ->
    {GenCompDesc, GenCompInfo} =
        case gen_component:is_gen_component(Pid) of
            true ->
                {Grp, Name} = pid_groups:group_and_name_of(Pid),
                comm:send_local(Pid , {web_debug_info, self()}),
                receive
                    ?SCALARIS_RECV({web_debug_info_reply, LocalKVs}, %% ->
                                   {[{"pidgroup", Grp}, {"pidname", Name}],
                                    LocalKVs})
                after 1000 -> {[], []}
                end;
            false -> {[], []}
        end,
    [{_, Memory}, {_, Reductions}, {_, QueueLen}] =
        process_info(Pid, [memory, reductions, message_queue_len]),
    [{"pid", pid_to_list(Pid)}]
        ++   GenCompDesc
        ++ [{"memory", Memory},
            {"reductions", Reductions},
            {"message_queue_len", QueueLen}]
        ++ GenCompInfo.

%% empty shell_prompt_func
-spec empty(any()) -> [].
empty(_) -> "".

-spec print_bits(fun((string(), [term()]) -> Result), binary()) -> Result.
print_bits(FormatFun, Binary) ->
    BitSize = erlang:bit_size(Binary),
    <<BinNr:BitSize>> = Binary,
    NrBits = lists:flatten(io_lib:format("~B", [BitSize])),
    FormatFun("~" ++ NrBits ++ ".2B", [BinNr]).

-spec if_verbose(string()) -> ok.
if_verbose(String) ->
    case app_get_env(verbose, false) of
        true ->  io:format(String);
        false -> ok
    end.

-spec if_verbose(string(), list()) -> ok.
if_verbose(String, Fmt) ->
    case app_get_env(verbose, false) of
        true ->  io:format(String, Fmt);
        false -> ok
    end.

-spec bin_xor(binary(), binary()) -> binary().
bin_xor(Binary1, Binary2) ->
    BitSize1 = erlang:bit_size(Binary1),
    BitSize2 = erlang:bit_size(Binary2),
    <<BinNr1:BitSize1>> = Binary1,
    <<BinNr2:BitSize2>> = Binary2,
    ResNr = BinNr1 bxor BinNr2,
    ResSize = erlang:max(BitSize1, BitSize2),
    <<ResNr:ResSize>>.

-spec extint2atom(atom() | integer()) -> atom().
extint2atom(X) when is_atom(X) -> X;
extint2atom(X) when is_integer(X) ->
    case X of
        %% lookup
        ?lookup_aux -> ?lookup_aux_atom;
        ?lookup_fin -> ?lookup_fin_atom;
        %% comm
        ?send_to_group_member -> ?send_to_group_member_atom;
        %% dht_node
        ?get_key_with_id_reply -> ?get_key_with_id_reply_atom;
        ?get_key -> ?get_key_atom;
        %% paxos
        ?proposer_accept -> ?proposer_accept_atom;
        ?acceptor_accept -> ?acceptor_accept_atom;
        ?paxos_id -> ?paxos_id_atom;
        %% transactions
        ?register_TP -> ?register_TP_atom;
        ?tx_tm_rtm_init_RTM -> ?tx_tm_rtm_init_RTM_atom;
        ?tp_do_commit_abort -> ?tp_do_commit_abort_atom;
        ?tx_tm_rtm_delete -> ?tx_tm_rtm_delete_atom;
        ?tp_committed -> ?tp_committed_atom;
        ?tx_state -> ?tx_state_atom;
        ?tx_id -> ?tx_id_atom;
        ?tx_item_id -> ?tx_item_id_atom;
        ?tx_item_state -> ?tx_item_state_atom;
        ?commit_client_id -> ?commit_client_id_atom;
        ?undecided -> ?undecided_atom;
        ?prepared -> ?prepared_atom;
        ?commit -> ?commit_atom;
        ?abort -> ?abort_atom;
        ?value -> ?value_atom;
        ?read -> ?read_atom;
        ?write -> ?write_atom;
        ?init_TP -> ?init_TP_atom;
        ?tp_do_commit_abort_fwd -> ?tp_do_commit_abort_fwd_atom
    end.

-spec sets_map(Fun :: fun((A :: any()) -> B :: any()), Set :: set()) -> [any()].
sets_map(Fun, Set) ->
    lists:reverse(sets:fold(fun (El, Acc) ->
                [Fun(El) | Acc]
        end, [], Set)).

%% @doc Combine the last N slots from a dump into one tuple. The number of slots to
%% combine is determined by Interval (in us): Take as many slots as needed to look
%% Interval-Epsilon microseconds back into the past.

-spec rrd_combine_timing_slots(DB :: rrd:rrd()
                               , CurrentTS :: time()
                               , Interval :: non_neg_integer()) ->
    {
        Sum :: number(), SquaresSum :: number(), Count :: non_neg_integer(), Min :: number(),
        Max :: number()
    } | undefined.
rrd_combine_timing_slots(DB, CurrentTS, Interval) ->
    rrd_combine_timing_slots(DB, CurrentTS, Interval, 0). % Epsilon = 10ms

-spec rrd_combine_timing_slots(DB :: rrd:rrd()
                               , CurrentTS :: time()
                               , Interval :: non_neg_integer()
                               , Epsilon :: non_neg_integer()) ->
    {
        Sum :: number(), SquaresSum :: number(), Count :: non_neg_integer(), Min :: number(),
        Max :: number()
    } | undefined.
rrd_combine_timing_slots(DB, CurrentTS, Interval, Epsilon) ->
    Slots = rrd:dump(DB),
    CalcStepLength = fun(Current, From, To) ->
            case timer:now_diff(Current,From) >= 0
                andalso timer:now_diff(To, Current) >= 0 of
                true  -> timer:now_diff(Current, From);
                false -> timer:now_diff(To, From)
            end

    end,
    Acc = lists:foldl(
            fun
                (_, {RemainingUS,_,_,_,_,_} = Acc) when (RemainingUS - Epsilon) =< 0 ->
                    Acc
                    ;
                ({From, To, {SlotSum,SlotSquared,SlotCount,SlotMin,SlotMax,_}},
                 {RemainingUS, Sum, SquaresSum, Count, Min, Max}) ->
                    StepLength = CalcStepLength(CurrentTS, From, To),
                    {
                        RemainingUS - StepLength
                        , Sum+SlotSum
                        , SquaresSum + SlotSquared
                        , Count + SlotCount
                        , erlang:min(Min, SlotMin)
                        , erlang:max(Max, SlotMax)
                    }
                    ;
                ({From, To, {SlotSum,SlotSquared,SlotCount,SlotMin,SlotMax,_}},
                 {RemainingUS}) ->
                    StepLength = CalcStepLength(CurrentTS, From, To),
                    {
                        RemainingUS - StepLength
                        , SlotSum
                        , SlotSquared
                        , SlotCount
                        , SlotMin
                        , SlotMax
                    }
            end, {Interval}, Slots),
    case Acc of
        {_, Sum, SquaresSum, Count, Min, Max} -> {Sum,SquaresSum,Count,Min,Max};
        {Interval} -> undefined
    end
    .
