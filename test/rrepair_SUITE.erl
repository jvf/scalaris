%  @copyright 2010-2014 Zuse Institute Berlin

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

%% @author Maik Lange <malange@informatik.hu-berlin.de
%% @doc    Tests for rep update module.
%% @end
%% @version $Id$
-module(rrepair_SUITE).
-author('malange@informatik.hu-berlin.de').
-vsn('$Id$').

-compile(export_all).

-include("unittest.hrl").
-include("scalaris.hrl").
-include("record_helpers.hrl").

-define(REP_FACTOR, 4).
-define(DBSizeKey, rrepair_SUITE_dbsize).    %Process Dictionary Key for generated db size

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

basic_tests() ->
    [get_symmetric_keys_test,
     tester_quadrant_intervals,
     tester_map_key_to_interval,
     tester_map_key_to_quadrant,
     tester_map_interval,
     tester_find_sync_interval,
     tester_merkle_compress_hashlist%,
%%      tester_merkle_compress_cmp_result
    ].

repair_default() ->
    [no_diff,        % ring is not out of sync e.g. no outdated or missing replicas
     one_node,       % sync in ring with only one node
     %mpath
     dest,           % run one sync with a specified dest node
     simple,         % run one sync round
     multi_round,    % run multiple sync rounds with sync probability 1
     multi_round2,   % run multiple sync rounds with sync probability 0.4
     parts           % get_chunk with limited items (leads to multiple get_chunk calls, in case of bloom also multiple bloom filters)
    ].

regen_special() ->
    [
     dest_empty_node % run one sync with empty dest node
    ].

all() ->
    [{group, basic},
     session_ttl,
     {group, repair}
     ].

groups() ->
    [{basic,  [parallel], basic_tests()},
     {repair, [sequence], [{upd_trivial,  [sequence], repair_default()},
                           {upd_bloom,    [sequence], repair_default()}, %{repeat_until_any_fail, 1000}
                           {upd_merkle,   [sequence], repair_default()},
                           {upd_art,      [sequence], repair_default()},
                           {regen_trivial,[sequence], repair_default() ++ regen_special()},
                           {regen_bloom,  [sequence], repair_default() ++ regen_special()},
                           {regen_merkle, [sequence], repair_default() ++ regen_special()},
                           {regen_art,    [sequence], repair_default() ++ regen_special()},
                           {mixed_trivial,[sequence], repair_default()},
                           {mixed_bloom,  [sequence], repair_default()},
                           {mixed_merkle, [sequence], repair_default()},
                           {mixed_art,    [sequence], repair_default()}
                          ]}
    ].

suite() -> [{timetrap, {seconds, 20}}].

group(tester_type_check) ->
    [{timetrap, {seconds, 60}}];
group(_) ->
    suite().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init_per_suite(Config) ->
    Config2 = unittest_helper:init_per_suite(Config),
    tester:register_type_checker({typedef, intervals, interval}, intervals, is_well_formed),
    tester:register_type_checker({typedef, intervals, continuous_interval}, intervals, is_continuous),
    tester:register_type_checker({typedef, intervals, non_empty_interval}, intervals, is_non_empty),
    tester:register_value_creator({typedef, intervals, interval}, intervals, tester_create_interval, 1),
    tester:register_value_creator({typedef, intervals, continuous_interval}, intervals, tester_create_continuous_interval, 4),
    tester:register_value_creator({typedef, intervals, non_empty_interval}, intervals, tester_create_non_empty_interval, 2),
    Config2.

