%  @copyright 2010-2013 Zuse Institute Berlin

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

%% @author Nico Kruber <kruber@zib.de>
%% @doc In-process Database using toke
%% @end
%% @version $Id$
-module(db_toke).
-author('kruber@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-behaviour(db_beh).

-type db_t() :: {{DB::pid(), FileName::string()}, SubscrTable::tid() | atom(),
                 {SnapTable::tid() | atom() | boolean(), non_neg_integer(), non_neg_integer()}}.

% Note: must include db_beh.hrl AFTER the type definitions for erlang < R13B04
% to work.
-include("db_beh.hrl").

-define(CKETS, ets).

-include("db_common.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% public functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Initializes a new database (will launch a process for it).
-spec new_() -> db_t().
new_() ->
    Dir = util:make_filename(atom_to_list(node())),
    FullDir = lists:flatten([config:read(db_directory), "/", Dir]),
    _ = case file:make_dir(FullDir) of
            ok -> ok;
            {error, eexist} -> ok;
            {error, Error} -> exit({db_toke, 'cannot create dir', FullDir, Error})
        end,
    {_Now_Ms, _Now_s, Now_us} = Now = erlang:now(),
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_local_time(Now),
    FileBaseName = util:make_filename(
                     io_lib:format("db_~B~B~B-~B~B~B\.~B.tch",
                                   [Year, Month, Day, Hour, Minute, Second, Now_us])),
    FullFileName = lists:flatten([FullDir, "/", FileBaseName]),
    new_db(FullFileName, [read, write, create, truncate]).

%% @doc Re-opens an existing database (will launch a process for it).
%%      BEWARE: use with caution in order to preserve consistency!
-spec open_(DBName::db_name()) -> db_t().
open_(FileName) ->
    new_db(FileName, [read, write]).

-spec new_db(FileName::string(),
             TokeOptions::[read | write | create | truncate | no_lock |
                           lock_no_block | sync_on_transaction]) -> db_t().
new_db(FileName, TokeOptions) ->
    DB = case toke_drv:start_link() of
             {ok, Pid} -> Pid;
             ignore ->
                 log:log(error, "[ Node ~w:db_toke ] process start returned 'ignore'", [self()]),
                 erlang:error({toke_failed, drv_start_ignore});
             {error, Error} ->
                 log:log(error, "[ Node ~w:db_toke ] ~.0p", [self(), Error]),
                 erlang:error({toke_failed, Error})
         end,
    case toke_drv:new(DB) of
        ok ->
            RandomName = randoms:getRandomString(),
            SubscrName = "db_" ++ RandomName ++ ":subscribers",
            case toke_drv:open(DB, FileName, TokeOptions) of
                ok     -> {{DB, FileName},
                           ets:new(list_to_atom(SubscrName), [ordered_set, private]),
                           {false,0,0}};
                Error2 -> log:log(error, "[ Node ~w:db_toke ] ~.0p", [self(), Error2]),
                          erlang:error({toke_failed, Error2})
            end;
        Error1 ->
            log:log(error, "[ Node ~w:db_toke ] ~.0p", [self(), Error1]),
            erlang:error({toke_failed, Error1})
    end.

%% @doc Deletes all contents of the given DB.
-spec close_(DB::db_t(), Delete::boolean()) -> any().
close_(State = {{DB, FileName}, _Subscr, _SnapState}, Delete) ->
    _ = call_subscribers(State, close_db),
    toke_drv:close(DB),
    toke_drv:delete(DB),
    toke_drv:stop(DB),
    case Delete of
        true ->
            case file:delete(FileName) of
                ok -> ok;
                {error, Reason} -> log:log(error, "[ Node ~w:db_toke ] deleting ~.0p failed: ~.0p",
                                           [self(), FileName, Reason])
            end;
        _ -> ok
    end.

%% @doc Returns the name of the DB, i.e. the path to its file, which can be
%%      used with open/1.
-spec get_name_(DB::db_t()) -> db_name().
get_name_({{_DB, FileName}, _Subscr, _SnapState}) ->
    FileName.

%% @doc Gets an entry from the DB. If there is no entry with the given key,
%%      an empty entry will be returned. The first component of the result
%%      tuple states whether the value really exists in the DB.
-spec get_entry2_(DB::db_t(), Key::?RT:key()) -> {Exists::boolean(), db_entry:entry()}.
get_entry2_({{DB, _FileName}, _Subscr, _SnapState}, Key) ->
    case toke_drv:get(DB, erlang:term_to_binary(Key, [{minor_version, 1}])) of
        not_found -> {false, db_entry:new(Key)};
        Entry     -> {true, erlang:binary_to_term(Entry)}
    end.

%% @doc Inserts a complete entry into the DB.
-spec set_entry_(DB::db_t(), Entry::db_entry:entry()) -> NewDB::db_t().
set_entry_(State = {{DB, _FileName}, _Subscr, {SnapTable,LiveLC,SnapLC}}, Entry) ->
    case db_entry:is_null(Entry) of
        true -> delete_entry_(State, Entry);
        _    -> 
            Key = db_entry:get_key(Entry),
            {_, OldEntry} = get_entry2_(State,Key),
            NewLiveLC = db_entry:update_lockcount(OldEntry,Entry,LiveLC),
            ok = toke_drv:insert(DB, erlang:term_to_binary(Key, [{minor_version, 1}]),
                                 erlang:term_to_binary(Entry, [{minor_version, 1}])),
            call_subscribers({{DB, _FileName}, _Subscr, {SnapTable,NewLiveLC,SnapLC}}, {write, Entry})
    end.

%% @doc Updates an existing (!) entry in the DB.
-spec update_entry_(DB::db_t(), Entry::db_entry:entry()) -> NewDB::db_t().
update_entry_(State, Entry) ->
    set_entry_(State, Entry).

%% @doc Removes all values with the given key from the DB.
-spec delete_entry_at_key_(DB::db_t(), ?RT:key()) -> NewDB::db_t().
delete_entry_at_key_(State, Key) ->
    delete_entry_at_key_(State, Key, erlang:term_to_binary(Key, [{minor_version, 1}])).

delete_entry_at_key_(State = {{DB, _FileName}, _Subscr, {SnapTable,LiveLC,SnapLC}}, Key, Key_) ->
    {_, OldEntry} = get_entry2_(State,Key),
    NewLiveLC = db_entry:update_lockcount(OldEntry,db_entry:new(Key),LiveLC),
    toke_drv:delete(DB, Key_),
    call_subscribers({{DB, _FileName}, _Subscr, {SnapTable,NewLiveLC,SnapLC}}, {delete, Key}).

%% @doc Returns the number of stored keys.
-spec get_load_(DB::db_t()) -> Load::integer().
get_load_({{DB, _FileName}, _Subscr, _SnapState}) ->
    % TODO: not really efficient (maybe store the load in the DB?)
    toke_drv:fold(fun (_K, _V, Load) -> Load + 1 end, 0, DB).

%% @doc Returns the number of stored keys in the given interval.
-spec get_load_(DB::db_t(), Interval::intervals:interval()) -> Load::integer().
get_load_(State = {{DB, _FileName}, _Subscr, _SnapState}, Interval) ->
    IsEmpty = intervals:is_empty(Interval),
    IsAll = intervals:is_all(Interval),
    if
        IsEmpty -> 0;
        IsAll   -> get_load_(State);
        true    ->
            toke_drv:fold(fun(Key_, _V, Load) ->
                                  Key = erlang:binary_to_term(Key_),
                                  case intervals:in(Key, Interval) of
                                      true -> Load + 1;
                                      _    -> Load
                                  end
                          end, 0, DB)
    end.

%% @doc Adds all db_entry objects in the Data list.
-spec add_data_(DB::db_t(), db_as_list()) -> NewDB::db_t().
add_data_(State = {{DB, _FileName}, _Subscr, _SnapState}, Data) ->
    % -> do not use set_entry (no further checks for changed keys necessary)
    _ = lists:foldl(
          fun(DBEntry, _) ->
              ok = toke_drv:insert(DB,
                                   erlang:term_to_binary(db_entry:get_key(DBEntry), [{minor_version, 1}]),
                                   erlang:term_to_binary(DBEntry, [{minor_version, 1}])),
              call_subscribers(State, {write, DBEntry})
          end, ok, Data),
    State.

%% @doc Splits the database into a database (first element) which contains all
%%      keys in MyNewInterval and a list of the other values (second element).
%%      Note: removes all keys not in MyNewInterval from the list of changed
%%      keys!
-spec split_data_(DB::db_t(), MyNewInterval::intervals:interval()) ->
         {NewDB::db_t(), db_as_list()}.
split_data_(State = {{DB, _FileName}, _Subscr, _SnapState}, MyNewInterval) ->
    % first collect all toke keys to remove from my db (can not delete while doing fold!)
    F = fun(_K, DBEntry_, HisList) ->
                DBEntry = erlang:binary_to_term(DBEntry_),
                case intervals:in(db_entry:get_key(DBEntry), MyNewInterval) of
                    true -> HisList;
                    _    -> [DBEntry | HisList]
                end
        end,
    HisList = toke_drv:fold(F, [], DB),
    % delete empty entries from HisList and remove all entries in HisList from the DB
    HisListFilt =
        lists:foldl(
          fun(DBEntry, L) ->
                  Key = db_entry:get_key(DBEntry),
                  toke_drv:delete(DB, erlang:term_to_binary(Key, [{minor_version, 1}])),
                  _ = call_subscribers(State, {split, Key}),
                  case db_entry:is_empty(DBEntry) of
                      false -> [DBEntry | L];
                      _     -> L
                  end
          end, [], HisList),
    {State, HisListFilt}.

%% @doc Gets all custom objects (created by ValueFun(DBEntry)) from the DB for
%%      which FilterFun returns true.
-spec get_entries_(DB::db_t(),
                   FilterFun::fun((DBEntry::db_entry:entry()) -> boolean()),
                   ValueFun::fun((DBEntry::db_entry:entry()) -> Value))
        -> [Value].
get_entries_({{DB, _FileName}, _Subscr, _SnapState}, FilterFun, ValueFun) ->
    F = fun (_Key, DBEntry_, Data) ->
                 DBEntry = erlang:binary_to_term(DBEntry_),
                 case FilterFun(DBEntry) of
                     true -> [ValueFun(DBEntry) | Data];
                     _    -> Data
                 end
        end,
    toke_drv:fold(F, [], DB).

%% @doc Returns all ValueFun(DBEntry) objects of the given DB which are in the
%%      given interval and satisfy FilterFun but at most ChunkSize elements.
%%      See get_chunk/3 for more details.
-spec get_chunk_(DB::db_t(), Interval::intervals:interval(),
                 FilterFun::fun((db_entry:entry()) -> boolean()),
                 ValueFun::fun((db_entry:entry()) -> V), ChunkSize::pos_integer() | all)
        -> {intervals:interval(), [V]}.
get_chunk_(State, Interval, FilterFun, ValueFun, ChunkSize) ->
    AddDataFun = fun(_Key_, _Key, DBEntry_, Data) ->
                         DBEntry = erlang:binary_to_term(DBEntry_),
                         case FilterFun(DBEntry) of
                             true -> [ValueFun(DBEntry) | Data];
                             _    -> Data
                         end
                 end,
    get_chunk_helper(State, Interval, AddDataFun, fun db_entry:get_key/1, ChunkSize).

-spec get_chunk_helper(DB::db_t(), Interval::intervals:interval(),
                       AddDataFun::fun((Key_::binary(), Key::?RT:key(), db_entry:entry(), [T]) -> [T]),
                       GetKeyFromDataFun::fun((T) -> ?RT:key()), ChunkSize::pos_integer() | all)
        -> {intervals:interval(), [T]}.
get_chunk_helper({{DB, _FileName}, _Subscr, _SnapState}, Interval, AddDataFun, GetKeyFromDataFun, ChunkSize) ->
    {BeginBr, Begin, _End, _EndBr} = intervals:get_bounds(Interval),
    % try to find the first existing key in the interval, starting at Begin:
    MInfToBegin = intervals:minus(intervals:all(),
                                  intervals:new(BeginBr, Begin, ?PLUS_INFINITY, ')')),
    % note: N is a helper for filtering out unnecessary items every once in a while
    F = fun (Key_, DBEntry_, {N, Data} = Acc) ->
                 Key = erlang:binary_to_term(Key_),
                 case intervals:in(Key, Interval) of
                     true when ChunkSize =:= all ->
                         % note: no need to count items here
                         {0, AddDataFun(Key_, Key, DBEntry_, Data)};
                     true ->
                         Data1 = AddDataFun(Key_, Key, DBEntry_, Data),
                         % filter out unnecessary items every (2 * ChunkSize) elements
                         case N rem 2 * ChunkSize of
                             0 ->
                                 {0, get_chunk_helper_filter(Data1, MInfToBegin, GetKeyFromDataFun, ChunkSize)};
                             _ ->
                                 {N + 1, Data1}
                         end;
                     _    -> Acc
                 end
        end,
    {_, Data} = toke_drv:fold(F, {0, []}, DB),
    SortedData = get_chunk_helper_sort(Data, MInfToBegin, GetKeyFromDataFun),
    case ChunkSize of
        all -> {intervals:empty(), SortedData};
        _   -> {Chunk, Rest} = util:safe_split(ChunkSize, SortedData),
               case Rest of
                   []      -> {intervals:empty(), Chunk};
                   [H | _] ->
                       Next = GetKeyFromDataFun(H),
                       NextToIntBegin =
                           case BeginBr of
                               '(' -> intervals:new('[', Next, Begin, ']');
                               '[' -> intervals:new('[', Next, Begin, ')')
                           end,
                       {intervals:intersection(Interval, NextToIntBegin), Chunk}
               end
    end.

-spec get_chunk_helper_sort(Data::[T], MInfToBegin::intervals:interval(),
                            GetKeyFromDataFun::fun((T) -> ?RT:key())) -> SortedData::[T].
get_chunk_helper_sort(Data, MInfToBegin, GetKeyFromDataFun) ->
    {SecondPart, FirstPart} =
        lists:partition(fun(E) ->
                                intervals:in(GetKeyFromDataFun(E), MInfToBegin)
                        end, Data),
    lists:append(lists:usort(FirstPart), lists:usort(SecondPart)).

-spec get_chunk_helper_filter(Data::[T], MInfToBegin::intervals:interval(),
                              GetKeyFromDataFun::fun((T) -> ?RT:key()),
                              ChunkSize::pos_integer()) -> SortedData::[T].
get_chunk_helper_filter(Data, MInfToBegin, GetKeyFromDataFun, ChunkSize) ->
    SortedData = get_chunk_helper_sort(Data, MInfToBegin, GetKeyFromDataFun),
    % note: leave one extra to be able to find the next available key
    {Chunk, _Rest} = util:safe_split(ChunkSize + 1, SortedData),
    Chunk.

%% @doc Deletes all objects in the given Range or (if a function is provided)
%%      for which the FilterFun returns true from the DB.
-spec delete_entries_(DB::db_t(),
                      RangeOrFun::intervals:interval() |
                                  fun((DBEntry::db_entry:entry()) -> boolean()))
        -> NewDB::db_t().
delete_entries_(State = {{DB, _FileName}, _Subscr, _SnapState}, FilterFun) when is_function(FilterFun) ->
    % first collect all toke keys to delete (can not delete while doing fold!)
    F = fun(KeyToke, DBEntry_, ToDelete) ->
                DBEntry = erlang:binary_to_term(DBEntry_),
                case FilterFun(DBEntry) of
                    false -> ToDelete;
                    _     -> [{KeyToke, db_entry:get_key(DBEntry)} | ToDelete]
                end
        end,
    KeysToDelete = toke_drv:fold(F, [], DB),
    % delete all entries with these keys
    _ = lists:foldl(fun({KeyToke, Key}, _) ->
                        toke_drv:delete(DB, KeyToke),
                        call_subscribers(State, {delete, Key})
                    end, ok, KeysToDelete),
    State;
delete_entries_(State, Interval) ->
    {Elements, RestInterval} = intervals:get_elements(Interval),
    case intervals:is_empty(RestInterval) of
        true ->
            lists:foldl(fun(Key, State1) -> delete_entry_at_key_(State1, Key) end, State, Elements);
        _ ->
            delete_entries_(State,
                            fun(E) ->
                                    intervals:in(db_entry:get_key(E), Interval)
                            end)
    end.

-spec delete_chunk_(DB::db_t(), Interval::intervals:interval(), ChunkSize::pos_integer() | all)
        -> {intervals:interval(), db_t()}.
delete_chunk_(DB, Interval, ChunkSize) ->
    AddDataFun = fun(Key_, Key, _DBEntry_, Data) -> [{Key, Key_} | Data] end,
    {Next, Chunk} = get_chunk_helper(DB, Interval, AddDataFun, fun({K, _K_}) -> K end, ChunkSize),
    DB2 = lists:foldl(fun({Key, Key_}, DB1) -> delete_entry_at_key_(DB1, Key, Key_) end, DB, Chunk),
    {Next, DB2}.

%% @doc Returns all DB entries.
-spec get_data_(DB::db_t()) -> db_as_list().
get_data_({{DB, _FileName}, _Subscr, _SnapState}) ->
    toke_drv:fold(fun (_K, DBEntry, Acc) ->
                           [erlang:binary_to_term(DBEntry) | Acc]
                  end, [], DB).

%% @doc Returns the key that would remove not more than TargetLoad entries
%%      from the DB when starting at the key directly after Begin.
%%      Precond: a load larger than 0
%%      Note: similar to get_chunk/2.
-spec get_split_key_(DB::db_t(), Begin::?RT:key(), TargetLoad::pos_integer(), forward | backward)
        -> {?RT:key(), TakenLoad::pos_integer()}.
get_split_key_(DB, Begin, TargetLoad, Direction) ->
    % assert ChunkSize > 0, see ChunkSize type
    case get_load_(DB) of
        0 -> throw('empty_db');
        _ ->
            % first need to get all keys, then sort them and filter out the split key
            F = fun (Key_, _DBEntry_, Data) -> [erlang:binary_to_term(Key_) | Data] end,
            Keys = toke_drv:fold(F, [], DB),
            % try to find the first existing key in the interval, starting at Begin (exclusive):
            MInfToBegin = intervals:minus(intervals:all(),
                                          intervals:new('(', Begin, ?PLUS_INFINITY, ')')),
            {SecondPart, FirstPart} =
                lists:partition(fun(E) -> intervals:in(E, MInfToBegin) end, Keys),
            SortedKeys = lists:append(lists:usort(FirstPart), lists:usort(SecondPart)),
            
            case Direction of
                forward  ->
                    {Chunk, _Rest} = util:safe_split(TargetLoad, SortedKeys),
                    {lists:last(Chunk), erlang:length(Chunk)};
                backward ->
                    {Chunk, _Rest} = util:safe_split(TargetLoad, lists:reverse(SortedKeys)),
                    {hd(Chunk), erlang:length(Chunk)}
            end
    end.

% snapshot-related functions

%% @doc Copy existing entry to snapshot table
-spec copy_value_to_snapshot_table_(DB::db_t(), Key::?RT:key()) -> NewDB::db_t().
copy_value_to_snapshot_table_(State = {{_DB, _FileName}, _Subscr, {SnapTable, _LiveLC, SnapLC}}, Key) ->
    case get_entry2_(State, Key) of
        {true, Entry}   ->  {_, OldSnapEntry} = get_snapshot_entry_(State,db_entry:get_key(Entry)),
                            NewSnapLC = db_entry:update_lockcount(OldSnapEntry,Entry,SnapLC),
                            ets:insert(SnapTable,Entry);
        _               ->  NewSnapLC = SnapLC
    end,
    {{_DB, _FileName}, _Subscr, {SnapTable, _LiveLC, NewSnapLC}}.

%% @doc Returns snapshot data as is
-spec get_snapshot_data_(DB::db_t()) -> db_as_list(). 
get_snapshot_data_({{_DB, _FileName}, _Subscr, {SnapTable, _, _}}) ->
    case SnapTable of
        false -> [];
        _ -> ets:tab2list(SnapTable)
    end.

%% @doc Join snapshot and primary db such that all tuples in the primary db are replaced
%%      if there is a matching tuple available in the snapshot set. The other tuples are
%%      returned as is.
-spec join_snapshot_data_(DB::db_t()) -> db_as_list(). 
join_snapshot_data_(State) ->
    PrimaryDB = lists:keysort(1, get_data_(State)),
    SnapshotDB = lists:keysort(1, get_snapshot_data_(State)),
    join_snapshot_data_helper(SnapshotDB, PrimaryDB).

-spec join_snapshot_data_helper(SnapshotDB::db_as_list(), PrimaryDB::db_as_list())
        -> db_as_list().
join_snapshot_data_helper([], Result) -> Result;
join_snapshot_data_helper([{Key, _, _, _, _} = Tuple | More], List2) ->
    Newlist = lists:keyreplace(Key, 1, List2, Tuple), 
    join_snapshot_data_helper(More, Newlist).

-spec set_snapshot_entry_(DB::db_t(), Entry::db_entry:entry()) -> NewDB::db_t().
set_snapshot_entry_(State = {{_DB, _FileName}, _Subscr, {SnapTable, _LiveLC, SnapLC}}, Entry) ->    
    case db_entry:is_null(Entry) of
        true -> delete_snapshot_entry_(State, Entry);
        
        % if there is a snapshot entry for this key, we base our lock calculation off that,
        % if not, we have to consider the live db because of the copy-on-write logic
        _    -> case get_snapshot_entry_(State,db_entry:get_key(Entry)) of
                    {true, OldEntry} ->
                            NewSnapLC = db_entry:update_lockcount(OldEntry,Entry,SnapLC);
                    {false, _} ->
                            {_,LiveEntry} = get_entry2_(State,db_entry:get_key(Entry)),
                            NewSnapLC = db_entry:update_lockcount(LiveEntry,Entry,SnapLC)
                end,
                ets:insert(SnapTable, Entry),
                {{_DB, _FileName},_Subscr,{SnapTable,_LiveLC,NewSnapLC}}
    end.


-spec get_snapshot_entry_(DB::db_t(), Key::?RT:key()) -> {Exists::boolean(), db_entry:entry()}.
get_snapshot_entry_({{_DB, _FileName}, _Subscr, {SnapTable, _LiveLC, _SnapLC}}, Key) ->
    case ets:lookup(SnapTable, Key) of
        [Entry] -> {true, Entry};
        []      -> {false, db_entry:new(Key)}
    end.

-spec delete_snapshot_entry_at_key_(DB::db_t(), Key::?RT:key()) -> NewDB::db_t().
delete_snapshot_entry_at_key_(State = {{_DB, _FileName}, _Subscr, {SnapTable, _LiveLC, SnapLC}}, Key) ->
    case get_snapshot_entry_(State,Key) of
        {true, OldEntry} ->
            NewSnapLC = db_entry:update_lockcount(OldEntry,db_entry:new(Key),SnapLC);
        {false, _} ->
            {_,LiveEntry} = get_entry2_(State,Key),
            NewSnapLC = db_entry:update_lockcount(LiveEntry,db_entry:new(Key),SnapLC)
    end,
    ets:delete(SnapTable, Key),
    {{_DB, _FileName},_Subscr,{SnapTable,_LiveLC,NewSnapLC}}.

%% @doc Removes all values with the given entry's key from the Snapshot DB.
-spec delete_snapshot_entry_(DB::db_t(), Entry::db_entry:entry()) -> NewDB::db_t().
delete_snapshot_entry_(State, Entry) ->
    Key = db_entry:get_key(Entry),
    delete_snapshot_entry_at_key_(State, Key).

-spec init_snapshot_(DB::db_t()) -> NewDB::db_t().
init_snapshot_({{_DB, _FileName}, _Subscr, {SnapTable,LiveLC,_SnapLC}}) ->
    case SnapTable of
        false ->
            ets:delete(SnapTable);
        _ -> 
            ok
    end,
    SnapDBName = "db_" ++ randoms:getRandomString() ++ ":snapshot",
    {{_DB, _FileName}, _Subscr, {ets:new(list_to_atom(SnapDBName), [ordered_set, private]),LiveLC,LiveLC}}.

-spec snapshot_is_lockfree_(DB::db_t()) -> boolean().
snapshot_is_lockfree_({{_DB, _FileName}, _Subscr, {_SnapTable, _LiveLC, SnapLC}}) ->
    SnapLC =:= 0.

-spec snapshot_is_running_(DB::db_t()) -> boolean().
snapshot_is_running_({{_DB, _FileName}, _Subscr, {SnapTable, _LiveLC, _SnapLC}}) ->
    case SnapTable of
        false -> false;
        _ -> true
    end.

-spec delete_snapshot_(DB::db_t()) -> NewDB::db_t().
delete_snapshot_({{DB, FileName}, Subscr, {_SnapTable, LiveLC, _SnapLC}}) ->
    {{DB, FileName}, Subscr, {false, LiveLC, 0}}.

-spec decrease_snapshot_lockcount_(DB::db_t()) -> NewDB::db_t().
decrease_snapshot_lockcount_({{_DB, _FileName}, _Subscr, {_SnapTable, _LiveLC, SnapLC}}) ->
    {{_DB, _FileName},_Subscr,{_SnapTable,_LiveLC,SnapLC-1}}.

% end snapshot-related functions