end_per_suite(Config) ->
    erlang:erase(?DBSizeKey),
    tester:unregister_type_checker({typedef, intervals, interval}),
    tester:unregister_type_checker({typedef, intervals, continuous_interval}),
    tester:unregister_type_checker({typedef, intervals, non_empty_interval}),
    tester:unregister_value_creator({typedef, intervals, interval}),
    tester:unregister_value_creator({typedef, intervals, continuous_interval}),
    tester:unregister_value_creator({typedef, intervals, non_empty_interval}),
    _ = unittest_helper:end_per_suite(Config),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init_per_group(Group, Config) ->
    ct:comment(io_lib:format("BEGIN ~p", [Group])),
    case Group of
        upd_trivial -> [{ru_method, trivial}, {ftype, update}];
        upd_bloom -> [{ru_method, bloom}, {ftype, update}];
        upd_merkle -> [{ru_method, merkle_tree}, {ftype, update}];
        upd_art -> [{ru_method, art}, {ftype, update}];
        regen_trivial -> [{ru_method, trivial}, {ftype, regen}];
        regen_bloom -> [{ru_method, bloom}, {ftype, regen}];
        regen_merkle -> [{ru_method, merkle_tree}, {ftype, regen}];
        regen_art -> [{ru_method, art}, {ftype, regen}];
        mixed_trivial -> [{ru_method, trivial}, {ftype, mixed}];
        mixed_bloom -> [{ru_method, bloom}, {ftype, mixed}];
        mixed_merkle -> [{ru_method, merkle_tree}, {ftype, mixed}];
        mixed_art -> [{ru_method, art}, {ftype, mixed}];
        _ -> []
    end ++ Config.

end_per_group(Group, Config) ->
    Method = proplists:get_value(ru_method, Config, undefined),
    FType = proplists:get_value(ftype, Config, undefined),
    case Method of
        undefined -> ct:comment(io_lib:format("END ~p", [Group]));
        M -> ct:comment(io_lib:format("END ~p/~p", [FType, M]))
    end,
    proplists:delete(ru_method, Config).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init_per_testcase(tester_type_check, Config) ->
    % needs config
    unittest_helper:start_minimal_procs(Config, [], false);
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    unittest_helper:stop_minimal_procs(Config),
    unittest_helper:stop_ring(),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_rep_upd_config(Method) ->
    [{rrepair_enabled, true},
     {rr_trigger_interval, 0}, %stop trigger
     {rr_recon_method, Method},
     {rr_session_ttl, 100000},
     {rr_gc_interval, 60000},
     {rr_recon_p1e, 0.1},
     {rr_trigger_probability, 100},
     {rr_art_inner_fpr, 0.01},
     {rr_art_leaf_fpr, 0.1},
     {rr_art_correction_factor, 2},
     {rr_merkle_branch_factor, 2},
     {rr_merkle_bucket_size, 25}].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Replica Update tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

no_diff(Config) ->
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    start_sync(Config, 4, 1000, [{fprob, 0}, {ftype, FType}],
               1, 0.1, get_rep_upd_config(Method), fun erlang:'=:='/2).

one_node(Config) ->
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    % atm, there is no rrepair with self (we wouldn't need a complex protocol for that)
    start_sync(Config, 1, 1, [{fprob, 50}, {ftype, FType}],
               1, 0.2, get_rep_upd_config(Method), fun erlang:'=:='/2).

mpath_map({X, {?key_upd, KVV, ReqKeys}, _}, _Source, _Dest)
  when X =:= request_resolve orelse X =:= continue_resolve ->
    {?key_upd, length(KVV), length(ReqKeys)};
mpath_map({X, _, {?key_upd, KVV, ReqKeys}, _}, _Source, _Dest)
  when X =:= request_resolve orelse X =:= continue_resolve ->
    {?key_upd, length(KVV), length(ReqKeys)};
mpath_map(Msg, _Source, _Dest) ->
    {element(1, Msg)}.

mpath(Config) ->
    %parameter
    NodeCount = 4,
    DataCount = 1000,
    P1E = 0.1,
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    TraceName = erlang:list_to_atom(atom_to_list(Method)++atom_to_list(FType)),
    %build and fill ring
    build_symmetric_ring(NodeCount, Config, [get_rep_upd_config(Method), {rr_recon_p1e, P1E}]),
    _ = db_generator:fill_ring(random, DataCount, [{ftype, FType},
                                                   {fprob, 50},
                                                   {distribution, uniform}]),
    %chose node pair
    SKey = ?RT:get_random_node_id(),
    CKey = util:randomelem(lists:delete(SKey, ?RT:get_replica_keys(SKey))),
    %server starts sync
    %trace_mpath:start(TraceName, fun mpath_map/3),
    trace_mpath:start(TraceName),
    api_dht_raw:unreliable_lookup(SKey, {?send_to_group_member, rrepair,
                                              {request_sync, Method, CKey, comm:this()}}),
    waitForSyncRoundEnd([SKey, CKey], true),
    trace_mpath:stop(),
    %TRACE
    A = trace_mpath:get_trace(TraceName),
    trace_mpath:cleanup(TraceName),
    B = [X || X = {log_send, _Time, _TraceID,
                   {{_FIP,_FPort,_FPid}, _FName},
                   {{_TIP,_TPort,_TPid}, _TName},
                   _Msg, _LocalOrGlobal} <- A],
    ok = file:write_file("TRACE_" ++ atom_to_list(TraceName) ++ ".txt", io_lib:fwrite("~.0p\n", [B])),
    ok = file:write_file("TRACE_HISTO_" ++ atom_to_list(TraceName) ++ ".txt", io_lib:fwrite("~.0p\n", [trace_mpath:send_histogram(B)])),
    %ok = file:write_file("TRACE_EVAL_" ++ atom_to_list(TraceName) ++ ".txt", io_lib:fwrite("~.0p\n", [rr_eval_admin:get_bandwidth(A)])),
    ok.

simple(Config) ->
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    start_sync(Config, 4, 1000, [{fprob, 10}, {ftype, FType}],
               1, 0.1, get_rep_upd_config(Method), fun erlang:'<'/2).

multi_round(Config) ->
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    start_sync(Config, 6, 1000, [{fprob, 10}, {ftype, FType}],
               3, 0.1, get_rep_upd_config(Method), fun erlang:'<'/2).

multi_round2(Config) ->
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    _RUConf = get_rep_upd_config(Method),
    RUConf = [{rr_trigger_probability, 40} | proplists:delete(rr_trigger_probability, _RUConf)],
    start_sync(Config, 6, 1000, [{fprob, 10}, {ftype, FType}],
               3, 0.1, RUConf, fun erlang:'<'/2).

dest(Config) ->
    %parameter
    NodeCount = 7,
    DataCount = 1000,
    P1E = 0.1,
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    %build and fill ring
    build_symmetric_ring(NodeCount, Config, [get_rep_upd_config(Method), {rr_recon_p1e, P1E}]),
    _ = db_generator:fill_ring(random, DataCount, [{ftype, FType},
                                                   {fprob, 50},
                                                   {distribution, uniform}]),
    %chose node pair
    SKey = ?RT:get_random_node_id(),
    CKey = util:randomelem(lists:delete(SKey, ?RT:get_replica_keys(SKey))),
    %measure initial sync degree
    SO = count_outdated(SKey),
    SM = count_dbsize(SKey),
    CO = count_outdated(CKey),
    CM = count_dbsize(CKey),
    %server starts sync
    api_dht_raw:unreliable_lookup(SKey, {?send_to_group_member, rrepair,
                                              {request_sync, Method, CKey, comm:this()}}),
    waitForSyncRoundEnd([SKey, CKey], true),
    %measure sync degree
    SONew = count_outdated(SKey),
    SMNew = count_dbsize(SKey),
    CONew = count_outdated(CKey),
    CMNew = count_dbsize(CKey),
    ct:pal("SYNC RUN << ~p / ~p >>~nServerKey=~p~nClientKey=~p~n"
           "Server Outdated=[~p -> ~p] DBSize=[~p -> ~p] - Upd=~p ; Regen=~p~n"
           "Client Outdated=[~p -> ~p] DBSize=[~p -> ~p] - Upd=~p ; Regen=~p",
           [Method, FType, SKey, CKey,
            SO, SONew, SM, SMNew, SO - SONew, SMNew - SM,
            CO, CONew, CM, CMNew, CO - CONew, CMNew - CM]),
    %clean up
    ?implies(SO > 0 orelse CO > 0, SONew < SO orelse CONew < CO) andalso
        ?implies(SM =/= SMNew, SMNew > SM) andalso
        ?implies(CM =/= CMNew, CMNew > CM).

dest_empty_node(Config) ->
    %parameter
    NodeCount = 4,
    DataCount = 1000,
    P1E = 0.1,
    Method = proplists:get_value(ru_method, Config),
    %build and fill ring
    build_symmetric_ring(NodeCount, Config, [get_rep_upd_config(Method), {rr_recon_p1e, P1E}]),
    _ = db_generator:fill_ring(random, DataCount, [{ftype, regen},
                                                   {fprob, 100},
                                                   {distribution, uniform},
                                                   {fdest, [1]}]),
    %chose any node not in quadrant 1
    KeyGrp = ?RT:get_replica_keys(?RT:get_random_node_id()),
    [Q1 | _] = rr_recon:quadrant_intervals(),
    IKey = util:randomelem([X || X <- KeyGrp, not intervals:in(X, Q1)]),
    CKey = hd([Y || Y <- KeyGrp, intervals:in(Y, Q1)]),
    %measure initial sync degree
    IM = count_dbsize(IKey),
    CM = count_dbsize(CKey),
    %server starts sync
    api_dht_raw:unreliable_lookup(IKey, {?send_to_group_member, rrepair,
                                              {request_sync, Method, CKey, comm:this()}}),
    waitForSyncRoundEnd([IKey, CKey], true),
    %measure sync degree
    IMNew = count_dbsize(IKey),
    CMNew = count_dbsize(CKey),
    ct:pal("SYNC RUN << ~p >>~nServerKey=~p~nClientKey=~p~n"
           "Server DBSize=[~p -> ~p] - Regen=~p~n"
           "Client DBSize=[~p -> ~p] - Regen=~p",
           [Method, IKey, CKey,
            IM, IMNew, IMNew - IM,
            CM, CMNew, CMNew - CM]),
    %clean up
    ?equals(CM, 0),
    ?compare(fun erlang:'>'/2, CMNew, CM).

parts(Config) ->
    Method = proplists:get_value(ru_method, Config),
    FType = proplists:get_value(ftype, Config),
    OldConf = get_rep_upd_config(Method),
    Conf = lists:keyreplace(rr_max_items, 1, OldConf, {rr_max_items, 500}),
    start_sync(Config, 4, 1000, [{fprob, 100}, {ftype, FType}],
               2, 0.2, Conf, fun erlang:'<'/2).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Basic Functions Group
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_symmetric_keys_test(Config) ->
    Conf2 = unittest_helper:start_minimal_procs(Config, [], true),
    ToTest = lists:sort(get_symmetric_keys(4)),
    ToBe = lists:sort(?RT:get_replica_keys(?MINUS_INFINITY)),
    unittest_helper:stop_minimal_procs(Conf2),
    ?equals_w_note(ToTest, ToBe,
                   io_lib:format("GenKeys=~w~nRTKeys=~w", [ToTest, ToBe])),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec wait_until_true(DestKey::?RT:key(), Request::comm:message(),
                      ConFun::fun((StateResponse::term()) -> boolean()),
                      MaxWait::integer()) -> boolean().
wait_until_true(DestKey, Request, ConFun, MaxWait) ->
    api_dht_raw:unreliable_lookup(DestKey, Request),
    Result = receive {get_state_response, R} -> ConFun(R) end,
    if Result -> true;
       not Result andalso MaxWait > 0 ->
           erlang:yield(),
           timer:sleep(10),
           wait_until_true(DestKey, Request, ConFun, MaxWait - 10);
       not Result andalso MaxWait =< 0 ->
           false
    end.

session_ttl(Config) ->
    %parameter
    NodeCount = 7,
    DataCount = 1000,
    Method = merkle_tree,
    FType = mixed,
    TTL = 2000,

    RRConf1 = lists:keyreplace(rr_session_ttl, 1, get_rep_upd_config(Method), {rr_session_ttl, TTL div 2}),
    RRConf = lists:keyreplace(rr_gc_interval, 1, RRConf1, {rr_gc_interval, erlang:round(TTL div 2)}),

    %build and fill ring
    build_symmetric_ring(NodeCount, Config, RRConf),
    _ = db_generator:fill_ring(random, DataCount, [{ftype, FType},
                                                   {fprob, 90},
                                                   {distribution, uniform}]),
    %chose node pair
    SKey = ?RT:get_random_node_id(),
    CKey = util:randomelem(lists:delete(SKey, ?RT:get_replica_keys(SKey))),

    api_dht_raw:unreliable_lookup(CKey, {get_pid_group, comm:this()}),
    CName = receive {get_pid_group_response, Key} -> Key end,

    %server starts sync
    api_dht_raw:unreliable_lookup(SKey, {?send_to_group_member, rrepair,
                                              {request_sync, Method, CKey}}),
    Req = {?send_to_group_member, rrepair, {get_state, comm:this(), open_sessions}},
    SessionOpened = wait_until_true(SKey, Req, fun(X) -> length(X) =/= 0 end, TTL),

    %check timeout
    api_vm:kill_node(CName),
    timer:sleep(TTL),
    api_dht_raw:unreliable_lookup(SKey, Req),
    SessionGarbageCollected = receive {get_state_response, R2} -> length(R2) =:= 0 end,
    case SessionOpened of
        true ->
            ?equals(SessionGarbageCollected, SessionOpened);
        false ->
            ct:pal("Session finished before client node could be killed.")
    end,
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec prop_quadrant_intervals() -> true.
prop_quadrant_intervals() ->
    Quadrants = rr_recon:quadrant_intervals(),
    ?equals(lists:foldl(fun intervals:union/2, intervals:empty(), Quadrants),
            intervals:all()),
    % all continuous:
    ?equals([Q || Q <- Quadrants, not intervals:is_continuous(Q)],
            []),
    % pair-wise non-overlapping:
    ?equals([{Q1, Q2} || Q1 <- Quadrants,
                         Q2 <- Quadrants,
                         Q1 =/= Q2,
                         not intervals:is_empty(intervals:intersection(Q1, Q2))],
            []).

tester_quadrant_intervals(_) ->
    tester:test(?MODULE, prop_quadrant_intervals, 0, 100, [{threads, 4}]).

-spec prop_map_key_to_interval(?RT:key(), intervals:interval()) -> boolean().
prop_map_key_to_interval(Key, I) ->
    Mapped = rr_recon:map_key_to_interval(Key, I),
    RGrp = ?RT:get_replica_keys(Key),
    InGrp = [X || X <- RGrp, intervals:in(X, I)],
    case intervals:in(Key, I) of
        true ->
            ?equals_w_note(Mapped, Key,
                           io_lib:format("Violation: if key is in i than mapped key equals key!~n"
                                             "Key=~p~nMapped=~p", [Key, Mapped]));
        false when Mapped =/= none ->
            ?compare(fun erlang:'=/='/2, InGrp, []),
            case InGrp of
                [W] -> ?equals(Mapped, W);
                [_|_] ->
                    NotIn = [Y || Y <- RGrp, Y =/= Key, not intervals:in(Y, I)],
%%                     ct:pal("prop_map_key_to_interval(~p, ~p)~nmapped: ~p~nnot in: ~w",
%%                            [I, Key, Mapped, NotIn]),
                    _ = [begin
                             MapZ = rr_recon:map_key_to_interval(Z, I),
%%                              ct:pal("~p -> ~p", [Z, MapZ]),
                             ?compare(fun erlang:'=/='/2, MapZ, Mapped)
                         end
                         || Z <- NotIn],
                    ?assert(intervals:in(Mapped, I))
            end;
        _ -> ?equals(InGrp, [])
    end.

tester_map_key_to_interval(_) ->
    [Q1, Q2, Q3 | _] = ?RT:get_replica_keys(?MINUS_INFINITY),
    prop_map_key_to_interval(Q1, intervals:new('[', Q1, Q2, ']')),
    prop_map_key_to_interval(Q2, intervals:new('[', Q1, Q2, ']')),
    prop_map_key_to_interval(Q3, intervals:new('[', Q1, Q2, ']')),
    tester:test(?MODULE, prop_map_key_to_interval, 2, 1000, [{threads, 4}]).

-spec prop_map_key_to_quadrant(?RT:key(), Quadrant::1..4) -> boolean().
prop_map_key_to_quadrant(Key, Quadrant) ->
    ?equals(rr_recon:map_key_to_quadrant(Key, Quadrant),
            rr_recon:map_key_to_interval(Key, lists:nth(Quadrant, rr_recon:quadrant_intervals()))).

tester_map_key_to_quadrant(_) ->
    tester:test(?MODULE, prop_map_key_to_quadrant, 2, 1000, [{threads, 4}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec prop_map_interval(A::intervals:continuous_interval(),
                             B::intervals:continuous_interval()) -> boolean().
prop_map_interval(A, B) ->
    Quadrants = rr_recon:quadrant_intervals(),
    % need a B that is in a single quadrant - just use the first one to get
    % deterministic behaviour:
    BQ = hd(rr_recon:quadrant_subints_(B, rr_recon:quadrant_intervals(), [])),
    SA = rr_recon:map_interval(A, BQ),

    % SA must be a sub-interval of A
    ?compare(fun intervals:is_subset/2, SA, A),

    % SA must be in a single quadrant
    ?equals([I || Q <- Quadrants,
                  not intervals:is_empty(
                    I = intervals:intersection(SA, Q))],
            ?IIF(intervals:is_empty(SA), [], [SA])),

    % if mapped back, must at least be a subset of BQ:
    case intervals:is_empty(SA) of
        true -> true;
        _ ->
            ?compare(fun intervals:is_subset/2, rr_recon:map_interval(BQ, SA), BQ)
    end.

tester_map_interval(_) ->
    prop_map_interval(intervals:new(?MINUS_INFINITY),
                      intervals:new('[', 45418374902990035001132940685036047259, ?MINUS_INFINITY, ']')),
    prop_map_interval(intervals:new(?MINUS_INFINITY), intervals:all()),
    prop_map_interval([{'[',0,52800909270899328435375133601130059363,')'}],
                      [{'[',234596648080609640182865804133877994395,293423227623586592154289572207917413067,')'}]),
    tester:test(?MODULE, prop_map_interval, 2, 1000, [{threads, 1}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec prop_find_sync_interval(intervals:continuous_interval(), intervals:continuous_interval()) -> true.
prop_find_sync_interval(A, B) ->
    SyncI = rr_recon:find_sync_interval(A, B),
    case intervals:is_empty(SyncI) of
        true -> true;
        _ ->
            % continuous:
            ?assert_w_note(intervals:is_continuous(SyncI), io_lib:format("SyncI: ~p", [SyncI])),
            % mapped to A, subset of A:
            ?assert_w_note(intervals:is_subset(SyncI, A), io_lib:format("SyncI: ~p", [SyncI])),
            Quadrants = rr_recon:quadrant_intervals(),
            % only in a single quadrant:
            ?equals([SyncI || Q <- Quadrants,
                              not intervals:is_empty(intervals:intersection(SyncI, Q))],
                    [SyncI]),
            % SyncI must be a subset of B if mapped back
            ?compare(fun intervals:is_subset/2, rr_recon:map_interval(B, SyncI), B)
    end.

tester_find_sync_interval(_) ->
    tester:test(?MODULE, prop_find_sync_interval, 2, 100, [{threads, 4}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec prop_merkle_compress_hashlist(Nodes::[merkle_tree:mt_node()], SigSize::1..160) -> boolean().
prop_merkle_compress_hashlist(Nodes0, SigSize) ->
    % fix node list which may contain nil hashes:
    % let it crash if the format of a merkle tree node changes
    Nodes = [begin
                 case N of
                     {nil, Count, LeafCount, Bucket, Interval, ChildList} ->
                         {randoms:getRandomInt(), Count, LeafCount, Bucket,
                          Interval, ChildList};
                     _ -> N
                 end
             end || N <- Nodes0],
    Bin = rr_recon:merkle_compress_hashlist(Nodes, <<>>, SigSize),
    HashesRed = [begin
                     H0 = merkle_tree:get_hash(N),
                     <<H:SigSize/integer-unit:1>> = <<H0:SigSize>>,
                     {H, merkle_tree:is_leaf(N)}
                 end || N <- Nodes],
    ?equals(rr_recon:merkle_decompress_hashlist(Bin, [], SigSize), HashesRed).

tester_merkle_compress_hashlist(_) ->
    tester:test(?MODULE, prop_merkle_compress_hashlist, 2, 1000, [{threads, 4}]).

%% -spec prop_merkle_compress_cmp_result(CmpRes::[rr_recon:merkle_cmp_result()],
%%                                       SigSize::1..160) -> boolean().
%% prop_merkle_compress_cmp_result(CmpRes, SigSize) ->
%%     {Flags, HashesBin} =
%%         rr_recon:merkle_compress_cmp_result(CmpRes, <<>>, <<>>, SigSize),
%%     CmpResRed = [case Cmp of
%%                      {H0} ->
%%                          <<H:SigSize/integer-unit:1>> = <<H0:SigSize>>,
%%                          {H};
%%                      X -> X
%%                  end || Cmp <- CmpRes],
%%     ?equals(rr_recon:merkle_decompress_cmp_result(Flags, HashesBin, [], SigSize),
%%             CmpResRed).
%%
%% tester_merkle_compress_cmp_result(_) ->
%%     tester:test(?MODULE, prop_merkle_compress_cmp_result, 2, 1000, [{threads, 4}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Helper Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% @doc
%    runs the bloom filter synchronization [Rounds]-times
%    and records the sync degree after each round
%    returns list of sync degrees per round, first value is initial sync degree
% @end
-spec start_sync(Config, Nodes::Int, DBSize::Int, DBParams,
                 Rounds::Int, P1E, RRConf::Config, CompFun) -> true when
    is_subtype(Config,      [tuple()]),
    is_subtype(Int,         pos_integer()),
    is_subtype(DBParams,    [db_generator:db_parameter()]),
    is_subtype(P1E,         float()),
    is_subtype(CompFun,     fun((T, T) -> boolean())).
start_sync(Config, NodeCount, DBSize, DBParams, Rounds, P1E, RRConfig, CompFun) ->
    NodeKeys = lists:sort(get_symmetric_keys(NodeCount)),
    build_symmetric_ring(NodeCount, Config, [RRConfig, {rr_recon_p1e, P1E}]),
    Nodes = [begin
                 comm:send_local(NodePid, {get_node_details, comm:this(), [node]}),
                 receive
                     ?SCALARIS_RECV({get_node_details_response, NodeDetails},
                                    begin
                                        Node = node_details:get(NodeDetails, node),
                                        {node:id(Node), node:pidX(Node)}
                                    end);
                     ?SCALARIS_RECV(Y, ?ct_fail("unexpected message while "
                                                "waiting for get_node_details_response: ~.0p",
                                                [Y]))
                 end
             end || NodePid <- pid_groups:find_all(dht_node)],
    ct:pal(">>Nodes: ~.2p", [Nodes]),
    erlang:put(?DBSizeKey, ?REP_FACTOR * DBSize),
    _ = db_generator:fill_ring(random, DBSize, DBParams),
    InitDBStat = get_db_status(),
    print_status(0, InitDBStat),
    _ = util:for_to_ex(1, Rounds,
                       fun(I) ->
                               ct:pal("Starting round ~p", [I]),
                               startSyncRound(NodeKeys),
                               waitForSyncRoundEnd(NodeKeys, false),
                               print_status(I, get_db_status())
                       end),
    EndStat = get_db_status(),
    ?compare_w_note(CompFun, sync_degree(InitDBStat), sync_degree(EndStat),
                    io_lib:format("CompFun: ~p", [CompFun])),
    unittest_helper:stop_ring(),
    true.

-spec print_status(Round::integer(), db_generator:db_status()) -> ok.
print_status(R, {_, _, M, O}) ->
    ct:pal(">>SYNC RUN [Round ~p] Missing=[~p] Outdated=[~p]", [R, M, O]).

-spec count_outdated(?RT:key()) -> non_neg_integer().
count_outdated(Key) ->
    Req = {rr_stats, {count_old_replicas, comm:this(), intervals:all()}},
    api_dht_raw:unreliable_lookup(Key, {?send_to_group_member, rrepair, Req}),
    receive
        {count_old_replicas_reply, Old} -> Old
    end.

-spec count_outdated() -> non_neg_integer().
count_outdated() ->
    Req = {rr_stats, {count_old_replicas, comm:this(), intervals:all()}},
    lists:foldl(
      fun(Node, Acc) ->
              comm:send(Node, {?send_to_group_member, rrepair, Req}),
              receive
                  {count_old_replicas_reply, Old} -> Acc + Old
              end
      end,
      0, get_node_list()).

-spec get_node_list() -> [comm:mypid()].
get_node_list() ->
    mgmt_server:node_list(),
    receive
        {get_list_response, N} -> N
    end.

% @doc counts db size on node responsible for key
-spec count_dbsize(?RT:key()) -> non_neg_integer().
count_dbsize(Key) ->
    RingData = unittest_helper:get_ring_data(),
    N = lists:filter(fun({_Pid, {LBr, LK, RK, RBr}, _DB, _Pred, _Succ, ok}) ->
                             intervals:in(Key, intervals:new(LBr, LK, RK, RBr))
                     end, RingData),
    case N of
        [{_Pid, _I, DB, _Pred, _Succ, ok}] -> length(DB);
        _ -> 0
    end.

-spec get_db_status() -> db_generator:db_status().
get_db_status() ->
    DBSize = erlang:get(?DBSizeKey),
    Ring = statistics:get_ring_details(),
    Stored = statistics:get_total_load(Ring),
    {DBSize, Stored, DBSize - Stored, count_outdated()}.

-spec get_symmetric_keys(pos_integer()) -> [?RT:key()].
get_symmetric_keys(NodeCount) ->
    [element(2, intervals:get_bounds(I)) || I <- intervals:split(intervals:all(), NodeCount)].

build_symmetric_ring(NodeCount, Config, RRConfig) ->
    {priv_dir, PrivDir} = lists:keyfind(priv_dir, 1, Config),
    % stop ring from previous test case (it may have run into a timeout)
    unittest_helper:stop_ring(),
    %Build ring with NodeCount symmetric nodes
    unittest_helper:make_ring_with_ids(
      fun() ->  get_symmetric_keys(NodeCount) end,
      [{config, lists:flatten([{log_path, PrivDir},
                               RRConfig])}]),
    % wait for all nodes to finish their join
    unittest_helper:check_ring_size_fully_joined(NodeCount),
    % wait a bit for the rm-processes to settle
    timer:sleep(500),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Analysis
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec startSyncRound(NodeKeys::[?RT:key()]) -> ok.
startSyncRound(NodeKeys) ->
    lists:foreach(
      fun(X) ->
              Req = {?send_to_group_member, rrepair, {rr_trigger}},
              api_dht_raw:unreliable_lookup(X, Req)
      end,
      NodeKeys),
    ok.

-spec waitForSyncRoundEnd(NodeKeys::[?RT:key()], RcvReqCompleteMsg::boolean()) -> ok.
waitForSyncRoundEnd(NodeKeys, RcvReqCompleteMsg) ->
    RcvReqCompleteMsg andalso
        receive
            {request_sync_complete, _} -> true
        end,
    Req = {?send_to_group_member, rrepair,
           {get_state, comm:this(), [open_sessions, open_recon, open_resolve]}},
    util:wait_for(fun() -> wait_for_sync_round_end2(Req, NodeKeys) end, 100).

-spec wait_for_sync_round_end2(Req::comm:message(), [?RT:key()]) -> ok.
wait_for_sync_round_end2(_Req, []) -> true;
wait_for_sync_round_end2(Req, [Key | Keys]) ->
    api_dht_raw:unreliable_lookup(Key, Req),
    KeyResult =
        receive
            ?SCALARIS_RECV(
            {get_state_response, [Sessions, ORC, ORS]}, % ->
            begin
                if (ORC =:= 0 andalso ORS =:= 0 andalso
                        Sessions =:= []) ->
                       true;
                   true ->
%%                        log:pal("Key: ~.2p~nOS : ~.2p~nORC: ~p, ORS: ~p~n",
%%                                [Key, Sessions, ORC, ORS]),
                       false
                end
            end)
        end,
    if KeyResult -> wait_for_sync_round_end2(Req, Keys);
       true -> false
    end.

-spec sync_degree(db_generator:db_status()) -> float().
sync_degree({Count, _Ex, M, O}) ->
    (Count - M - O) / Count.
