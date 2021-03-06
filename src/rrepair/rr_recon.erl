% @copyright 2011-2015 Zuse Institute Berlin

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

%% @author Maik Lange <malange@informatik.hu-berlin.de>
%% @doc    replica reconcilication module
%% @end
%% @version $Id$
-module(rr_recon).
-author('malange@informatik.hu-berlin.de').
-vsn('$Id$').

-behaviour(gen_component).

-include("record_helpers.hrl").
-include("scalaris.hrl").
-include("client_types.hrl").

-export([init/1, on/2, start/2, check_config/0]).
-export([map_key_to_interval/2, map_key_to_quadrant/2, map_rkeys_to_quadrant/2,
         map_interval/2,
         quadrant_intervals/0]).
-export([get_chunk_kv/1, get_chunk_filter/1]).
%-export([compress_kv_list/6]).

%export for testing
-export([find_sync_interval/2, quadrant_subints_/3, key_dist/2]).
-export([merkle_compress_hashlist/4, merkle_decompress_hashlist/3]).
-export([pos_to_bitstring/4, bitstring_to_k_list_k/3, bitstring_to_k_list_kv/3]).
-export([calc_signature_size_nm_pair/5, calc_n_subparts_p1e/2, calc_n_subparts_p1e/3]).
%% -export([trivial_signature_sizes/4, trivial_worst_case_failprob/3,
%%          bloom_fp/4]).
-export([tester_create_kvi_tree/1, tester_is_kvi_tree/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% debug
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-define(TRACE(X,Y), ok).
%-define(TRACE(X,Y), log:pal("~w: [ ~p:~.0p ] " ++ X ++ "~n", [?MODULE, pid_groups:my_groupname(), self()] ++ Y)).
-define(TRACE_SEND(Pid, Msg), ?TRACE("to ~p:~.0p: ~.0p~n", [pid_groups:group_of(comm:make_local(comm:get_plain_pid(Pid))), Pid, Msg])).
-define(TRACE1(Msg, State),
        ?TRACE("~n  Msg: ~.0p~n"
                 "State: method: ~.0p;  stage: ~.0p;  initiator: ~.0p~n"
                 "      syncI@I: ~.0p~n"
                 "       params: ~.0p~n",
               [Msg, State#rr_recon_state.method, State#rr_recon_state.stage,
                State#rr_recon_state.initiator, State#rr_recon_state.'sync_interval@I',
                ?IIF(is_list(State#rr_recon_state.struct), State#rr_recon_state.struct, [])])).
-define(MERKLE_DEBUG(X,Y), ok).
%-define(MERKLE_DEBUG(X,Y), log:pal("~w: [ ~p:~.0p ] " ++ X, [?MODULE, pid_groups:my_groupname(), self()] ++ Y)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% type definitions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export_type([method/0, request/0]).

-type method()         :: trivial | shash | bloom | merkle_tree | art.% | iblt.
-type stage()          :: req_shared_interval | build_struct | reconciliation | resolve.

-type exit_reason()    :: empty_interval |      %interval intersection between initator and client is empty
                          recon_node_crash |    %sync partner node crashed
                          sync_finished |       %finish recon on local node
                          sync_finished_remote. %client-side shutdown by merkle-tree recon initiator

-type db_chunk_kv()    :: [{?RT:key(), client_version()}].

-type signature_size() :: 0..160. % use an upper bound of 160 (SHA-1) to limit automatic testing
-type kvi_tree()       :: mymaps:mymap(). % KeyShort::non_neg_integer() => {VersionShort::non_neg_integer(), Idx::non_neg_integer()}

-record(trivial_recon_struct,
        {
         interval  = intervals:empty()                          :: intervals:interval(),
         reconPid  = undefined                                  :: comm:mypid() | undefined,
         exp_delta = ?required(trivial_recon_struct, exp_delta) :: number(),
         db_chunk  = ?required(trivial_recon_struct, db_chunk)  :: {bitstring(), bitstring()} | {bitstring(), bitstring(), db_chunk_kv()}, % two binaries for transfer, the three-tuple only temporarily (locally)
         sig_size  = ?required(trivial_recon_struct, sig_size)  :: signature_size(),
         ver_size  = ?required(trivial_recon_struct, ver_size)  :: signature_size()
        }).

-record(shash_recon_struct,
        {
         interval  = intervals:empty()                        :: intervals:interval(),
         reconPid  = undefined                                :: comm:mypid() | undefined,
         exp_delta = ?required(shash_recon_struct, exp_delta) :: number(),
         db_chunk  = ?required(shash_recon_struct, db_chunk)  :: bitstring() | {bitstring(), db_chunk_kv()}, % binary for transfer, the pair only temporarily (locally)
         sig_size  = ?required(shash_recon_struct, sig_size)  :: signature_size(),
         p1e       = ?required(shash_recon_struct, p1e)       :: float()
        }).

-record(bloom_recon_struct,
        {
         interval   = intervals:empty()                         :: intervals:interval(),
         reconPid   = undefined                                 :: comm:mypid() | undefined,
         exp_delta  = ?required(bloom_recon_struct, exp_delta)  :: number(),
         bf         = ?required(bloom_recon_struct, bloom)      :: binary() | bloom:bloom_filter(), % binary for transfer, the full filter locally
         item_count = ?required(bloom_recon_struct, item_count) :: non_neg_integer(),
         hf_count   = ?required(bloom_recon_struct, hf_count)   :: pos_integer(),
         p1e        = ?required(bloom_recon_struct, p1e)        :: float()
        }).

-record(merkle_params,
        {
         interval       = ?required(merkle_param, interval)       :: intervals:interval(),
         reconPid       = undefined                               :: comm:mypid() | undefined,
         branch_factor  = ?required(merkle_param, branch_factor)  :: pos_integer(),
         num_trees      = ?required(merkle_param, num_trees)      :: pos_integer(),
         bucket_size    = ?required(merkle_param, bucket_size)    :: pos_integer(),
         p1e            = ?required(merkle_param, p1e)            :: float(),
         ni_item_count  = ?required(merkle_param, ni_item_count)  :: non_neg_integer()
        }).

-record(art_recon_struct,
        {
         art            = ?required(art_recon_struct, art)            :: art:art(),
         reconPid       = undefined                                   :: comm:mypid() | undefined,
         branch_factor  = ?required(art_recon_struct, branch_factor)  :: pos_integer(),
         bucket_size    = ?required(art_recon_struct, bucket_size)    :: pos_integer()
        }).

-type sync_struct() :: #trivial_recon_struct{} |
                       #shash_recon_struct{} |
                       #bloom_recon_struct{} |
                       merkle_tree:merkle_tree() |
                       [merkle_tree:mt_node()] |
                       #art_recon_struct{}.
-type parameters() :: #trivial_recon_struct{} |
                      #shash_recon_struct{} |
                      #bloom_recon_struct{} |
                      #merkle_params{} |
                      #art_recon_struct{}.
-type recon_dest() :: ?RT:key() | random.

-type merkle_sync_rcv() ::
          {MyMaxItemsCount::non_neg_integer(),
           MyKVItems::merkle_tree:mt_bucket()}.
-type merkle_sync_send() ::
          {OtherMaxItemsCount::non_neg_integer(),
           MyKVItems::merkle_tree:mt_bucket()}.
-type merkle_sync_direct() ::
          % mismatches with an empty leaf on either node
          % -> these are resolved directly
          {MyKItems::[?RT:key()], MyLeafCount::non_neg_integer(), OtherNodeCount::non_neg_integer()}.
-type merkle_sync() :: {[merkle_sync_send()], [merkle_sync_rcv()],
                        SynRcvLeafCount::non_neg_integer(), merkle_sync_direct()}.

-record(rr_recon_state,
        {
         ownerPid           = ?required(rr_recon_state, ownerPid)    :: pid(),
         dest_rr_pid        = ?required(rr_recon_state, dest_rr_pid) :: comm:mypid(), %dest rrepair pid
         dest_recon_pid     = undefined                              :: comm:mypid() | undefined, %dest recon process pid
         method             = undefined                              :: method() | undefined,
         'sync_interval@I'  = intervals:empty()                      :: intervals:interval(),
         'max_items@I'      = undefined                              :: non_neg_integer() | undefined,
         params             = {}                                     :: parameters() | {}, % parameters from the other node
         struct             = {}                                     :: sync_struct() | {}, % my recon structure
         stage              = req_shared_interval                    :: stage(),
         initiator          = false                                  :: boolean(),
         merkle_sync        = {[], [], 0, {[], 0, 0}}                :: merkle_sync(),
         misc               = []                                     :: [{atom(), term()}], % any optional parameters an algorithm wants to keep
         kv_list            = []                                     :: db_chunk_kv() | [db_chunk_kv()], % list of KV chunks only temporarily when retrieving the DB in pieces
         k_list             = []                                     :: [?RT:key()],
         stats              = ?required(rr_recon_state, stats)       :: rr_recon_stats:stats(),
         to_resolve         = {[], []}                               :: {ToSend::rr_resolve:kvv_list(), ToReqIdx::[non_neg_integer()]}
         }).
-type state() :: #rr_recon_state{}.

% keep in sync with merkle_check_node/22
-define(recon_ok,                       1). % match
-define(recon_fail_stop_leaf,           2). % mismatch, sending node has leaf node
-define(recon_fail_stop_inner,          3). % mismatch, sending node has inner node
-define(recon_fail_cont_inner,          0). % mismatch, both inner nodes (continue!)

-type merkle_cmp_request() :: {Hash::merkle_tree:mt_node_key() | none, IsLeaf::boolean()}.

-type request() ::
    {start, method(), DestKey::recon_dest()} |
    {create_struct, method(), SenderI::intervals:interval(), SenderMaxItems::non_neg_integer()} | % from initiator
    {start_recon, bloom, #bloom_recon_struct{}} | % to initiator
    {start_recon, merkle_tree, #merkle_params{}} | % to initiator
    {start_recon, art, #art_recon_struct{}}. % to initiator

-type message() ::
    % API
    request() |
    % trivial/shash/bloom sync messages
    {resolve_req, BinReqIdxPos::bitstring()} |
    {resolve_req, DBChunk::{bitstring(), bitstring()}, DiffIdx::bitstring(), SigSize::signature_size(),
     VSize::signature_size(), SenderPid::comm:mypid()} |
    {resolve_req, DBChunk::{bitstring(), bitstring()}, SigSize::signature_size(),
     VSize::signature_size(), SenderPid::comm:mypid()} |
    {resolve_req, shutdown} |
    % merkle tree sync messages
    {?check_nodes, SenderPid::comm:mypid(), ToCheck::bitstring(), MaxItemsCount::non_neg_integer()} |
    {?check_nodes, ToCheck::bitstring(), MaxItemsCount::non_neg_integer()} |
    {?check_nodes_response, FlagsBin::bitstring(), MaxItemsCount::non_neg_integer()} |
    {resolve_req, HashesK::bitstring(), HashesV::bitstring()} |
    {resolve_req, BinKeyList::bitstring()} |
    % dht node response
    {create_struct2, SenderI::intervals:interval(), {get_state_response, MyI::intervals:interval()}} |
    {process_db, {get_chunk_response, {intervals:interval(), db_chunk_kv()}}} |
    % internal
    {shutdown, exit_reason()} |
    {fd_notify, fd:event(), DeadPid::comm:mypid(), Reason::fd:reason()} |
    {'DOWN', MonitorRef::reference(), process, Owner::pid(), Info::any()}
    .

-include("gen_component.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec on(message(), state()) -> state() | kill.

on({create_struct, RMethod, SenderI, SenderMaxItems} = _Msg, State) ->
    ?TRACE1(_Msg, State),
    % (first) request from initiator to create a sync struct
    This = comm:reply_as(comm:this(), 3, {create_struct2, SenderI, '_'}),
    comm:send_local(pid_groups:get_my(dht_node), {get_state, This, my_range}),
    State#rr_recon_state{method = RMethod, initiator = false,
                         'max_items@I' = SenderMaxItems};

on({create_struct2, SenderI, {get_state_response, MyI}} = _Msg,
   State = #rr_recon_state{stage = req_shared_interval, initiator = false,
                           method = RMethod,            dest_rr_pid = DestRRPid}) ->
    ?TRACE1(_Msg, State),
    % target node got sync request, asked for its interval
    % dest_interval contains the interval of the initiator
    % -> client creates recon structure based on common interval, sends it to initiator
    SyncI = find_sync_interval(MyI, SenderI),
    case intervals:is_empty(SyncI) of
        false ->
            case RMethod of
                art -> ok; % legacy (no integrated trivial sync yet)
                _   -> fd:subscribe(self(), [DestRRPid])
            end,
            % reduce SenderI to the sub-interval matching SyncI, i.e. a mapped SyncI
            SenderSyncI = map_interval(SenderI, SyncI),
            send_chunk_req(pid_groups:get_my(dht_node), self(),
                           SyncI, get_max_items()),
            State#rr_recon_state{stage = build_struct,
                                 'sync_interval@I' = SenderSyncI};
        true ->
            shutdown(empty_interval, State)
    end;

on({process_db, {get_chunk_response, {RestI, DBList0}}} = _Msg,
   State = #rr_recon_state{stage = build_struct,       initiator = false,
                           'sync_interval@I' = SenderSyncI}) ->
    ?TRACE1(_Msg, State),
    % create recon structure based on all elements in sync interval
    DBList = [{Key, VersionX} || {KeyX, VersionX} <- DBList0,
                                 none =/= (Key = map_key_to_interval(KeyX, SenderSyncI))],
    build_struct(DBList, RestI, State);

on({start_recon, RMethod, Params} = _Msg,
   State = #rr_recon_state{dest_rr_pid = DestRRPid, misc = Misc}) ->
    ?TRACE1(_Msg, State),
    % initiator got other node's sync struct or parameters over sync interval
    % (mapped to the initiator's range)
    % -> create own recon structure based on sync interval and reconcile
    % note: sync interval may be an outdated sub-interval of this node's range
    %       -> pay attention when saving values to DB!
    %       (it could be outdated then even if we retrieved the current range now!)
    case RMethod of
        trivial ->
            #trivial_recon_struct{interval = MySyncI, reconPid = DestReconPid,
                                  db_chunk = DBChunk,
                                  sig_size = SigSize, ver_size = VSize} = Params,
            Params1 = Params#trivial_recon_struct{db_chunk = {<<>>, <<>>}},
            ?DBG_ASSERT(DestReconPid =/= undefined),
            fd:subscribe(self(), [DestRRPid]),
            % convert db_chunk to a map for faster access checks
            {DBChunkTree, OrigDBChunkLen} =
                decompress_kv_list(DBChunk, SigSize, VSize),
            ?DBG_ASSERT(Misc =:= []),
            Misc1 = [{db_chunk, {DBChunkTree, OrigDBChunkLen, _MyDBSize = 0}}];
        shash ->
            #shash_recon_struct{interval = MySyncI, reconPid = DestReconPid,
                                db_chunk = DBChunk, sig_size = SigSize} = Params,
            ?DBG_ASSERT(DestReconPid =/= undefined),
            fd:subscribe(self(), [DestRRPid]),
            % convert db_chunk to a gb_set for faster access checks
            {DBChunkSet, OrigDBChunkLen} =
                decompress_kv_list({DBChunk, <<>>}, SigSize, 0),
            %DBChunkSet = mymaps:from_list(DBChunkList),
            Params1 = Params#shash_recon_struct{db_chunk = <<>>},
            ?DBG_ASSERT(Misc =:= []),
            Misc1 = [{db_chunk, {DBChunkSet, OrigDBChunkLen, _MyDBSize = 0}}];
        bloom ->
            #bloom_recon_struct{interval = MySyncI, reconPid = DestReconPid,
                                bf = BFBin, item_count = BFCount,
                                hf_count = HfCount} = Params,
            ?DBG_ASSERT(DestReconPid =/= undefined),
            fd:subscribe(self(), [DestRRPid]),
            ?DBG_ASSERT(Misc =:= []),
            Hfs = ?REP_HFS:new(HfCount),
            BF = bloom:new_bin(BFBin, Hfs, BFCount),
            Params1 = Params#bloom_recon_struct{bf = BF},
            Misc1 = [{item_count, 0},
                     {my_bf, bloom:new(erlang:max(1, erlang:bit_size(BFBin)), Hfs)}];
        merkle_tree ->
            #merkle_params{interval = MySyncI, reconPid = DestReconPid} = Params,
            Params1 = Params,
            ?DBG_ASSERT(DestReconPid =/= undefined),
            fd:subscribe(self(), [DestRRPid]),
            Misc1 = Misc;
        art ->
            #art_recon_struct{art = ART, reconPid = DestReconPid} = Params,
            MySyncI = art:get_interval(ART),
            Params1 = Params,
            ?DBG_ASSERT(DestReconPid =/= undefined),
            Misc1 = Misc
    end,
    % client only sends non-empty sync intervals or exits
    ?DBG_ASSERT(not intervals:is_empty(MySyncI)),
    
    send_chunk_req(pid_groups:get_my(dht_node), self(),
                   MySyncI, get_max_items()),
    State#rr_recon_state{stage = reconciliation, params = Params1,
                         method = RMethod, initiator = true,
                         'sync_interval@I' = MySyncI,
                         dest_recon_pid = DestReconPid,
                         misc = Misc1};

on({process_db, {get_chunk_response, {RestI, DBList}}} = _Msg,
   State = #rr_recon_state{stage = reconciliation,        initiator = true,
                           method = trivial,
                           params = #trivial_recon_struct{exp_delta = ExpDelta,
                                                          sig_size = SigSize,
                                                          ver_size = VSize},
                           dest_rr_pid = DestRRPid,    stats = Stats,
                           ownerPid = OwnerL, to_resolve = {ToSend, ToReqIdx},
                           misc = [{db_chunk, {OtherDBChunk, OrigDBChunkLen, MyDBSize}}],
                           dest_recon_pid = DestReconPid}) ->
    ?TRACE1(_Msg, State),

    MyDBSize1 = MyDBSize + length(DBList),
    % identify items to send, request and the remaining (non-matched) DBChunk:
    {ToSend1, ToReqIdx1, OtherDBChunk1} =
        get_full_diff(DBList, OtherDBChunk, ToSend, ToReqIdx, SigSize, VSize),
    ?DBG_ASSERT2(length(ToSend1) =:= length(lists:usort(ToSend1)),
                 {non_unique_send_list, ToSend, ToSend1}),

    %if rest interval is non empty get another chunk
    SyncFinished = intervals:is_empty(RestI),
    if not SyncFinished ->
           send_chunk_req(pid_groups:get_my(dht_node), self(),
                          RestI, get_max_items()),
           State#rr_recon_state{to_resolve = {ToSend1, ToReqIdx1},
                                misc = [{db_chunk, {OtherDBChunk1, OrigDBChunkLen, MyDBSize1}}]};
       true ->
           % note: the actual P1E(phase1) may be different from what the non-initiator expected
           P1E_p1 = trivial_worst_case_failprob(SigSize, OrigDBChunkLen, MyDBSize1, ExpDelta),
           Stats1  = rr_recon_stats:set([{p1e_phase1, P1E_p1}], Stats),
           NewStats = send_resolve_request(Stats1, ToSend1, OwnerL, DestRRPid,
                                           true, true),
           % let the non-initiator's rr_recon process identify the remaining keys
           ReqIdx = lists:usort([Idx || {_Version, Idx} <- mymaps:values(OtherDBChunk1)]
                                    ++ ToReqIdx1),
           ToReq2 = compress_idx_list(ReqIdx, OrigDBChunkLen - 1, [], 0, 0),
           NewStats2 =
               if ReqIdx =/= [] ->
                      % the non-initiator will use key_upd_send and we must thus increase
                      % the number of resolve processes here!
                      rr_recon_stats:inc([{rs_expected, 1}], NewStats);
                  true -> NewStats
               end,

           ?TRACE("resolve_req Trivial Session=~p ; ToReq=~p (~p bits)",
                  [rr_recon_stats:get(session_id, Stats1), length(ReqIdx),
                   erlang:bit_size(ToReq2)]),
           comm:send(DestReconPid, {resolve_req, ToReq2}),
           
           shutdown(sync_finished,
                    State#rr_recon_state{stats = NewStats2,
                                         to_resolve = {[], []},
                                         misc = []})
    end;

on({process_db, {get_chunk_response, {RestI, DBList}}} = _Msg,
   State = #rr_recon_state{stage = reconciliation,    initiator = true,
                           method = shash,            stats = Stats,
                           params = #shash_recon_struct{exp_delta = ExpDelta,
                                                        sig_size = SigSize,
                                                        p1e = P1E},
                           kv_list = KVList,
                           misc = [{db_chunk, {OtherDBChunk, OrigDBChunkLen, MyDBSize}}]}) ->
    ?TRACE1(_Msg, State),
    % this is similar to the trivial sync above and the bloom sync below

    MyDBSize1 = MyDBSize + length(DBList),
    % identify differing items and the remaining (non-matched) DBChunk:
    {NewKVList, OtherDBChunk1} =
        shash_get_full_diff(DBList, OtherDBChunk, KVList, SigSize),
    NewState =
        State#rr_recon_state{kv_list = NewKVList,
                             misc = [{db_chunk, {OtherDBChunk1, OrigDBChunkLen, MyDBSize1}}]},

    %if rest interval is non empty start another sync
    SyncFinished = intervals:is_empty(RestI),
    if not SyncFinished ->
           send_chunk_req(pid_groups:get_my(dht_node), self(),
                          RestI, get_max_items()),
           NewState;
       true ->
           % note: the actual P1E(phase1) may be different from what the non-initiator expected
           P1E_p1 = trivial_worst_case_failprob(SigSize, OrigDBChunkLen, MyDBSize1, ExpDelta),
           P1E_p2 = calc_n_subparts_p1e(1, P1E, (1 - P1E_p1)),
           Stats1  = rr_recon_stats:set([{p1e_phase1, P1E_p1}], Stats),
           CKidxSize = mymaps:size(OtherDBChunk1),
           StartResolve = NewKVList =/= [] orelse CKidxSize > 0,
           OtherDiffIdx =
               if StartResolve andalso OrigDBChunkLen > 0 ->
                      % let the non-initiator's rr_recon process identify the remaining keys
                      ReqIdx = lists:usort([Idx || {_Version, Idx} <- mymaps:values(OtherDBChunk1)]),
                      compress_idx_list(ReqIdx, OrigDBChunkLen - 1, [], 0, 0);
                  true ->
                      % no need to create a real OtherDiffIdx if phase2_run_trivial_on_diff/7 is not using it
                      <<>>
               end,
           phase2_run_trivial_on_diff(
             NewKVList, OtherDiffIdx, CKidxSize, OrigDBChunkLen, P1E_p2,
             CKidxSize, NewState#rr_recon_state{stats = Stats1})
    end;

on({process_db, {get_chunk_response, {RestI, DBList}}} = _Msg,
   State = #rr_recon_state{stage = reconciliation,    initiator = true,
                           method = bloom,
                           params = #bloom_recon_struct{exp_delta = ExpDelta,
                                                        p1e = P1E, bf = BF},
                           stats = Stats,             kv_list = KVList,
                           misc = [{item_count, MyDBSize}, {my_bf, MyBF}]}) ->
    ?TRACE1(_Msg, State),
    MyDBSize1 = MyDBSize + length(DBList),
    MyBF1 = bloom:add_list(MyBF, DBList),
    % no need to map keys since the other node's bloom filter was created with
    % keys mapped to our interval
    BFCount = bloom:item_count(BF),
    Diff = if BFCount =:= 0 -> DBList;
              true -> [X || X <- DBList, not bloom:is_element(BF, X)]
           end,
    NewKVList = lists:append(KVList, Diff),

    %if rest interval is non empty start another sync
    SyncFinished = intervals:is_empty(RestI),
    if not SyncFinished ->
           send_chunk_req(pid_groups:get_my(dht_node), self(),
                          RestI, get_max_items()),
           State#rr_recon_state{kv_list = NewKVList,
                                misc = [{item_count, MyDBSize1}, {my_bf, MyBF1}]};
       true ->
           % here, the failure probability is correct (in contrast to the
           % non-initiator) since we know how many item checks we perform with
           % the BF and how many checks the non-initiator will perform on MyBF1
           P1E_p1_bf1_real = bloom_worst_case_failprob(BF, MyDBSize1, ExpDelta),
           P1E_p1_bf2_real = bloom_worst_case_failprob(MyBF1, BFCount, ExpDelta),
           P1E_p1_real = 1 - (1 - P1E_p1_bf1_real) * (1 - P1E_p1_bf2_real),
%%            log:pal("~w: [ ~p:~.0p ]~n NI:~p, P1E_bf=~p~n"
%%                    " Bloom1: m=~B k=~B BFCount=~B Checks=~B P1E_bf1=~p~n"
%%                    " Bloom2: m=~B k=~B BFCount=~B Checks=~B P1E_bf2=~p",
%%                    [?MODULE, pid_groups:my_groupname(), self(),
%%                     State#rr_recon_state.dest_recon_pid,
%%                     calc_n_subparts_p1e(2, _P1E_p1 = calc_n_subparts_p1e(2, P1E)),
%%                     bloom:get_property(BF, size), ?REP_HFS:size(bloom:get_property(BF, hfs)),
%%                     BFCount, MyDBSize1, P1E_p1_bf1_real,
%%                     bloom:get_property(MyBF1, size), ?REP_HFS:size(bloom:get_property(MyBF1, hfs)),
%%                     bloom:item_count(MyBF1), BFCount, P1E_p1_bf2_real]),
           Stats1  = rr_recon_stats:set([{p1e_phase1, P1E_p1_real}], Stats),
           DiffBF = util:bin_xor(bloom:get_property(BF, filter),
                                 bloom:get_property(MyBF1, filter)),
           % NOTE: use left-over P1E after phase 1 (bloom) for phase 2 (trivial RC)
           P1E_p2 = calc_n_subparts_p1e(1, P1E, (1 - P1E_p1_real)),
           phase2_run_trivial_on_diff(
             NewKVList, DiffBF,
             % note: this is not the number of (unmatched) elements but the binary size:
             erlang:byte_size(erlang:term_to_binary(DiffBF, [compressed])),
             BFCount, P1E_p2, BFCount,
             State#rr_recon_state{params = {}, kv_list = NewKVList,
                                  stats = Stats1})
    end;

on({process_db, {get_chunk_response, {RestI, DBList}}} = _Msg,
   State = #rr_recon_state{stage = reconciliation,     initiator = true,
                           method = RMethod})
  when RMethod =:= merkle_tree orelse RMethod =:= art->
    ?TRACE1(_Msg, State),
    build_struct(DBList, RestI, State);

on({fd_notify, crash, _Pid, _Reason} = _Msg, State) ->
    ?TRACE1(_Msg, State),
    shutdown(recon_node_crash, State);

on({fd_notify, _Event, _Pid, _Reason} = _Msg, State) ->
    State;

on({shutdown, Reason}, State) ->
    shutdown(Reason, State);

on({'DOWN', MonitorRef, process, _Owner, _Info}, _State) ->
    log:log(info, "[ ~p - ~p] shutdown due to rrepair shut down", [?MODULE, comm:this()]),
    gen_component:demonitor(MonitorRef),
    kill;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% trivial/shash/bloom/art reconciliation sync messages
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

on({resolve_req, shutdown} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = false,
                           method = RMethod})
  when (RMethod =:= bloom orelse RMethod =:= shash orelse RMethod =:= art) ->
    shutdown(sync_finished, State);

on({resolve_req, BinReqIdxPos} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = false,
                           method = trivial,
                           dest_rr_pid = DestRRPid,   ownerPid = OwnerL,
                           k_list = KList,            stats = Stats}) ->
    ?TRACE1(_Msg, State),
    NewStats =
        send_resolve_request(Stats, decompress_idx_to_list(BinReqIdxPos, KList),
                             OwnerL, DestRRPid, _Initiator = false, true),
    shutdown(sync_finished, State#rr_recon_state{stats = NewStats});

on({resolve_req, OtherDBChunk, MyDiffIdx, SigSize, VSize, DestReconPid} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = false,
                           method = shash,            kv_list = KVList}) ->
    ?TRACE1(_Msg, State),
%%     log:pal("[ ~p ] CKIdx1: ~B (~B compressed)",
%%             [self(), erlang:byte_size(MyDiffIdx),
%%              erlang:byte_size(erlang:term_to_binary(MyDiffIdx, [compressed]))]),
    ?DBG_ASSERT(SigSize >= 0 andalso VSize >= 0),

    {DBChunkTree, _OrigDBChunkLen} =
        decompress_kv_list(OtherDBChunk, SigSize, VSize),
    MyDiffKV = decompress_idx_to_list(MyDiffIdx, KVList),
    State1 = State#rr_recon_state{kv_list = MyDiffKV},
    FBItems = [Key || {Key, _Version} <- MyDiffKV,
                      not mymaps:is_key(compress_key(Key, SigSize),
                                        DBChunkTree)],

    NewStats2 = shash_bloom_perform_resolve(
                  State1, DBChunkTree, SigSize, VSize, DestReconPid, FBItems),

    shutdown(sync_finished, State1#rr_recon_state{stats = NewStats2});

on({resolve_req, DBChunk, DiffBF, SigSize, VSize, DestReconPid} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = false,
                           method = bloom,            kv_list = KVList,
                           struct = #bloom_recon_struct{bf = MyBFBin,
                                                        hf_count = MyHfCount}}) ->
    ?TRACE1(_Msg, State),
    
    {DBChunkTree, _OrigDBChunkLen} =
        decompress_kv_list(DBChunk, SigSize, VSize),
    
    Hfs = ?REP_HFS:new(MyHfCount),
    OtherBF = bloom:new_bin(util:bin_xor(MyBFBin, DiffBF),
                            Hfs, 0), % fake item count (this is not used here!)
    FBItems = [Key || X = {Key, _Version} <- KVList,
                      not mymaps:is_key(compress_key(Key, SigSize),
                                        DBChunkTree),
                      not bloom:is_element(OtherBF, X)],

    NewStats2 = shash_bloom_perform_resolve(
                  State, DBChunkTree, SigSize, VSize, DestReconPid, FBItems),
    shutdown(sync_finished, State#rr_recon_state{stats = NewStats2});

on({resolve_req, DBChunk, SigSize, VSize, DestReconPid} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = false,
                           method = art}) ->
    ?TRACE1(_Msg, State),
    
    {DBChunkTree, _OrigDBChunkLen} =
        decompress_kv_list(DBChunk, SigSize, VSize),

    NewStats2 = shash_bloom_perform_resolve(
                  State, DBChunkTree, SigSize, VSize, DestReconPid, []),
    shutdown(sync_finished, State#rr_recon_state{stats = NewStats2});

on({resolve_req, BinReqIdxPos} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = true,
                           method = RMethod,
                           dest_rr_pid = DestRRPid,   ownerPid = OwnerL,
                           k_list = KList,            stats = Stats,
                           misc = [{my_bin_diff_empty, MyBinDiffEmpty}]})
  when (RMethod =:= bloom orelse RMethod =:= shash orelse RMethod =:= art) ->
    ?TRACE1(_Msg, State),
%%     log:pal("[ ~p ] CKIdx2: ~B (~B compressed)",
%%             [self(), erlang:byte_size(BinReqIdxPos),
%%              erlang:byte_size(erlang:term_to_binary(BinReqIdxPos, [compressed]))]),
    ToSend = if MyBinDiffEmpty -> KList; % optimised away by using 0 bits -> sync all!
                true           -> bitstring_to_k_list_k(BinReqIdxPos, KList, [])
             end,
    NewStats = send_resolve_request(
                 Stats, ToSend, OwnerL, DestRRPid, _Initiator = true, true),
    shutdown(sync_finished, State#rr_recon_state{stats = NewStats});

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% merkle tree sync messages
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

on({?check_nodes, SenderPid, ToCheck, OtherMaxItemsCount}, State) ->
    NewState = State#rr_recon_state{dest_recon_pid = SenderPid},
    on({?check_nodes, ToCheck, OtherMaxItemsCount}, NewState);

on({?check_nodes, ToCheck0, OtherMaxItemsCount},
   State = #rr_recon_state{stage = reconciliation,    initiator = false,
                           method = merkle_tree,      merkle_sync = Sync,
                           params = #merkle_params{} = Params,
                           struct = TreeNodes,        stats = Stats,
                           dest_recon_pid = DestReconPid,
                           misc = [{p1e, LastP1ETotal},
                                   {p1e_phase_x, P1EPhaseX},
                                   {icount, MyLastMaxItemsCount}]}) ->
    ?DBG_ASSERT(comm:is_valid(DestReconPid)),
    {_P1E_I, _P1E_L, SigSizeI, SigSizeL, EffectiveP1E_I, EffectiveP1E_L} =
        merkle_next_signature_sizes(Params, LastP1ETotal, MyLastMaxItemsCount,
                                    OtherMaxItemsCount),
    ToCheck = merkle_decompress_hashlist(ToCheck0, SigSizeI, SigSizeL),
    PrevP0E = 1 - rr_recon_stats:get(p1e_phase1, Stats),
    {FlagsBin, RTree, SyncNew, NStats0, MyMaxItemsCount,
     NextLvlNodesAct, HashCmpI, HashCmpL} =
        merkle_check_node(ToCheck, TreeNodes, SigSizeI, SigSizeL,
                          MyLastMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                          <<>>, [], [], [], 0, [], 0, 0, Sync, 0, 0, 0,
                          0, 0),
    ?IIF((EffectiveP1E_I > 0 andalso (1 - EffectiveP1E_I >= 1)) orelse
             (1 - EffectiveP1E_L >= 1), % EffectiveP1E_L is always greater than 0
         log:log("~w: [ ~p:~.0p ] merkle_next_signature_sizes/4 precision warning:"
                 " P1E_I = ~g, P1E_L = ~g",
                 [?MODULE, pid_groups:my_groupname(), self(),
                  EffectiveP1E_I, EffectiveP1E_L]),
         ok),
    NextP0E = PrevP0E * math:pow(1 - EffectiveP1E_I, HashCmpI)
                  * math:pow(1 - EffectiveP1E_L, HashCmpL),
    NStats = rr_recon_stats:set([{p1e_phase1, 1 - NextP0E}], NStats0),
    NewState = State#rr_recon_state{struct = RTree, merkle_sync = SyncNew},
    ?MERKLE_DEBUG("merkle (NI) - CurrentNodes: ~B~nP1E: ~g -> ~g",
                  [length(RTree), 1 - PrevP0E, 1 - NextP0E]),
    send(DestReconPid, {?check_nodes_response, FlagsBin, MyMaxItemsCount}),
    
    if RTree =:= [] ->
           % start a (parallel) resolve (if items to resolve)
           merkle_resolve_leaves_send(NewState, NextP0E);
       true ->
           ?DBG_ASSERT(NextLvlNodesAct >= 0),
           % calculate the remaining trees' failure prob based on the already
           % used failure prob
           P1E_I_2 = calc_n_subparts_p1e(NextLvlNodesAct, P1EPhaseX, NextP0E),
           NewState#rr_recon_state{stats = NStats,
                                   misc = [{p1e, P1E_I_2},
                                           {p1e_phase_x, P1EPhaseX},
                                           {icount, MyMaxItemsCount}]}
    end;

on({?check_nodes_response, FlagsBin, OtherMaxItemsCount},
   State = #rr_recon_state{stage = reconciliation,        initiator = true,
                           method = merkle_tree,          merkle_sync = Sync,
                           params = #merkle_params{} = Params,
                           struct = TreeNodes,            stats = Stats,
                           dest_recon_pid = DestReconPid,
                           misc = [{signature_size, {SigSizeI, SigSizeL}},
                                   {p1e, {EffectiveP1ETotal_I, EffectiveP1ETotal_L}},
                                   {p1e_phase_x, P1EPhaseX},
                                   {icount, MyLastMaxItemsCount},
                                   {oicount, OtherLastMaxItemsCount}]}) ->
    PrevP0E = 1 - rr_recon_stats:get(p1e_phase1, Stats),
    {RTree, SyncNew, NStats0, MyMaxItemsCount,
     NextLvlNodesAct, HashCmpI, HashCmpL} =
        merkle_cmp_result(FlagsBin, TreeNodes, SigSizeI, SigSizeL,
                          MyLastMaxItemsCount, OtherLastMaxItemsCount,
                          Sync, Params, Stats, [], [], [], 0, [], 0, 0, 0, 0, 0,
                          0, 0),
    ?IIF((1 - EffectiveP1ETotal_I >= 1) orelse (1 - EffectiveP1ETotal_L >= 1),
         log:log("~w: [ ~p:~.0p ] merkle_next_signature_sizes/4 precision warning:"
                 " P1E_I = ~g, P1E_L = ~g",
                 [?MODULE, pid_groups:my_groupname(), self(),
                  EffectiveP1ETotal_I, EffectiveP1ETotal_L]),
         ok),
    NextP0E = PrevP0E * math:pow(1 - EffectiveP1ETotal_I, HashCmpI)
                  * math:pow(1 - EffectiveP1ETotal_L, HashCmpL),
    NStats = rr_recon_stats:set([{p1e_phase1, 1 - NextP0E}], NStats0),
    NewState = State#rr_recon_state{struct = RTree, merkle_sync = SyncNew},
    ?MERKLE_DEBUG("merkle (I) - CurrentNodes: ~B~nP1E: ~g -> ~g",
                  [length(RTree), 1 - PrevP0E, rr_recon_stats:get(p1e_phase1, NStats)]),

    if RTree =:= [] ->
           % start a (parallel) resolve (if items to resolve)
           merkle_resolve_leaves_send(NewState, NextP0E);
       true ->
           ?DBG_ASSERT(NextLvlNodesAct >= 0),
           % calculate the remaining trees' failure prob based on the already
           % used failure prob
           P1ETotal_I_2 = calc_n_subparts_p1e(NextLvlNodesAct, P1EPhaseX, NextP0E),
           {_P1E_I, _P1E_L, NextSigSizeI, NextSigSizeL, EffectiveP1E_I, EffectiveP1E_L} =
               merkle_next_signature_sizes(Params, P1ETotal_I_2, MyMaxItemsCount,
                                           OtherMaxItemsCount),
           Req = merkle_compress_hashlist(RTree, <<>>, NextSigSizeI, NextSigSizeL),
           send(DestReconPid, {?check_nodes, Req, MyMaxItemsCount}),
           NewState#rr_recon_state{stats = NStats,
                                   misc = [{signature_size, {NextSigSizeI, NextSigSizeL}},
                                           {p1e, {EffectiveP1E_I, EffectiveP1E_L}},
                                           {p1e_phase_x, P1EPhaseX},
                                           {icount, MyMaxItemsCount},
                                           {oicount, OtherMaxItemsCount}]}
    end;

on({resolve_req, HashesK, HashesV} = _Msg,
   State = #rr_recon_state{stage = resolve,           method = merkle_tree})
  when is_bitstring(HashesK) andalso is_bitstring(HashesV) ->
    ?TRACE1(_Msg, State),
    % NOTE: FIFO channels ensure that the {resolve_req, BinKeyList} is always
    %       received after the {resolve_req, Hashes} message from the other node!
    merkle_resolve_leaves_receive(State, HashesK, HashesV);

on({resolve_req, BinKeyList} = _Msg,
   State = #rr_recon_state{stage = resolve,           initiator = IsInitiator,
                           method = merkle_tree,
                           merkle_sync = {SyncSend, [], SyncRcvLeafCount, DirectResolve},
                           params = Params,
                           dest_rr_pid = DestRRPid,   ownerPid = OwnerL,
                           stats = Stats})
    % NOTE: FIFO channels ensure that the {resolve_req, BinKeyList} is always
    %       received after the {resolve_req, Hashes} message from the other node!
  when is_bitstring(BinKeyList) ->
    ?MERKLE_DEBUG("merkle (~s) - BinKeyListSize: ~B compressed",
                  [?IIF(IsInitiator, "I", "NI"),
                   erlang:byte_size(
                     erlang:term_to_binary(BinKeyList, [compressed]))]),
    ?TRACE1(_Msg, State),
    NStats = if BinKeyList =:= <<>> ->
                    Stats;
                true ->
                    merkle_resolve_leaves_ckidx(
                      SyncSend, BinKeyList, DestRRPid, Stats, OwnerL,
                      Params, [], IsInitiator)
             end,
    NewState = State#rr_recon_state{merkle_sync = {[], [], SyncRcvLeafCount, DirectResolve},
                                    stats = NStats},
    shutdown(sync_finished, NewState).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec build_struct(DBList::db_chunk_kv(),
                   RestI::intervals:interval(), state()) -> state() | kill.
build_struct(DBList, RestI,
             State = #rr_recon_state{method = RMethod, params = Params,
                                     struct = {},
                                     initiator = Initiator, stats = Stats,
                                     kv_list = KVList,
                                     'sync_interval@I' = SyncI,
                                     'max_items@I' = InitiatorMaxItems}) ->
    ?DBG_ASSERT(?implies(RMethod =/= merkle_tree andalso RMethod =/= art,
                         not Initiator)),
    % note: RestI already is a sub-interval of the sync interval
    BeginSync = intervals:is_empty(RestI),
    NewKVList0 = [DBList | KVList],
    if BeginSync ->
           NewKVList = lists:append(lists:reverse(NewKVList0)),
           ToBuild = if Initiator andalso RMethod =:= art -> merkle_tree;
                        true -> RMethod
                     end,
           {BuildTime, {SyncStruct, P1E_p1}} =
               util:tc(
                 fun() -> build_recon_struct(ToBuild, SyncI, NewKVList,
                                             InitiatorMaxItems, Params)
                 end),
           Stats1 = rr_recon_stats:inc([{build_time, BuildTime}], Stats),
           Stats2  = rr_recon_stats:set([{p1e_phase1, P1E_p1}], Stats1),
           NewState = State#rr_recon_state{struct = SyncStruct, stats = Stats2,
                                           kv_list = NewKVList},
           begin_sync(Params, NewState#rr_recon_state{stage = reconciliation});
       true ->
           send_chunk_req(pid_groups:get_my(dht_node), self(),
                          RestI, get_max_items()),
           % keep stage (at initiator: reconciliation, at other: build_struct)
           State#rr_recon_state{kv_list = NewKVList0}
    end.

-spec begin_sync(OtherSyncStruct::parameters() | {}, state()) -> state() | kill.
begin_sync(_OtherSyncStruct = {},
           State = #rr_recon_state{method = trivial, initiator = false,
                                   struct = MySyncStruct,
                                   ownerPid = OwnerL, stats = Stats,
                                   dest_rr_pid = DestRRPid, kv_list = _KVList}) ->
    ?TRACE("BEGIN SYNC", []),
    SID = rr_recon_stats:get(session_id, Stats),
    {KList, VList, ResortedKVOrigList} = MySyncStruct#trivial_recon_struct.db_chunk,
    MySyncStruct1 = MySyncStruct#trivial_recon_struct{db_chunk = {KList, VList}},
    send(DestRRPid, {continue_recon, comm:make_global(OwnerL), SID,
                     {start_recon, trivial, MySyncStruct1}}),
    State#rr_recon_state{struct = {}, stage = resolve, kv_list = [],
                         k_list = [K || {K, _V} <- ResortedKVOrigList]};
begin_sync(_OtherSyncStruct = {},
           State = #rr_recon_state{method = shash, initiator = false,
                                   struct = MySyncStruct,
                                   ownerPid = OwnerL, stats = Stats,
                                   dest_rr_pid = DestRRPid, kv_list = _KVList}) ->
    ?TRACE("BEGIN SYNC", []),
    SID = rr_recon_stats:get(session_id, Stats),
    {KList, ResortedKVOrigList} = MySyncStruct#shash_recon_struct.db_chunk,
    MySyncStruct1 = MySyncStruct#shash_recon_struct{db_chunk = KList},
    send(DestRRPid, {continue_recon, comm:make_global(OwnerL), SID,
                     {start_recon, shash, MySyncStruct1}}),
    case MySyncStruct1#shash_recon_struct.db_chunk of
        <<>> -> shutdown(sync_finished, State#rr_recon_state{struct = {}, kv_list = []});
        _    -> State#rr_recon_state{struct = {}, stage = resolve, kv_list = ResortedKVOrigList}
    end;
begin_sync(_OtherSyncStruct = {},
           State = #rr_recon_state{method = bloom, initiator = false,
                                   struct = MySyncStruct,
                                   ownerPid = OwnerL, stats = Stats,
                                   dest_rr_pid = DestRRPid}) ->
    ?TRACE("BEGIN SYNC", []),
    SID = rr_recon_stats:get(session_id, Stats),
    BFBin = bloom:get_property(MySyncStruct#bloom_recon_struct.bf, filter),
    MySyncStruct1 = MySyncStruct#bloom_recon_struct{bf = BFBin},
    send(DestRRPid, {continue_recon, comm:make_global(OwnerL), SID,
                     {start_recon, bloom, MySyncStruct1}}),
    case MySyncStruct#bloom_recon_struct.item_count of
        0 -> shutdown(sync_finished, State#rr_recon_state{kv_list = []});
        _ -> State#rr_recon_state{struct = MySyncStruct1, stage = resolve}
    end;
begin_sync(_OtherSyncStruct = {},
           State = #rr_recon_state{method = merkle_tree, initiator = false,
                                   struct = MySyncStruct,
                                   ownerPid = OwnerL, stats = Stats,
                                   dest_rr_pid = DestRRPid}) ->
    ?TRACE("BEGIN SYNC", []),
    % tell the initiator to create its struct first, and then build ours
    % (at this stage, we do not have any data in the merkle tree yet!)
    DBItems = State#rr_recon_state.kv_list,
    MerkleI = merkle_tree:get_interval(MySyncStruct),
    MerkleV = merkle_tree:get_branch_factor(MySyncStruct),
    MerkleB = merkle_tree:get_bucket_size(MySyncStruct),
    NumTrees = get_merkle_num_trees(),
    P1ETotal = get_p1e(),
    P1ETotal2 = calc_n_subparts_p1e(2, P1ETotal),
    
    % split interval first and create NumTrees merkle trees later
    {BuildTime1, ICBList} =
        util:tc(fun() ->
                        merkle_tree:keys_to_intervals(
                          DBItems, intervals:split(MerkleI, NumTrees))
                end),
    ItemCount = lists:max([0 | [Count || {_SubI, Count, _Bucket} <- ICBList]]),
    P1ETotal3 = calc_n_subparts_p1e(NumTrees, P1ETotal2),
    
    MySyncParams = #merkle_params{interval = MerkleI,
                                  branch_factor = MerkleV,
                                  bucket_size = MerkleB,
                                  num_trees = NumTrees,
                                  p1e = P1ETotal,
                                  ni_item_count = ItemCount},
    SyncParams = MySyncParams#merkle_params{reconPid = comm:this()},
    SID = rr_recon_stats:get(session_id, Stats),
    send(DestRRPid, {continue_recon, comm:make_global(OwnerL), SID,
                     {start_recon, merkle_tree, SyncParams}}),
    
    % finally create the real merkle tree containing data
    % -> this way, the initiator can create its struct in parallel!
    {BuildTime2, SyncStruct} =
        util:tc(fun() ->
                        [merkle_tree:get_root(
                           merkle_tree:new(SubI, Bucket,
                                           [{keep_bucket, true},
                                            {branch_factor, MerkleV},
                                            {bucket_size, MerkleB}]))
                           || {SubI, _Count, Bucket} <- ICBList]
                end),
    MTSize = merkle_tree:size_detail(SyncStruct),
    Stats1 = rr_recon_stats:set([{tree_size, MTSize}], Stats),
    Stats2 = rr_recon_stats:inc([{build_time, BuildTime1 + BuildTime2}], Stats1),
    ?MERKLE_DEBUG("merkle (NI) - CurrentNodes: ~B~n"
                  "Inner/Leaf/Items: ~p, EmptyLeaves: ~B",
                  [length(SyncStruct), MTSize,
                   length([ok || L <- merkle_tree:get_leaves(SyncStruct),
                                 merkle_tree:is_empty(L)])]),
    
    State#rr_recon_state{struct = SyncStruct,
                         stats = Stats2, params = MySyncParams,
                         misc = [{p1e, P1ETotal3},
                                 {p1e_phase_x, P1ETotal2},
                                 {icount, ItemCount}],
                         kv_list = []};
begin_sync(OtherSyncStruct,
           State = #rr_recon_state{method = merkle_tree, initiator = true,
                                   struct = MySyncStruct, stats = Stats,
                                   dest_recon_pid = DestReconPid}) ->
    ?TRACE("BEGIN SYNC", []),
    MTSize = merkle_tree:size_detail(MySyncStruct),
    Stats1 = rr_recon_stats:set([{tree_size, MTSize}], Stats),
    #merkle_params{p1e = P1ETotal, num_trees = NumTrees,
                   ni_item_count = OtherItemsCount} = OtherSyncStruct,
    MyItemCount =
        lists:max([0 | [merkle_tree:get_item_count(Node) || Node <- MySyncStruct]]),
    ?MERKLE_DEBUG("merkle (I) - CurrentNodes: ~B~n"
                  "Inner/Leaf/Items: ~p, EmptyLeaves: ~B",
                  [length(MySyncStruct), MTSize,
                   length([ok || L <- merkle_tree:get_leaves(MySyncStruct),
                                 merkle_tree:is_empty(L)])]),
    P1ETotal2 = calc_n_subparts_p1e(2, P1ETotal),
    P1ETotal3 = calc_n_subparts_p1e(NumTrees, P1ETotal2),
    
    {_P1E_I, _P1E_L, NextSigSizeI, NextSigSizeL, EffectiveP1E_I, EffectiveP1E_L} =
        merkle_next_signature_sizes(OtherSyncStruct, P1ETotal3, MyItemCount,
                                    OtherItemsCount),
    
    Req = merkle_compress_hashlist(MySyncStruct, <<>>, NextSigSizeI, NextSigSizeL),
    send(DestReconPid, {?check_nodes, comm:this(), Req, MyItemCount}),
    State#rr_recon_state{stats = Stats1,
                         misc = [{signature_size, {NextSigSizeI, NextSigSizeL}},
                                 {p1e, {EffectiveP1E_I, EffectiveP1E_L}},
                                 {p1e_phase_x, P1ETotal2},
                                 {icount, MyItemCount},
                                 {oicount, OtherItemsCount}],
                         kv_list = []};
begin_sync(_OtherSyncStruct = {},
           State = #rr_recon_state{method = art, initiator = false,
                                   struct = MySyncStruct,
                                   ownerPid = OwnerL, stats = Stats,
                                   dest_rr_pid = DestRRPid}) ->
    ?TRACE("BEGIN SYNC", []),
    SID = rr_recon_stats:get(session_id, Stats),
    send(DestRRPid, {continue_recon, comm:make_global(OwnerL), SID,
                     {start_recon, art, MySyncStruct}}),
    case art:get_property(MySyncStruct#art_recon_struct.art, items_count) of
        0 -> shutdown(sync_finished, State#rr_recon_state{kv_list = []});
        _ -> State#rr_recon_state{struct = {}, stage = resolve}
    end;
begin_sync(OtherSyncStruct,
           State = #rr_recon_state{method = art, initiator = true,
                                   struct = MySyncStruct, stats = Stats,
                                   dest_recon_pid = DestReconPid}) ->
    ?TRACE("BEGIN SYNC", []),
    ART = OtherSyncStruct#art_recon_struct.art,
    Stats1 = rr_recon_stats:set(
               [{tree_size, merkle_tree:size_detail(MySyncStruct)}], Stats),
    OtherItemCount = art:get_property(ART, items_count),
    case merkle_tree:get_interval(MySyncStruct) =:= art:get_interval(ART) of
        true ->
            {ASyncLeafs, NComp, NSkip, NLSync} =
                art_get_sync_leaves([merkle_tree:get_root(MySyncStruct)], ART,
                                    [], 0, 0, 0),
            Diff = lists:append([merkle_tree:get_bucket(N) || N <- ASyncLeafs]),
            MyItemCount = merkle_tree:get_item_count(MySyncStruct),
            P1E = get_p1e(),
            % TODO: correctly calculate the probabilities and select appropriate parameters beforehand
            P1E_p1_0 = bloom_worst_case_failprob(
                         art:get_property(ART, leaf_bf), MyItemCount, 100), % TODO: adapt ExpDelta
            P1E_p1 = if P1E_p1_0 == 1 ->
                            log:log("~w: [ ~p:~.0p ] P1E constraint broken (phase 1 overstepped?)"
                                    " - continuing with smallest possible failure probability",
                                    [?MODULE, pid_groups:my_groupname(), self()]),
                            1 - 1.0e-16;
                        true -> P1E_p1_0
                     end,
            Stats2  = rr_recon_stats:set([{p1e_phase1, P1E_p1}], Stats1),
            % NOTE: use left-over P1E after phase 1 (ART) for phase 2 (trivial RC)
            P1E_p2 = calc_n_subparts_p1e(1, P1E, (1 - P1E_p1)),
            
            Stats3 = rr_recon_stats:inc([{tree_nodesCompared, NComp},
                                         {tree_compareSkipped, NSkip},
                                         {tree_leavesSynced, NLSync}], Stats2),
            
            phase2_run_trivial_on_diff(Diff, none, 0, OtherItemCount,
                                       P1E_p2, OtherItemCount,
                                       State#rr_recon_state{stats = Stats3});
        false when OtherItemCount =/= 0 ->
            % must send resolve_req message for the non-initiator to shut down
            send(DestReconPid, {resolve_req, shutdown}),
            shutdown(sync_finished, State#rr_recon_state{stats = Stats1,
                                                         kv_list = []});
        false ->
            shutdown(sync_finished, State#rr_recon_state{stats = Stats1,
                                                         kv_list = []})
    end.

-spec shutdown(exit_reason(), state()) -> kill.
shutdown(Reason, #rr_recon_state{ownerPid = OwnerL, stats = Stats,
                                 initiator = Initiator, dest_rr_pid = DestRR,
                                 dest_recon_pid = DestRC, method = RMethod,
                                 'sync_interval@I' = SyncI}) ->
    ?TRACE("SHUTDOWN Session=~p Reason=~p",
           [rr_recon_stats:get(session_id, Stats), Reason]),

    % unsubscribe from fd if a subscription was made:
    case Initiator orelse (not intervals:is_empty(SyncI)) of
        true ->
            case RMethod of
                trivial -> fd:unsubscribe(self(), [DestRR]);
                bloom   -> fd:unsubscribe(self(), [DestRR]);
                merkle_tree -> fd:unsubscribe(self(), [DestRR]);
                _ -> ok
            end;
        false -> ok
    end,

    Status = exit_reason_to_rc_status(Reason),
    NewStats = rr_recon_stats:set([{status, Status}], Stats),
    send_local(OwnerL, {recon_progress_report, comm:this(), Initiator, DestRR,
                        DestRC, NewStats}),
    kill.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% KV-List compression
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Calculates the minimum number of bits needed to have a hash collision
%%      probability of P1E, given we compare N hashes with M other hashes
%%      pairwise with each other (assuming that ExpDelta percent of them are
%%      different).
-spec calc_signature_size_nm_pair(N::non_neg_integer(), M::non_neg_integer(),
                                  ExpDelta::number(), P1E::float(),
                                  MaxSize::signature_size())
        -> SigSize::signature_size().
calc_signature_size_nm_pair(_, 0, _ExpDelta, P1E, _MaxSize)
  when P1E > 0 andalso P1E < 1 ->
    0;
calc_signature_size_nm_pair(0, _, _ExpDelta, P1E, _MaxSize)
  when P1E > 0 andalso P1E < 1 ->
    0;
calc_signature_size_nm_pair(N, M, ExpDelta, P1E, MaxSize)
  when P1E > 0 andalso P1E < 1 ->
    P = if P1E < 1.0e-8 ->
               % BEWARE: we cannot use (1-p1E) since it is near 1 and its floating
               %         point representation is sub-optimal!
               % => use Taylor expansion of math:log(1 / (1-P1E))  at P1E = 0
               %    (small terms first)
               % http://www.wolframalpha.com/input/?i=Taylor+expansion+of+log%281+%2F+%281-p%29%29++at+p+%3D+0
               P1E2 = P1E * P1E, P1E3 = P1E2* P1E, P1E4 = P1E3 * P1E, P1E5 = P1E4 * P1E,
               P1E + P1E2/2 + P1E3/3 + P1E4/4 + P1E5/5; % +O[p^6]
           true ->
               math:log(1 / (1 - P1E))
        end,
    NT = calc_max_different_hashes(N, M, ExpDelta),
    min_max(util:ceil(util:log2(NT * (NT - 1) / (2 * P))), get_min_hash_bits(), MaxSize).

%% @doc Helper for calc_signature_size_nm_pair/5 calculating the maximum number
%%      of different hashes when an upper bound on the delta is known.
-spec calc_max_different_hashes(N::non_neg_integer(), M::non_neg_integer(),
                                ExpDelta::number()) -> non_neg_integer().
calc_max_different_hashes(N, M, ExpDelta) when ExpDelta >= 0 andalso ExpDelta =< 100 ->
    if ExpDelta == 0 ->
           % M and N may differ anyway if the actual delta is higher
           % -> target no collisions among items on any node!
           erlang:max(M, N);
       ExpDelta == 100 ->
           M + N; % special case of the one below
       is_float(ExpDelta) ->
           % assume the worst case, i.e. ExpDelta percent different hashes
           % on both nodes together, e.g. due to missing items, and thus:
           % N = NT * (100 - ExpDelta * alpha) / 100 and
           % M = NT * (100 - ExpDelta * (1-alpha)) / 100
           util:ceil(((M + N) * 100) / (200 - ExpDelta));
       is_integer(ExpDelta) ->
           % -> use integer division (and round up) for higher precision:
           ((M + N) * 100 + 200 - ExpDelta - 1) div (200 - ExpDelta)
    end.

-spec calc_items_in_chunk(DBChunk::bitstring(), BitsPerItem::non_neg_integer())
-> NrItems::non_neg_integer().
calc_items_in_chunk(<<>>, 0) -> 0;
calc_items_in_chunk(DBChunk, BitsPerItem) ->
    ?DBG_ASSERT(erlang:bit_size(DBChunk) rem BitsPerItem =:= 0),
    erlang:bit_size(DBChunk) div BitsPerItem.

%% @doc Transforms a list of key and version tuples (with unique keys), into a
%%      compact binary representation for transfer.
-spec compress_kv_list(
        KVList::db_chunk_kv(), {KeyDiff::Bin, VBin::Bin},
        SigSize, VSize::signature_size(),
        KeyComprFun::fun(({?RT:key(), client_version()}, SigSize) -> bitstring()))
        -> {KeyDiff::Bin, VBin::Bin, ResortedKOrigList::db_chunk_kv()}
    when is_subtype(Bin, bitstring()),
         is_subtype(SigSize, signature_size()).
compress_kv_list([_ | _], {AccDiff, AccV}, 0, 0, _KeyComprFun) ->
    {AccDiff, AccV, []};
compress_kv_list([_ | _] = KVList, {AccDiff, AccV}, SigSize, VSize, KeyComprFun) ->
    SortedKVList = lists:sort([{KeyComprFun(X, SigSize), V, X}
                              || X = {_K0, V} <- KVList]),
    {KList, VList, KV0List} = lists:unzip3(SortedKVList),
    DiffKBin = compress_idx_list(KList, util:pow(2, SigSize) - 1, [], 0, 0),
    DiffVBin = if VSize =:= 0 -> AccV;
                  true -> lists:foldl(fun(V, Acc) ->
                                              <<Acc/bitstring, V:VSize>>
                                      end, AccV, VList)
               end,
    {<<AccDiff/bitstring, DiffKBin/bitstring>>, DiffVBin, KV0List};
compress_kv_list([], {AccDiff, AccV}, _SigSize, _VSize, _KeyComprFun) ->
    {AccDiff, AccV, []}.

%% @doc De-compresses the binary from compress_kv_list/6 into a map with a
%%      binary key representation and the integer of the (shortened) version.
-spec decompress_kv_list(CompressedBin::{KeyDiff::bitstring(), VBin::bitstring()},
                         SigSize::signature_size(), VSize::signature_size())
        -> {ResTree::kvi_tree(), NumKeys::non_neg_integer()}.
decompress_kv_list({<<>>, <<>>}, _SigSize, _VSize) ->
    {mymaps:new(), 0};
decompress_kv_list({KeyDiff, VBin}, SigSize, VSize) ->
    {KList, KListLen} = decompress_idx_list(KeyDiff, util:pow(2, SigSize) - 1),
    {<<>>, Res, _} =
        lists:foldl(
          fun(CurKeyX, {<<Version:VSize, T/bitstring>>, AccX, CurPosX}) ->
                  {T, [{CurKeyX, {Version, CurPosX}} | AccX], CurPosX + 1}
          end, {VBin, [], 0}, KList),
    KVMap = mymaps:from_list(Res),
    % deal with duplicates:
    KVMap1 =
        case mymaps:size(KVMap) of
            KListLen -> KVMap;
            KVMapSize ->
                log:log("~w: [ ~p:~.0p ] hash collision detected"
                        " (redundant item transfers expected)",
                        [?MODULE, pid_groups:my_groupname(), self()]),
                % there are duplicates! (items were mapped to the same key)
                % -> remove them from the map so we send these items to the other node
                % since every key must be in the map, we remove them one by one
                % and check whether something was removed (ok) or not (duplicate)
                element(3, lists:foldl(
                          fun(CurKeyX, {UnprocessedX, OldSize, NewMapX}) ->
                                  UnprocessedX1 = mymaps:remove(CurKeyX, UnprocessedX),
                                  case mymaps:size(UnprocessedX1) of
                                      OldSize -> % already removed -> duplicate
                                          {UnprocessedX1, OldSize,
                                           mymaps:remove(CurKeyX, NewMapX)};
                                      NewSize -> % first occurence
                                          {UnprocessedX1, NewSize, NewMapX}
                                  end
                          end, {KVMap, KVMapSize, KVMap}, KList))
        end,
    {KVMap1, KListLen}.

%% @doc Gets all entries from MyEntries which are not encoded in MyIOtherKvTree
%%      or the entry in MyEntries has a newer version than the one in the tree
%%      and returns them as FBItems. ReqItems contains items in the tree but
%%      where the version in MyEntries is older than the one in the tree.
-spec get_full_diff(MyEntries::db_chunk_kv(), MyIOtherKvTree::kvi_tree(),
                    AccFBItems::[?RT:key()], AccReqItems::[non_neg_integer()],
                    SigSize::signature_size(), VSize::signature_size())
        -> {FBItems::[?RT:key()], ReqItemsIdx::[non_neg_integer()],
            MyIOtherKvTree::kvi_tree()}.
get_full_diff(MyEntries, MyIOtKvTree, FBItems, ReqItemsIdx, SigSize, VSize) ->
    get_full_diff_(MyEntries, MyIOtKvTree, FBItems, ReqItemsIdx, SigSize,
                  util:pow(2, VSize)).

%% @doc Helper for get_full_diff/6.
-spec get_full_diff_(MyEntries::db_chunk_kv(), MyIOtherKvTree::kvi_tree(),
                     AccFBItems::[?RT:key()], AccReqItems::[non_neg_integer()],
                     SigSize::signature_size(), VMod::pos_integer())
        -> {FBItems::[?RT:key()], ReqItemsIdx::[non_neg_integer()],
            MyIOtherKvTree::kvi_tree()}.
get_full_diff_([], MyIOtKvTree, FBItems, ReqItemsIdx, _SigSize, _VMod) ->
    {FBItems, ReqItemsIdx, MyIOtKvTree};
get_full_diff_([{Key, Version} | Rest], MyIOtKvTree, FBItems, ReqItemsIdx, SigSize, VMod) ->
    {KeyShort, VersionShort} = compress_kv_pair(Key, Version, SigSize, VMod),
    case mymaps:find(KeyShort, MyIOtKvTree) of
        error ->
            get_full_diff_(Rest, MyIOtKvTree, [Key | FBItems],
                           ReqItemsIdx, SigSize, VMod);
        {ok, {OtherVersionShort, Idx}} ->
            MyIOtKvTree2 = mymaps:remove(KeyShort, MyIOtKvTree),
            if VersionShort > OtherVersionShort ->
                   get_full_diff_(Rest, MyIOtKvTree2, [Key | FBItems],
                                  ReqItemsIdx, SigSize, VMod);
               VersionShort =:= OtherVersionShort ->
                   get_full_diff_(Rest, MyIOtKvTree2, FBItems,
                                  ReqItemsIdx, SigSize, VMod);
               true -> % VersionShort < OtherVersionShort
                   get_full_diff_(Rest, MyIOtKvTree2, FBItems,
                                  [Idx | ReqItemsIdx], SigSize, VMod)
            end
    end.

%% @doc Gets all entries from MyEntries which are in MyIOtherKvTree
%%      and the entry in MyEntries has a newer version than the one in the tree
%%      and returns them as FBItems. ReqItems contains items in the tree but
%%      where the version in MyEntries is older than the one in the tree.
-spec get_part_diff(MyEntries::db_chunk_kv(), MyIOtherKvTree::kvi_tree(),
                    AccFBItems::[?RT:key()], AccReqItems::[non_neg_integer()],
                    SigSize::signature_size(), VSize::signature_size())
        -> {FBItems::[?RT:key()], ReqItemsIdx::[non_neg_integer()],
            MyIOtherKvTree::kvi_tree()}.
get_part_diff(MyEntries, MyIOtKvTree, FBItems, ReqItemsIdx, SigSize, VSize) ->
    get_part_diff_(MyEntries, MyIOtKvTree, FBItems, ReqItemsIdx, SigSize,
                   util:pow(2, VSize)).

%% @doc Helper for get_part_diff/6.
-spec get_part_diff_(MyEntries::db_chunk_kv(), MyIOtherKvTree::kvi_tree(),
                     AccFBItems::[?RT:key()], AccReqItems::[non_neg_integer()],
                     SigSize::signature_size(), VMod::pos_integer())
        -> {FBItems::[?RT:key()], ReqItemsIdx::[non_neg_integer()],
            MyIOtherKvTree::kvi_tree()}.
get_part_diff_([], MyIOtKvTree, FBItems, ReqItemsIdx, _SigSize, _VMod) ->
    {FBItems, ReqItemsIdx, MyIOtKvTree};
get_part_diff_([{Key, Version} | Rest], MyIOtKvTree, FBItems, ReqItemsIdx, SigSize, VMod) ->
    {KeyShort, VersionShort} = compress_kv_pair(Key, Version, SigSize, VMod),
    case mymaps:find(KeyShort, MyIOtKvTree) of
        error ->
            get_part_diff_(Rest, MyIOtKvTree, FBItems, ReqItemsIdx,
                           SigSize, VMod);
        {ok, {OtherVersionShort, Idx}} ->
            MyIOtKvTree2 = mymaps:remove(KeyShort, MyIOtKvTree),
            if VersionShort > OtherVersionShort ->
                   get_part_diff_(Rest, MyIOtKvTree2, [Key | FBItems], ReqItemsIdx,
                                  SigSize, VMod);
               VersionShort =:= OtherVersionShort ->
                   get_part_diff_(Rest, MyIOtKvTree2, FBItems, ReqItemsIdx,
                                  SigSize, VMod);
               true ->
                   get_part_diff_(Rest, MyIOtKvTree2, FBItems, [Idx | ReqItemsIdx],
                                  SigSize, VMod)
            end
    end.

%% @doc Transforms a single key and version into compact representations
%%      based on the given size and VMod, respectively.
%% @see compress_kv_list/6.
-spec compress_kv_pair(Key::?RT:key(), Version::client_version(),
                        SigSize::signature_size(), VMod::pos_integer())
        -> {KeyShort::non_neg_integer(), VersionShort::integer()}.
compress_kv_pair(Key, Version, SigSize, VMod) ->
    {compress_key(Key, SigSize), Version rem VMod}.

%% @doc Transforms a key or a KV-tuple into a compact binary representation
%%      based on the given size.
%% @see compress_kv_list/6.
-spec compress_key(Key::?RT:key() | {Key::?RT:key(), Version::client_version()},
                   SigSize::signature_size()) -> KeyShort::non_neg_integer().
compress_key(Key, SigSize) ->
    KBin = erlang:md5(erlang:term_to_binary(Key)),
    RestSize = erlang:bit_size(KBin) - SigSize,
    % return an integer based on the last SigSize bits:
    if RestSize >= 0  ->
           <<_:RestSize/bitstring, KeyShort:SigSize/integer-unit:1>> = KBin,
           KeyShort;
       true ->
           FillSize = -RestSize,
           <<KeyShort:SigSize/integer-unit:1>> = <<0:FillSize, KBin/binary>>,
           KeyShort
    end.

%% @doc Transforms a key from a KV-tuple into a compact binary representation
%%      based on the given size.
%% @see compress_kv_list/6.
-spec trivial_compress_key({Key::?RT:key(), Version::client_version()},
                   SigSize::signature_size()) -> KeyShort::non_neg_integer().
trivial_compress_key(KV, SigSize) ->
    compress_key(element(1, KV), SigSize).

%% @doc Creates a compressed version of a (key-)position list.
%%      MaxPosBound represents an upper bound on the biggest value in the list;
%%      when decoding, the same bound must be known!
-spec compress_idx_list(SortedIdxList::[non_neg_integer()],
                        MaxPosBound::non_neg_integer(), ResultIdx::[non_neg_integer()],
                        LastPos::non_neg_integer(), Max::non_neg_integer())
        -> CompressedIndices::bitstring().
compress_idx_list([Pos | Rest], MaxPosBound, AccResult, LastPos, Max) ->
    CurIdx0 = Pos - LastPos,
    % need a positive value to encode:
    CurIdx = if CurIdx0 >= 0 -> CurIdx0;
                true -> Mod = MaxPosBound + 1,
                        ((CurIdx0 rem Mod) + Mod) rem Mod
             end,
    compress_idx_list(Rest, MaxPosBound, [CurIdx | AccResult], Pos + 1,
                      erlang:max(CurIdx, Max));
compress_idx_list([], MaxPosBound, AccResult, _LastPos, Max) ->
    IdxSize = if Max =:= 0 -> 1;
                 true      -> bits_for_number(Max)
              end,
    Bin = lists:foldr(fun(Pos, Acc) ->
                              <<Acc/bitstring, Pos:IdxSize/integer-unit:1>>
                      end, <<>>, AccResult),
    case Bin of
        <<>> ->
            <<>>;
        _ ->
            IdxBitsSize = bits_for_number(bits_for_number(MaxPosBound)),
            <<IdxSize:IdxBitsSize/integer-unit:1, Bin/bitstring>>
    end.

%% @doc De-compresses a bitstring with indices from compress_idx_list/5
%%      into a list of indices encoded by that function.
-spec decompress_idx_list(CompressedBin::bitstring(),
                          MaxPosBound::non_neg_integer())
        -> {[non_neg_integer()], Count::non_neg_integer()}.
decompress_idx_list(<<>>, _MaxPosBound) ->
    {[], 0};
decompress_idx_list(Bin, MaxPosBound) ->
    IdxBitsSize = bits_for_number(bits_for_number(MaxPosBound)),
    <<SigSize0:IdxBitsSize/integer-unit:1, Bin2/bitstring>> = Bin,
    SigSize = erlang:max(1, SigSize0),
    Count = calc_items_in_chunk(Bin2, SigSize),
    IdxList = decompress_idx_list_(Bin2, 0, SigSize, MaxPosBound + 1),
    ?DBG_ASSERT(Count =:= length(IdxList)),
    {IdxList, Count}.

%% @doc Helper for decompress_idx_list/3.
-spec decompress_idx_list_(CompressedBin::bitstring(), LastPos::non_neg_integer(),
                           SigSize::signature_size(), Mod::pos_integer())
        -> ResKeys::[non_neg_integer()].
decompress_idx_list_(<<>>, _LastPos, _SigSize, _Mod) ->
    [];
decompress_idx_list_(Bin, LastPos, SigSize, Mod) ->
    <<Diff:SigSize/integer-unit:1, T/bitstring>> = Bin,
    CurPos = (LastPos + Diff) rem Mod,
    [CurPos | decompress_idx_list_(T, CurPos + 1, SigSize, Mod)].

%% @doc De-compresses a bitstring with indices from compress_idx_list/5
%%      into the encoded sub-list of the original list.
%%      NOTE: in contrast to decompress_idx_list/2 (which is used for
%%            compressing KV lists as well), we do not support duplicates
%%            in the original list fed into compress_idx_list/5 and will fail
%%            during the decode!
-spec decompress_idx_to_list(CompressedBin::bitstring(), [X]) -> [X].
decompress_idx_to_list(<<>>, _List) ->
    [];
decompress_idx_to_list(Bin, List) ->
    IdxBitsSize = bits_for_number(bits_for_number(length(List) - 1)),
    <<SigSize0:IdxBitsSize/integer-unit:1, Bin2/bitstring>> = Bin,
    SigSize = erlang:max(1, SigSize0),
    decompress_idx_to_list_(Bin2, List, SigSize).

%% @doc Helper for decompress_idx_to_list/2.
-spec decompress_idx_to_list_(CompressedBin::bitstring(), [X],
                              SigSize::signature_size()) -> [X].
decompress_idx_to_list_(<<>>, _, _SigSize) ->
    [];
decompress_idx_to_list_(Bin, List, SigSize) ->
    <<KeyPosInc:SigSize/integer-unit:1, T/bitstring>> = Bin,
    % note: this fails if there have been duplicates in the original list or
    %       KeyPosInc was negative!
    [X | List2] = lists:nthtail(KeyPosInc, List),
    [X | decompress_idx_to_list_(T, List2, SigSize)].

%% @doc Converts a list of positions to a bitstring where the x'th bit is set
%%      if the x'th position is in the list. The final bitstring may be
%%      created with erlang:list_to_bitstring(lists:reverse(Result)).
%%      A total of FinalSize bits will be used.
%%      PreCond: sorted list Pos, 0 &lt;= every pos &lt; FinalSize
-spec pos_to_bitstring(Pos::[non_neg_integer()], AccBin::[bitstring()],
                       BitsSet::non_neg_integer(), FinalSize::non_neg_integer())
        -> Result::[bitstring()].
pos_to_bitstring([Pos | Rest], AccBin, BitsSet, FinalSize) ->
    New = <<0:(Pos - BitsSet), 1:1>>,
    pos_to_bitstring(Rest, [New | AccBin], Pos + 1, FinalSize);
pos_to_bitstring([], AccBin, BitsSet, FinalSize) ->
    [<<0:(FinalSize - BitsSet)>> | AccBin].

%% @doc Converts the bitstring from pos_to_bitstring/4 into keys at the
%%      appropriate positions in KList. Result is reversly sorted.
%%      NOTE: This is essentially the same as bitstring_to_k_list_kv/3 but we
%%            need the separation because of the opaque RT keys.
-spec bitstring_to_k_list_k(PosBitString::bitstring(), KList::[?RT:key()],
                            Acc::[?RT:key()]) -> Result::[?RT:key()].
bitstring_to_k_list_k(<<1:1, RestBits/bitstring>>, [Key | RestK], Acc) ->
    bitstring_to_k_list_k(RestBits, RestK, [Key | Acc]);
bitstring_to_k_list_k(<<0:1, RestBits/bitstring>>, [_Key | RestK], Acc) ->
    bitstring_to_k_list_k(RestBits, RestK, Acc);
bitstring_to_k_list_k(<<>>, _KList, Acc) ->
    Acc; % last 0 bits may  be truncated, e.g. by setting FinalSize in pos_to_bitstring/4 accordingly
bitstring_to_k_list_k(RestBits, [], Acc) ->
    % there may be rest bits, but all should be 0:
    BitCount = erlang:bit_size(RestBits),
    ?ASSERT(<<0:BitCount>> =:= RestBits),
    Acc.

%% @doc Converts the bitstring from pos_to_bitstring/4 into keys at the
%%      appropriate positions in KVList. Result is reversly sorted.
-spec bitstring_to_k_list_kv(PosBitString::bitstring(), KVList::db_chunk_kv(),
                             Acc::[?RT:key()]) -> Result::[?RT:key()].
bitstring_to_k_list_kv(<<1:1, RestBits/bitstring>>, [{Key, _Version} | RestKV], Acc) ->
    bitstring_to_k_list_kv(RestBits, RestKV, [Key | Acc]);
bitstring_to_k_list_kv(<<0:1, RestBits/bitstring>>, [{_Key, _Version} | RestKV], Acc) ->
    bitstring_to_k_list_kv(RestBits, RestKV, Acc);
bitstring_to_k_list_kv(<<>>, _KVList, Acc) ->
    Acc; % last 0 bits may  be truncated, e.g. by setting FinalSize in pos_to_bitstring/4 accordingly
bitstring_to_k_list_kv(RestBits, [], Acc) ->
    % there may be rest bits, but all should be 0:
    BitCount = erlang:bit_size(RestBits),
    ?ASSERT(<<0:BitCount>> =:= RestBits),
    Acc.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% SHash specific
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Gets all entries from MyEntries which are not encoded in MyIOtKvSet.
%%      Also returns the tree with all these matches removed.
-spec shash_get_full_diff(MyEntries::KV, MyIOtherKvTree::kvi_tree(),
                          AccDiff::KV, SigSize::signature_size())
        -> {Diff::KV, MyIOtherKvTree::kvi_tree()}
    when is_subtype(KV, db_chunk_kv()).
shash_get_full_diff([], MyIOtKvSet, AccDiff, _SigSize) ->
    {AccDiff, MyIOtKvSet};
shash_get_full_diff([KV | Rest], MyIOtKvSet, AccDiff, SigSize) ->
    CurKey = compress_key(KV, SigSize),
    OldSize = mymaps:size(MyIOtKvSet),
    MyIOtKvSet2 = mymaps:remove(CurKey, MyIOtKvSet),
    case mymaps:size(MyIOtKvSet2) of
        OldSize ->
            shash_get_full_diff(Rest, MyIOtKvSet2, [KV | AccDiff], SigSize);
        _ ->
            shash_get_full_diff(Rest, MyIOtKvSet2, AccDiff, SigSize)
    end.

%% @doc Part of the resolve_req message processing of the SHash and Bloom RC
%%      processes in phase 2 (trivial RC) at the non-initiator.
-spec shash_bloom_perform_resolve(
        State::state(), DBChunkTree::kvi_tree(),
        SigSize::signature_size(), VSize::signature_size(),
        DestReconPid::comm:mypid(), FBItems::[?RT:key()])
        -> rr_recon_stats:stats().
shash_bloom_perform_resolve(
  #rr_recon_state{dest_rr_pid = DestRRPid,   ownerPid = OwnerL,
                  kv_list = KVList,          stats = Stats,
                  method = _RMethod},
  DBChunkTree, SigSize, VSize, DestReconPid, FBItems) ->
    {ToSendKeys1, ToReqIdx1, DBChunkTree1} =
        get_part_diff(KVList, DBChunkTree, FBItems, [], SigSize, VSize),

    NewStats1 = send_resolve_request(Stats, ToSendKeys1, OwnerL, DestRRPid,
                                     false, false),

    % let the initiator's rr_recon process identify the remaining keys
    ReqIdx = lists:usort([Idx || {_Version, Idx} <- mymaps:values(DBChunkTree1)] ++ ToReqIdx1),
    ToReq2 = erlang:list_to_bitstring(
               lists:reverse(
                 pos_to_bitstring(% note: ReqIdx positions start with 0
                   ReqIdx, [], 0, ?IIF(ReqIdx =:= [], 0, lists:last(ReqIdx) + 1)))),
    ?TRACE("resolve_req ~s Session=~p ; ToReq= ~p bytes",
           [_RMethod, rr_recon_stats:get(session_id, NewStats1), erlang:byte_size(ToReq2)]),
    comm:send(DestReconPid, {resolve_req, ToReq2}),
    % the initiator will use key_upd_send and we must thus increase
    % the number of resolve processes here!
    if ReqIdx =/= [] ->
           rr_recon_stats:inc([{rs_expected, 1}], NewStats1);
       true -> NewStats1
    end.

%% @doc Sets up a phase2 trivial synchronisation on the identified differences
%%      where the mapping of the differences is not clear yet and only the
%%      current node knows them.
-spec phase2_run_trivial_on_diff(
  UnidentifiedDiff::db_chunk_kv(), OtherDiffIdx::bitstring() | none,
  OtherDiffIdxSize::non_neg_integer(), OtherItemCount::non_neg_integer(),
  P1E_p2::float(), OtherCmpItemCount::non_neg_integer(), State::state())
        -> NewState::state().
phase2_run_trivial_on_diff(
  UnidentifiedDiff, OtherDiffIdx, OtherDiffIdxSize, OtherItemCount, P1E_p2,
  OtherCmpItemCount, % number of items the other nodes compares CKV entries with
  State = #rr_recon_state{stats = Stats, dest_recon_pid = DestReconPid,
                          dest_rr_pid = DestRRPid, ownerPid = OwnerL}) ->
    CKVSize = length(UnidentifiedDiff),
    StartResolve = CKVSize + OtherDiffIdxSize > 0,
    ?TRACE("Reconcile SHash/Bloom/ART Session=~p ; Diff=~B+~B",
           [rr_recon_stats:get(session_id, Stats), CKVSize, OtherDiffIdxSize]),
    if StartResolve andalso OtherItemCount > 0 ->
           % send idx of non-matching other items & KV-List of my diff items
           % start resolve similar to a trivial recon but using the full diff!
           % (as if non-initiator in trivial recon)
           ExpDelta = 100, % TODO: can we reduce this here?
           {BuildTime, {MyDiffK, MyDiffV, ResortedKVOrigList, SigSizeT, VSizeT}} =
               util:tc(fun() ->
                               compress_kv_list_p1e(
                                 UnidentifiedDiff, CKVSize, OtherCmpItemCount, ExpDelta, P1E_p2,
                                 fun trivial_signature_sizes/4, fun trivial_compress_key/2)
                       end),
           ?DBG_ASSERT(?implies(OtherDiffIdx =:= none, MyDiffK =/= <<>>)), % if no items to request
           ?DBG_ASSERT((MyDiffK =:= <<>>) =:= (MyDiffV =:= <<>>)),
           MyDiff = {MyDiffK, MyDiffV},
           P1E_p2_real = trivial_worst_case_failprob(
                           SigSizeT, CKVSize, OtherCmpItemCount, ExpDelta),

           case OtherDiffIdx of
               none -> send(DestReconPid,
                            {resolve_req, MyDiff, SigSizeT, VSizeT, comm:this()});
               _    -> send(DestReconPid,
                            {resolve_req, MyDiff, OtherDiffIdx, SigSizeT, VSizeT, comm:this()})
           end,
           % the non-initiator will use key_upd_send and we must thus increase
           % the number of resolve processes here!
           NewStats1 = rr_recon_stats:inc([{rs_expected, 1},
                                           {build_time, BuildTime}], Stats),
           NewStats  = rr_recon_stats:set([{p1e_phase2, P1E_p2_real}], NewStats1),
           KList = [element(1, KV) || KV <- ResortedKVOrigList],
           State#rr_recon_state{stats = NewStats, stage = resolve,
                                kv_list = [], k_list = KList,
                                misc = [{my_bin_diff_empty, MyDiffK =:= <<>>}]};
       StartResolve -> % andalso OtherItemCount =:= 0 ->
           ?DBG_ASSERT(OtherItemCount =:= 0),
           % no need to send resolve_req message - the non-initiator already shut down
           % the other node does not have any items but there is a diff at our node!
           % start a resolve here:
           KList = [element(1, KV) || KV <- UnidentifiedDiff],
           NewStats = send_resolve_request(
                        Stats, KList, OwnerL, DestRRPid, true, false),
           NewState = State#rr_recon_state{stats = NewStats, stage = resolve},
           shutdown(sync_finished, NewState);
       OtherItemCount =:= 0 ->
           shutdown(sync_finished, State);
       true -> % OtherItemCount > 0, CKVSize =:= 0
           % must send resolve_req message for the non-initiator to shut down
           send(DestReconPid, {resolve_req, shutdown}),
           shutdown(sync_finished, State)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Merkle Tree specific
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Calculates from a total P1E the (next) P1E to use for signature and
%%      sub-tree reconciliations.
-spec merkle_next_p1e(BranchFactor::pos_integer(), P1ETotal::float())
    -> {P1E_I::float(), P1E_L::float()}.
merkle_next_p1e(BranchFactor, P1ETotal) ->
    % mistakes caused by:
    % inner node: current node or any of its BranchFactor children (B=BranchFactor+1)
    % leaf node: current node only (B=1) and thus P1ETotal
    % => current node's probability of 0 errors = P0E(child)^B
    P1E_I = calc_n_subparts_p1e(BranchFactor + 1, P1ETotal),
    P1E_L = P1ETotal,
%%     log:pal("merkle [ ~p ]~n - P1ETotal: ~p, \tP1E_I: ~p, \tP1E_L: ~p",
%%             [self(), P1ETotal, P1E_I, P1E_L]),
    {P1E_I, P1E_L}.

%% @doc Calculates the new signature sizes based on the next P1E as in
%%      merkle_next_p1e/2
-spec merkle_next_signature_sizes(
        Params::#merkle_params{}, P1ETotal::float(),
        MyMaxItemsCount::non_neg_integer(), OtherMaxItemsCount::non_neg_integer())
    -> {P1E_I::float(), P1E_L::float(),
        NextSigSizeI::signature_size(), NextSigSizeL::signature_size(),
        EffectiveP1E_I::float(), EffectiveP1E_L::float()}.
merkle_next_signature_sizes(
  #merkle_params{bucket_size = BucketSize, branch_factor = BranchFactor}, P1ETotal,
  MyMaxItemsCount, OtherMaxItemsCount) ->
    {P1E_I, P1E_L} = merkle_next_p1e(BranchFactor, P1ETotal),

    % note: we need to use the same P1E for this level's signature
    %       comparison as a children's tree has in total!
    if MyMaxItemsCount =/= 0 andalso OtherMaxItemsCount =/= 0 ->
           AffectedItemsI = MyMaxItemsCount + OtherMaxItemsCount,
           NextSigSizeI = min_max(util:ceil(util:log2(AffectedItemsI / P1E_I)),
                                  get_min_hash_bits(), 160),
           EffectiveP1E_I = float(AffectedItemsI / util:pow(2, NextSigSizeI));
       true ->
           NextSigSizeI = 0,
           EffectiveP1E_I = 0.0
    end,
    ?DBG_ASSERT2(EffectiveP1E_I >= 0 andalso EffectiveP1E_I < 1, EffectiveP1E_I),

    AffectedItemsL = 2 * BucketSize,
    NextSigSizeL = min_max(util:ceil(util:log2(AffectedItemsL / P1E_L)),
                           get_min_hash_bits(), 160),
    EffectiveP1E_L = float(AffectedItemsL / util:pow(2, NextSigSizeL)),
    ?DBG_ASSERT2(EffectiveP1E_L > 0 andalso EffectiveP1E_L < 1, EffectiveP1E_L),

    ?MERKLE_DEBUG("merkle - signatures~nMyMI: ~B,\tOtMI: ~B"
                  "\tP1E_I: ~g,\tP1E_L: ~g,\tSigSizeI: ~B,\tSigSizeL: ~B~n"
                  "  -> eff. P1E_I: ~g,\teff. P1E_L: ~g",
                  [MyMaxItemsCount, OtherMaxItemsCount,
                   P1E_I, P1E_L, NextSigSizeI, NextSigSizeL,
                   EffectiveP1E_I, EffectiveP1E_L]),
    {P1E_I, P1E_L, NextSigSizeI, NextSigSizeL, EffectiveP1E_I, EffectiveP1E_L}.

-compile({nowarn_unused_function, {min_max_feeder, 3}}).
-spec min_max_feeder(X::number(), Min::number(), Max::number())
        -> {X::number(), Min::number(), Max::number()}.
min_max_feeder(X, Min, Max) when Min > Max -> {X, Max, Min};
min_max_feeder(X, Min, Max) -> {X, Min, Max}.

%% @doc Sets min and max boundaries for X and returns either Min, Max or X.
-spec min_max(X::number(), Min::number(), Max::number()) -> number().
min_max(X, _Min, Max) when X >= Max ->
    ?DBG_ASSERT(_Min =< Max orelse _Min =:= get_min_hash_bits()),
    Max;
min_max(X, Min, _Max) when X =< Min ->
    ?DBG_ASSERT(Min =< _Max orelse Min =:= get_min_hash_bits()),
    Min;
min_max(X, _Min, _Max) ->
    % dbg_assert must be true:
    %?DBG_ASSERT(_Min =< _Max orelse _Min =:= get_min_hash_bits()),
    X.

%% @doc Transforms a list of merkle keys, i.e. hashes, into a compact binary
%%      representation for transfer.
-spec merkle_compress_hashlist(Nodes::[merkle_tree:mt_node()], Bin,
                               SigSizeI::signature_size(),
                               SigSizeL::signature_size()) -> Bin
    when is_subtype(Bin, bitstring()).
merkle_compress_hashlist([], Bin, _SigSizeI, _SigSizeL) ->
    Bin;
merkle_compress_hashlist([N1 | TL], Bin, SigSizeI, SigSizeL) ->
    H1 = merkle_tree:get_hash(N1),
    case merkle_tree:is_leaf(N1) of
        true ->
            Bin2 = case merkle_tree:is_empty(N1) of
                       true  -> <<Bin/bitstring, 1:1, 0:1>>;
                       false -> <<Bin/bitstring, 1:1, 1:1, H1:SigSizeL>>
                   end,
            merkle_compress_hashlist(TL, Bin2, SigSizeI, SigSizeL);
        false ->
            merkle_compress_hashlist(TL, <<Bin/bitstring, 0:1, H1:SigSizeI>>,
                                     SigSizeI, SigSizeL)
    end.

%% @doc Transforms the compact binary representation of merkle hash lists from
%%      merkle_compress_hashlist/2 back into the original form.
-spec merkle_decompress_hashlist(bitstring(), SigSizeI::signature_size(),
                                 SigSizeL::signature_size())
        -> Hashes::[merkle_cmp_request()].
merkle_decompress_hashlist(<<>>, _SigSizeI, _SigSizeL) ->
    [];
merkle_decompress_hashlist(Bin, SigSizeI, SigSizeL) ->
    IsLeaf = case Bin of
                 <<1:1, 1:1, Hash:SigSizeL/integer-unit:1, Bin2/bitstring>> ->
                     true;
                 <<1:1, 0:1, Bin2/bitstring>> ->
                     Hash = none,
                     true;
                 <<0:1, Hash:SigSizeI/integer-unit:1, Bin2/bitstring>> ->
                     false
             end,
    [{Hash, IsLeaf} | merkle_decompress_hashlist(Bin2, SigSizeI, SigSizeL)].

%% @doc Compares the given Hashes from the other node with my merkle_tree nodes
%%      (executed on non-initiator).
%%      Returns the comparison results and the rest nodes to check in a next
%%      step.
-spec merkle_check_node(
        Hashes::[merkle_cmp_request()], MyNodes::NodeList,
        SigSizeI::signature_size(), SigSizeL::signature_size(),
        MyMaxItemsCount::non_neg_integer(), OtherMaxItemsCount::non_neg_integer(),
        #merkle_params{}, Stats, FlagsAcc::bitstring(), RestTreeAcc::NodeList,
        SyncAccSend::[merkle_sync_send()], SyncAccRcv::[merkle_sync_rcv()],
        SyncAccRcvLeafCount::Count,
        MySyncAccDRK::[?RT:key()], MySyncAccDRLCount::Count, OtherSyncAccDRLCount::Count,
        SyncIn::merkle_sync(), AccCmp::Count, AccSkip::Count,
        NextLvlNodesActIN::Count, HashCmpI_IN::Count, HashCmpL_IN::Count)
        -> {FlagsOUT::bitstring(), RestTreeOut::NodeList,
            SyncOUT::merkle_sync(), Stats, MaxItemsCount::Count,
            NextLvlNodesActOUT::Count, HashCmpI_OUT::Count, HashCmpL_OUT::Count}
    when
      is_subtype(NodeList, [merkle_tree:mt_node()]),
      is_subtype(Stats,    rr_recon_stats:stats()),
      is_subtype(Count,    non_neg_integer()).
merkle_check_node([], [], _SigSizeI, _SigSizeL,
                  _MyMaxItemsCount, _OtherMaxItemsCount, _Params, Stats, FlagsAcc, RestTreeAcc,
                  SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                  {SyncInSend, SyncInRcv, SyncInRcvLeafCount,
                   {MySyncInDRK, MySyncInDRLCount, OtherSyncInDRLCount}},
                  AccCmp, AccSkip, NextLvlNodesActIN,
                  HashCmpI_IN, HashCmpL_IN) ->
    NStats = rr_recon_stats:inc([{tree_nodesCompared, AccCmp},
                                 {tree_compareSkipped, AccSkip}], Stats),
    % note: we can safely include all leaf nodes here although only inner nodes
    %       should go into MIC - every inner node always has more items than
    %       any leaf node (otherwise it would have been a leaf node)
    AccMIC = lists:max([0 | [merkle_tree:get_item_count(Node) || Node <- RestTreeAcc]]),
    {FlagsAcc, lists:reverse(RestTreeAcc),
     {lists:reverse(SyncAccSend, SyncInSend),
      lists:reverse(SyncAccRcv, SyncInRcv),
      SyncInRcvLeafCount + SyncAccRcvLeafCount,
      {MySyncAccDRK ++ MySyncInDRK, MySyncInDRLCount + MySyncAccDRLCount,
       OtherSyncInDRLCount + OtherSyncAccDRLCount}},
     NStats, AccMIC, NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN};
merkle_check_node([{Hash, IsLeafHash} | TK], [Node | TN], SigSizeI, SigSizeL,
                  MyMaxItemsCount, OtherMaxItemsCount, Params, Stats, FlagsAcc, RestTreeAcc,
                  SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                  SyncIN, AccCmp, AccSkip, NextLvlNodesActIN,
                  HashCmpI_IN, HashCmpL_IN) ->
    IsLeafNode = merkle_tree:is_leaf(Node),
    EmptyNode = merkle_tree:is_empty(Node),
    EmptyLeafNode = IsLeafNode andalso EmptyNode,
    NonEmptyLeafNode = IsLeafNode andalso (not EmptyNode),
    NodeHash =
        if EmptyLeafNode ->
               none; % to match with the hash from merkle_decompress_hashlist/3
           IsLeafNode ->
               <<X:SigSizeL/integer-unit:1>> = <<(merkle_tree:get_hash(Node)):SigSizeL>>,
               X;
           true ->
               <<X:SigSizeI/integer-unit:1>> = <<(merkle_tree:get_hash(Node)):SigSizeI>>,
               X
        end,
    EmptyLeafHash = IsLeafHash andalso Hash =:= none,
    NonEmptyLeafHash = IsLeafHash andalso Hash =/= none,
    if Hash =:= NodeHash andalso IsLeafHash =:= IsLeafNode ->
           Skipped = merkle_tree:size(Node) - 1,
           if EmptyLeafHash -> % empty leaf hash on both nodes - this was exact!
                  HashCmpI_OUT = HashCmpI_IN,
                  HashCmpL_OUT = HashCmpL_IN;
              IsLeafHash -> % both non-empty leaf nodes
                  HashCmpI_OUT = HashCmpI_IN,
                  HashCmpL_OUT = HashCmpL_IN + 1;
              true -> % both inner nodes
                  HashCmpI_OUT = HashCmpI_IN + 1,
                  HashCmpL_OUT = HashCmpL_IN
           end,
           merkle_check_node(TK, TN, SigSizeI, SigSizeL,
                             MyMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                             <<FlagsAcc/bitstring, ?recon_ok:2>>, RestTreeAcc,
                             SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                             MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                             SyncIN, AccCmp + 1, AccSkip + Skipped,
                             NextLvlNodesActIN, HashCmpI_OUT, HashCmpL_OUT);
       (not IsLeafNode) andalso (not IsLeafHash) ->
           % both inner nodes
           Childs = merkle_tree:get_childs(Node),
           NextLvlNodesActOUT = NextLvlNodesActIN + Params#merkle_params.branch_factor,
           HashCmpI_OUT = HashCmpI_IN + 1,
           merkle_check_node(TK, TN, SigSizeI, SigSizeL,
                             MyMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                             <<FlagsAcc/bitstring, ?recon_fail_cont_inner:2>>, lists:reverse(Childs, RestTreeAcc),
                             SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                             MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                             SyncIN, AccCmp + 1, AccSkip,
                             NextLvlNodesActOUT, HashCmpI_OUT, HashCmpL_IN);
       (not IsLeafNode) andalso NonEmptyLeafHash ->
           % inner node here, non-empty leaf there
           % no need to compare hashes - this is an exact process based on the tags
           {MyKVItems, LeafCount} = merkle_tree:get_items([Node]),
           Sync = {MyMaxItemsCount, MyKVItems},
           merkle_check_node(TK, TN, SigSizeI, SigSizeL,
                             MyMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                             <<FlagsAcc/bitstring, ?recon_fail_stop_inner:2>>, RestTreeAcc,
                             SyncAccSend, [Sync | SyncAccRcv], SyncAccRcvLeafCount + LeafCount,
                             MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                             SyncIN, AccCmp + 1, AccSkip,
                             NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN);
       NonEmptyLeafNode andalso (NonEmptyLeafHash orelse not IsLeafHash) ->
           % non-empty leaf here, non-empty leaf or inner node there
           if NonEmptyLeafHash -> % both non-empty leaf nodes
                  OtherMaxItemsCount1 =
                      erlang:min(Params#merkle_params.bucket_size,
                                 OtherMaxItemsCount),
                  HashCmpL_OUT = HashCmpL_IN + 1;
              true -> % inner node there
                  OtherMaxItemsCount1 = OtherMaxItemsCount,
                  HashCmpL_OUT = HashCmpL_IN
           end,
           SyncAccSend1 =
               [{OtherMaxItemsCount1, merkle_tree:get_bucket(Node)} | SyncAccSend],
           merkle_check_node(TK, TN, SigSizeI, SigSizeL,
                             MyMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                             <<FlagsAcc/bitstring, ?recon_fail_stop_leaf:2>>, RestTreeAcc,
                             SyncAccSend1, SyncAccRcv, SyncAccRcvLeafCount,
                             MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                             SyncIN, AccCmp + 1, AccSkip,
                             NextLvlNodesActIN, HashCmpI_IN, HashCmpL_OUT);
       (NonEmptyLeafNode orelse not IsLeafNode) andalso EmptyLeafHash ->
           % non-empty leaf or inner node here, empty leaf there
           % no need to compare hashes - this is an exact process based on the tags
           % -> resolve directly here, i.e. without a trivial sub process
           ResultCode = if not IsLeafNode -> ?recon_fail_stop_inner; % stop_empty_leaf1
                           NonEmptyLeafNode -> ?recon_fail_stop_leaf % stop_empty_leaf2
                        end,
           {MyKVItems, LeafCount} = merkle_tree:get_items([Node]),
           MySyncAccDRK1 = [element(1, X) || X <- MyKVItems] ++ MySyncAccDRK,
           merkle_check_node(TK, TN, SigSizeI, SigSizeL,
                             MyMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                             <<FlagsAcc/bitstring, ResultCode:2>>, RestTreeAcc,
                             SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                             MySyncAccDRK1, MySyncAccDRLCount + LeafCount,
                             OtherSyncAccDRLCount,
                             SyncIN, AccCmp + 1, AccSkip,
                             NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN);
       EmptyLeafNode andalso (NonEmptyLeafHash orelse not IsLeafHash) ->
           % empty leaf here, non-empty leaf or inner node there
           % no need to compare hashes - this is an exact process based on the tags
           % -> resolved directly at the other node, i.e. without a trivial sub process
           ResultCode = if not IsLeafHash -> ?recon_fail_stop_inner; % stop_empty_leaf3
                           NonEmptyLeafHash -> ?recon_fail_cont_inner % stop_empty_leaf4
                        end,
           merkle_check_node(TK, TN, SigSizeI, SigSizeL,
                             MyMaxItemsCount, OtherMaxItemsCount, Params, Stats,
                             <<FlagsAcc/bitstring, ResultCode:2>>, RestTreeAcc,
                             SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                             MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount + 1,
                             SyncIN, AccCmp + 1, AccSkip,
                             NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN)
    end.

%% @doc Processes compare results from merkle_check_node/22 on the initiator.
-spec merkle_cmp_result(
        bitstring(), RestTree::NodeList,
        SigSizeI::signature_size(), SigSizeL::signature_size(),
        MyMaxItemsCount::non_neg_integer(), OtherMaxItemsCount::non_neg_integer(),
        SyncIn::merkle_sync(), #merkle_params{}, Stats, RestTreeAcc::NodeList,
        SyncAccSend::[merkle_sync_send()], SyncAccRcv::[merkle_sync_rcv()],
        SyncAccRcvLeafCount::Count,
        MySyncAccDRK::[?RT:key()], MySyncAccDRLCount::Count, OtherSyncAccDRLCount::Count,
        AccCmp::Count, AccSkip::Count,
        NextLvlNodesActIN::Count, HashCmpI_IN::Count, HashCmpL_IN::Count)
        -> {RestTreeOut::NodeList, MerkleSyncOut::merkle_sync(),
            NewStats::Stats, MaxItemsCount::Count,
            NextLvlNodesActOUT::Count, HashCmpI_OUT::Count, HashCmpL_OUT::Count}
    when
      is_subtype(NodeList, [merkle_tree:mt_node()]),
      is_subtype(Stats,    rr_recon_stats:stats()),
      is_subtype(Count,    non_neg_integer()).
merkle_cmp_result(<<>>, [], _SigSizeI, _SigSizeL,
                  _MyMaxItemsCount, _OtherMaxItemsCount,
                  {SyncInSend, SyncInRcv, SyncInRcvLeafCount,
                   {MySyncInDRK, MySyncInDRLCount, OtherSyncInDRLCount}},
                  _Params, Stats,
                  RestTreeAcc, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount, AccCmp, AccSkip,
                  NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN) ->
    NStats = rr_recon_stats:inc([{tree_nodesCompared, AccCmp},
                                 {tree_compareSkipped, AccSkip}], Stats),
    % note: we can safely include all leaf nodes here although only inner nodes
    %       should go into MIC - every inner node always has more items than
    %       any leaf node (otherwise it would have been a leaf node)
    AccMIC = lists:max([0 | [merkle_tree:get_item_count(Node) || Node <- RestTreeAcc]]),
    {lists:reverse(RestTreeAcc),
     {lists:reverse(SyncAccSend, SyncInSend),
      lists:reverse(SyncAccRcv, SyncInRcv),
      SyncInRcvLeafCount + SyncAccRcvLeafCount,
      {MySyncAccDRK ++ MySyncInDRK, MySyncInDRLCount + MySyncAccDRLCount,
       OtherSyncInDRLCount + OtherSyncAccDRLCount}},
     NStats, AccMIC, NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN};
merkle_cmp_result(<<?recon_ok:2, TR/bitstring>>, [Node | TN], SigSizeI, SigSizeL,
                  MyMaxItemsCount, OtherMaxItemsCount, MerkleSyncIn, Params, Stats,
                  RestTreeAcc, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                  AccCmp, AccSkip, NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN) ->
    case merkle_tree:is_leaf(Node) of
        true ->
            case merkle_tree:is_empty(Node) of
                true ->
                    % empty leaf hash on both nodes - this was exact!
                    HashCmpI_OUT = HashCmpI_IN,
                    HashCmpL_OUT = HashCmpL_IN;
                false ->
                    HashCmpI_OUT = HashCmpI_IN,
                    HashCmpL_OUT = HashCmpL_IN + 1
            end;
        false ->
            HashCmpI_OUT = HashCmpI_IN + 1,
            HashCmpL_OUT = HashCmpL_IN
    end,
    Skipped = merkle_tree:size(Node) - 1,
    merkle_cmp_result(TR, TN, SigSizeI, SigSizeL,
                      MyMaxItemsCount, OtherMaxItemsCount, MerkleSyncIn, Params, Stats,
                      RestTreeAcc, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                      MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                      AccCmp + 1, AccSkip + Skipped,
                      NextLvlNodesActIN, HashCmpI_OUT, HashCmpL_OUT);
merkle_cmp_result(<<?recon_fail_cont_inner:2, TR/bitstring>>, [Node | TN],
                  SigSizeI, SigSizeL,
                  MyMaxItemsCount, OtherMaxItemsCount, SyncIn, Params, Stats,
                  RestTreeAcc, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount,
                  AccCmp, AccSkip, NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN) ->
    % either cont_inner or stop_empty_leaf4
    case merkle_tree:is_leaf(Node) of
        false -> % cont_inner
            % inner hash on both nodes
            Childs = merkle_tree:get_childs(Node),
            NextLvlNodesActOUT = NextLvlNodesActIN + Params#merkle_params.branch_factor,
            HashCmpI_OUT = HashCmpI_IN + 1,
            RestTreeAcc1 = lists:reverse(Childs, RestTreeAcc),
            MySyncAccDRK1 = MySyncAccDRK,
            MySyncAccDRLCount1 = MySyncAccDRLCount;
        true -> % stop_empty_leaf4
            ?DBG_ASSERT(not merkle_tree:is_empty(Node)),
            % non-empty leaf on this node, empty leaf on the other node
            % -> resolve directly here, i.e. without a trivial sub process
            NextLvlNodesActOUT = NextLvlNodesActIN,
            HashCmpI_OUT = HashCmpI_IN,
            RestTreeAcc1 = RestTreeAcc,
            MyKVItems = merkle_tree:get_bucket(Node),
            MySyncAccDRK1 = [element(1, X) || X <- MyKVItems] ++ MySyncAccDRK,
            MySyncAccDRLCount1 = MySyncAccDRLCount + 1
    end,
    merkle_cmp_result(TR, TN, SigSizeI, SigSizeL,
                      MyMaxItemsCount, OtherMaxItemsCount, SyncIn, Params, Stats,
                      RestTreeAcc1, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                      MySyncAccDRK1, MySyncAccDRLCount1, OtherSyncAccDRLCount,
                      AccCmp + 1, AccSkip,
                      NextLvlNodesActOUT, HashCmpI_OUT, HashCmpL_IN);
merkle_cmp_result(<<?recon_fail_stop_inner:2, TR/bitstring>>, [Node | TN],
                  SigSizeI, SigSizeL,
                  MyMaxItemsCount, OtherMaxItemsCount, SyncIn, Params, Stats,
                  RestTreeAcc, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount, AccCmp, AccSkip,
                  NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN) ->
    % either stop_inner or stop_empty_leaf1 or stop_empty_leaf3
    % NOTE: all these mismatches are exact process based on the tags
    IsLeafNode = merkle_tree:is_leaf(Node),
    EmptyLeafNode = IsLeafNode andalso merkle_tree:is_empty(Node),
    
    if IsLeafNode andalso (not EmptyLeafNode) -> % stop_inner
           SyncAccSend1 =
               [{OtherMaxItemsCount, merkle_tree:get_bucket(Node)} | SyncAccSend],
           OtherSyncAccDRLCount1 = OtherSyncAccDRLCount,
           MySyncAccDRK1 = MySyncAccDRK,
           MySyncAccDRLCount1 = MySyncAccDRLCount;
       EmptyLeafNode -> % stop_empty_leaf1
           % -> resolved directly at the other node, i.e. without a trivial sub process
           SyncAccSend1 = SyncAccSend,
           OtherSyncAccDRLCount1 = OtherSyncAccDRLCount + 1, % this will deviate from the other node!
           MySyncAccDRK1 = MySyncAccDRK,
           MySyncAccDRLCount1 = MySyncAccDRLCount;
       not IsLeafNode -> % stop_empty_leaf3
           % -> resolve directly here, i.e. without a trivial sub process
           SyncAccSend1 = SyncAccSend,
           OtherSyncAccDRLCount1 = OtherSyncAccDRLCount,
           {MyKVItems, LeafCount} = merkle_tree:get_items([Node]),
           MySyncAccDRK1 = [element(1, X) || X <- MyKVItems] ++ MySyncAccDRK,
           MySyncAccDRLCount1 = MySyncAccDRLCount + LeafCount
    end,
    merkle_cmp_result(TR, TN, SigSizeI, SigSizeL,
                      MyMaxItemsCount, OtherMaxItemsCount, SyncIn, Params, Stats,
                      RestTreeAcc, SyncAccSend1, SyncAccRcv, SyncAccRcvLeafCount,
                      MySyncAccDRK1, MySyncAccDRLCount1, OtherSyncAccDRLCount1,
                      AccCmp + 1, AccSkip,
                      NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN);
merkle_cmp_result(<<?recon_fail_stop_leaf:2, TR/bitstring>>, [Node | TN],
                  SigSizeI, SigSizeL,
                  MyMaxItemsCount, OtherMaxItemsCount, SyncIn, Params, Stats,
                  RestTreeAcc, SyncAccSend, SyncAccRcv, SyncAccRcvLeafCount,
                  MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount, AccCmp, AccSkip,
                  NextLvlNodesActIN, HashCmpI_IN, HashCmpL_IN) ->
    % either stop_leaf or stop_empty_leaf2
    case merkle_tree:is_leaf(Node) of
        true  ->
            case merkle_tree:is_empty(Node) of
                false -> % stop_leaf
                    MaxItemsCount = erlang:min(Params#merkle_params.bucket_size,
                                               MyMaxItemsCount),
                    SyncAccRcv1 =
                        [{MaxItemsCount, merkle_tree:get_bucket(Node)} | SyncAccRcv],
                    SyncAccRcvLeafCount1 = SyncAccRcvLeafCount + 1,
                    OtherSyncAccDRLCount1 = OtherSyncAccDRLCount,
                    HashCmpL_OUT = HashCmpL_IN + 1;
                true -> % stop_empty_leaf2
                    % -> resolved directly at the other node, i.e. without a trivial sub process
                    SyncAccRcv1 = SyncAccRcv,
                    SyncAccRcvLeafCount1 = SyncAccRcvLeafCount,
                    OtherSyncAccDRLCount1 = OtherSyncAccDRLCount + 1,
                    HashCmpL_OUT = HashCmpL_IN
            end;
        false -> % stop_leaf
            {MyKVItems, LeafCount} = merkle_tree:get_items([Node]),
            SyncAccRcv1 =
                [{MyMaxItemsCount, MyKVItems} | SyncAccRcv],
            SyncAccRcvLeafCount1 = SyncAccRcvLeafCount + LeafCount,
            OtherSyncAccDRLCount1 = OtherSyncAccDRLCount,
            HashCmpL_OUT = HashCmpL_IN
    end,
    merkle_cmp_result(TR, TN, SigSizeI, SigSizeL,
                      MyMaxItemsCount, OtherMaxItemsCount, SyncIn, Params, Stats,
                      RestTreeAcc, SyncAccSend, SyncAccRcv1, SyncAccRcvLeafCount1,
                      MySyncAccDRK, MySyncAccDRLCount, OtherSyncAccDRLCount1,
                      AccCmp + 1, AccSkip,
                      NextLvlNodesActIN, HashCmpI_IN, HashCmpL_OUT).

%% @doc Helper for adding a leaf node's KV-List to a compressed binary
%%      during merkle sync.
-spec merkle_resolve_add_leaf_hash(
        Bucket::merkle_tree:mt_bucket(), P1EAllLeaves::float(), NumRestLeaves::pos_integer(),
        OtherMaxItemsCount::non_neg_integer(), BucketSizeBits::pos_integer(),
        HashesK::Bin, HashesV::Bin, PrevP0E::float())
        -> {HashesK::Bin, HashesV::Bin, PrevP0E::float(),
            ResortedBucket::merkle_tree:mt_bucket()}
    when is_subtype(Bin, bitstring()).
merkle_resolve_add_leaf_hash(
  Bucket, P1EAllLeaves, NumRestLeaves, OtherMaxItemsCount, BucketSizeBits,
  HashesK, HashesV, PrevP0E) ->
    BucketSize = length(Bucket),
    ?DBG_ASSERT(BucketSize > 0),
    ?DBG_ASSERT(BucketSize =< util:pow(2, BucketSizeBits)),
    HashesK1 = <<HashesK/bitstring, (BucketSize - 1):BucketSizeBits>>,
    P1E_next = calc_n_subparts_p1e(NumRestLeaves, P1EAllLeaves, PrevP0E),
%%     log:pal("merkle_send [ ~p ]:~n   ~p~n   ~p",
%%             [self(), {NumRestLeaves, P1EAllLeaves, PrevP0E}, {BucketSize, OtherMaxItemsCount, P1E_next}]),
    ExpDelta = 100, % TODO: set the configured value
    {SigSize, VSize} = trivial_signature_sizes(BucketSize, OtherMaxItemsCount, ExpDelta, P1E_next),
    P1E_p1 = trivial_worst_case_failprob(SigSize, BucketSize, OtherMaxItemsCount, ExpDelta),
    NextP0E = PrevP0E * (1 - P1E_p1),
%%     log:pal("merkle_send [ ~p ] (rest: ~B):~n   bits: ~p, P1E: ~p vs. ~p~n   P0E: ~p -> ~p",
%%             [self(), NumRestLeaves, {SigSize, VSize}, P1E_next, P1E_p1, PrevP0E, NextP0E]),
    {HashesKNew, HashesVNew, ResortedBucket} =
        compress_kv_list(Bucket, {HashesK1, HashesV}, SigSize, VSize,
                         fun trivial_compress_key/2),
    {HashesKNew, HashesVNew, NextP0E, ResortedBucket}.

%% @doc Helper for retrieving a leaf node's KV-List from the compressed binary
%%      returned by merkle_resolve_add_leaf_hash/8 during merkle sync.
-spec merkle_resolve_retrieve_leaf_hashes(
        HashesK::Bin, HashesV::Bin, P1EAllLeaves::float(), NumRestLeaves::pos_integer(),
        PrevP0E::float(), MyMaxItemsCount::non_neg_integer(),
        BucketSizeBits::pos_integer())
        -> {NewHashesK::Bin, NewHashesV::Bin, OtherBucketTree::kvi_tree(),
            OrigDBChunkLen::non_neg_integer(),
            SigSize::signature_size(), VSize::signature_size(), NextP0E::float()}
    when is_subtype(Bin, bitstring()).
merkle_resolve_retrieve_leaf_hashes(
  HashesK, HashesV, P1EAllLeaves, NumRestLeaves, PrevP0E, MyMaxItemsCount,
  BucketSizeBits) ->
    <<BucketSize0:BucketSizeBits/integer-unit:1, HashesKT/bitstring>> = HashesK,
    BucketSize = BucketSize0 + 1,
    P1E_next = calc_n_subparts_p1e(NumRestLeaves, P1EAllLeaves, PrevP0E),
%%     log:pal("merkle_receive [ ~p ]:~n   ~p~n   ~p",
%%             [self(), {NumRestLeaves, P1EAllLeaves, PrevP0E},
%%              {BucketSize, MyMaxItemsCount, P1E_next}]),
    ExpDelta = 100, % TODO: set the configured value
    {SigSize, VSize} = trivial_signature_sizes(BucketSize, MyMaxItemsCount, ExpDelta, P1E_next),
    P1E_p1 = trivial_worst_case_failprob(SigSize, BucketSize, MyMaxItemsCount, ExpDelta),
    NextP0E = PrevP0E * (1 - P1E_p1),
%%     log:pal("merkle_receive [ ~p ] (rest: ~B):~n   bits: ~p, P1E: ~p vs. ~p~n   P0E: ~p -> ~p",
%%             [self(), NumRestLeaves, {SigSize, VSize}, P1E_next, P1E_p1, PrevP0E, NextP0E]),
    % we need to know how large a piece is
    % -> peak into the binary (using the format in decompress_idx_list/3):
    IdxBitsSize = bits_for_number(SigSize),
    <<DiffSigSize1:IdxBitsSize/integer-unit:1, _/bitstring>> = HashesKT,
    OBucketKBinSize = BucketSize * DiffSigSize1 + IdxBitsSize,
    %log:pal("merkle: ~B", [OBucketKBinSize]),
    OBucketVBinSize = BucketSize * VSize,
    <<OBucketKBin:OBucketKBinSize/bitstring, NHashesK/bitstring>> = HashesKT,
    <<OBucketVBin:OBucketVBinSize/bitstring, NHashesV/bitstring>> = HashesV,
    {OBucketTree, _OrigDBChunkLen} =
        decompress_kv_list({OBucketKBin, OBucketVBin}, SigSize, VSize),
    {NHashesK, NHashesV, OBucketTree, BucketSize, SigSize, VSize, NextP0E}.

%% @doc Creates a compact binary consisting of bitstrings with trivial
%%      reconciliations for all sync requests to send.
-spec merkle_resolve_leaves_send(State::state(), NextP0E::float()) -> NewState::state().
merkle_resolve_leaves_send(
  State = #rr_recon_state{params = Params, initiator = IsInitiator,
                          stats = Stats, dest_recon_pid = DestReconPid,
                          dest_rr_pid = DestRRPid,   ownerPid = OwnerL,
                          merkle_sync = {SyncSend, SyncRcv, SyncRcvLeafCount,
                                         {MySyncDRK, MySyncDRLCount, OtherSyncDRLCount}}},
  NextP0E) ->
    ?TRACE("Sync (~s):~nsend:~.2p~n rcv:~.2p",
           [?IIF(IsInitiator, "I", "NI"), SyncNewSend, SyncNewRcv]),
    % resolve items from emptyLeaf-* comparisons with empty leaves on any node as key_upd:
    NStats1 = send_resolve_request(Stats, MySyncDRK, OwnerL, DestRRPid, IsInitiator, true),
    NStats2 = rr_recon_stats:inc(
                [{tree_leavesSynced, MySyncDRLCount + OtherSyncDRLCount},
                 {rs_expected, ?IIF(OtherSyncDRLCount > 0, 1, 0)}], NStats1),
    % allow the garbage collector to free the SyncDRK list here
    SyncNew1 = {SyncSend, SyncRcv, SyncRcvLeafCount, {[], MySyncDRLCount, OtherSyncDRLCount}},

    SyncSendL = length(SyncSend),
    SyncRcvL = length(SyncRcv),
    TrivialProcs = SyncSendL + SyncRcvL,
    P1EAllLeaves = calc_n_subparts_p1e(1, Params#merkle_params.p1e, NextP0E),
    ?MERKLE_DEBUG("merkle (~s) - LeafSync~n~B (send), ~B (receive), ~B direct (~s)\tP1EAllLeaves: ~g\t"
                  "ItemsToSend: ~B (~g per leaf)",
                  [?IIF(IsInitiator, "I", "NI"), SyncSendL, SyncRcvL,
                   SyncDRLCount, ?IIF(IsInitiator, "in", "out"),
                   P1EAllLeaves,
                   lists:sum([length(MyKVItems) || {_, MyKVItems} <- SyncSend]),
                   ?IIF(SyncSend =/= [],
                        lists:sum([length(MyKVItems) || {_, MyKVItems} <- SyncSend]) /
                            SyncSendL, 0.0)]),
    
    if SyncSendL =:= 0 andalso SyncRcvL =:= 0 ->
           % nothing to do
           shutdown(sync_finished,
                    State#rr_recon_state{stats = NStats2,
                                         merkle_sync = SyncNew1, misc = []});
       SyncSend =/= [] ->
           % note: we do not have empty buckets here and thus always store (BucketSize - 1)
           BucketSizeBits = bits_for_number(Params#merkle_params.bucket_size - 1),
           % note: 1 trivial proc contains 1 leaf
           {HashesK, HashesV, NewSyncSend_rev, ThisP0E, LeafCount} =
               lists:foldl(
                 fun({OtherMaxItemsCount, MyKVItems},
                     {HashesKAcc, HashesVAcc, SyncAcc, PrevP0E, LeafNAcc}) ->
                         {HashesKAcc1, HashesVAcc1, CurP0E, MyKVItems1} =
                             merkle_resolve_add_leaf_hash(
                               MyKVItems, P1EAllLeaves, TrivialProcs - LeafNAcc,
                               OtherMaxItemsCount, BucketSizeBits, HashesKAcc, HashesVAcc,
                               PrevP0E),
                         {HashesKAcc1, HashesVAcc1,
                          [{OtherMaxItemsCount, MyKVItems1} | SyncAcc],
                          CurP0E, LeafNAcc + 1}
                 end, {<<>>, <<>>, [], 1.0, 0}, SyncSend),
           % the other node will send its items from this CKV list - increase rs_expected, too
           NStats3 = rr_recon_stats:inc([{tree_leavesSynced, LeafCount},
                                         {rs_expected, 1}], NStats2),
           ?DBG_ASSERT(rr_recon_stats:get(p1e_phase2, NStats3) =:= 0.0),
           
           NStats4  = rr_recon_stats:set([{p1e_phase2, 1 - ThisP0E}], NStats3),
           MerkleSyncNew1 = {lists:reverse(NewSyncSend_rev), SyncRcv, SyncRcvLeafCount,
                             {[], MySyncDRLCount, OtherSyncDRLCount}},
           ?MERKLE_DEBUG("merkle (~s) - HashesSize: ~B (~B compressed)",
                         [?IIF(_IsInitiator, "I", "NI"),
                          erlang:byte_size(
                            erlang:term_to_binary(Hashes)),
                          erlang:byte_size(
                            erlang:term_to_binary(Hashes, [compressed]))]),
           ?DBG_ASSERT(HashesK =/= <<>> orelse HashesV =/= <<>>),
           send(DestReconPid, {resolve_req, HashesK, HashesV}),
           State#rr_recon_state{stage = resolve, stats = NStats4,
                                merkle_sync = MerkleSyncNew1,
                                misc = [{all_leaf_p1e, P1EAllLeaves},
                                        {trivial_procs, TrivialProcs}]};
       true ->
           % only wait for the other node's resolve_req
           State#rr_recon_state{stage = resolve, merkle_sync = SyncNew1,
                                stats = NStats2,
                                misc = [{all_leaf_p1e, P1EAllLeaves},
                                        {trivial_procs, TrivialProcs}]}
    end.

%% @doc Decodes the trivial reconciliations from merkle_resolve_leaves_send/5
%%      and resolves them returning a compressed idx list each with keys to
%%      request.
-spec merkle_resolve_leaves_receive(State::state(), HashesK::bitstring(),
                                    HashesV::bitstring()) -> NewState::state().
merkle_resolve_leaves_receive(
  State = #rr_recon_state{initiator = IsInitiator,
                          merkle_sync = {SyncSend, SyncRcv, SyncRcvLeafCount, DirectResolve},
                          params = Params,
                          dest_rr_pid = DestRRPid,   ownerPid = OwnerL,
                          dest_recon_pid = DestRCPid, stats = Stats,
                          misc = [{all_leaf_p1e, P1EAllLeaves},
                                  {trivial_procs, TrivialProcs}]},
  HashesK, HashesV) ->
    ?DBG_ASSERT(HashesK =/= <<>> orelse HashesV =/= <<>>),
    % note: we do not have empty buckets here and thus always store (BucketSize - 1)
    BucketSizeBits = bits_for_number(Params#merkle_params.bucket_size - 1),
    % mismatches to resolve:
    % * at initiator    : inner(I)-leaf(NI) or leaf(NI)-non-empty-leaf(I)
    % * at non-initiator: inner(NI)-leaf(I)
    % note: 1 trivial proc may contain more than 1 leaf!
    {<<>>, <<>>, ToSend, ToResolve, ResolveNonEmpty, _TrivialProcsRest,
     ThisP0E} =
        lists:foldl(
          fun({MyMaxItemsCount, MyKVItems},
              {HashesKAcc, HashesVAcc, ToSend, ToResolve, ResolveNonEmpty,
               TProcsAcc, P0EIn}) ->
                  {NHashesKAcc, NHashesVAcc, OBucketTree, _OrigDBChunkLen,
                   SigSize, VSize, ThisP0E} =
                      merkle_resolve_retrieve_leaf_hashes(
                        HashesKAcc, HashesVAcc, P1EAllLeaves, TProcsAcc, P0EIn,
                        MyMaxItemsCount, BucketSizeBits),
                  % calc diff (trivial sync)
                  ?DBG_ASSERT(MyKVItems =/= []),
                  {ToSend1, ToReqIdx1, OBucketTree1} =
                      get_full_diff(
                        MyKVItems, OBucketTree, ToSend, [], SigSize, VSize),
                  ReqIdx = lists:usort(
                             [Idx || {_Version, Idx} <- mymaps:values(OBucketTree1)]
                                 ++ ToReqIdx1),
                  ToResolve1 = pos_to_bitstring(ReqIdx, ToResolve, 0,
                                                Params#merkle_params.bucket_size),
                  {NHashesKAcc, NHashesVAcc, ToSend1, ToResolve1,
                   ?IIF(ReqIdx =/= [], true, ResolveNonEmpty),
                   TProcsAcc - 1, ThisP0E}
          end, {HashesK, HashesV, [], [], false, TrivialProcs, 1.0}, SyncRcv),

    % send resolve message:
    % resolve items we should send as key_upd:
    % NOTE: the other node does not know whether our ToSend is empty and thus
    %       always expects a following resolve process!
    Stats1 = send_resolve_request(Stats, ToSend, OwnerL, DestRRPid, IsInitiator, false),
    % let the other node's rr_recon process identify the remaining keys;
    % it will use key_upd_send (if non-empty) and we must thus increase
    % the number of resolve processes here!
    if ResolveNonEmpty -> 
           ToResolve1 = erlang:list_to_bitstring(lists:reverse(ToResolve)),
           MerkleResReqs = 1;
       true ->
           ToResolve1 = <<>>,
           MerkleResReqs = 0
    end,
    NStats1 = rr_recon_stats:inc([{tree_leavesSynced, SyncRcvLeafCount},
                                  {rs_expected, MerkleResReqs}], Stats1),
    PrevP1E_p2 = rr_recon_stats:get(p1e_phase2, NStats1),
    NStats  = rr_recon_stats:set(
                [{p1e_phase2, 1 - (1 - PrevP1E_p2) * ThisP0E}], NStats1),
    ?TRACE("resolve_req Merkle Session=~p ; resolve expexted=~B",
           [rr_recon_stats:get(session_id, NStats),
            rr_recon_stats:get(rs_expected, NStats)]),

    comm:send(DestRCPid, {resolve_req, ToResolve1}),
    % free up some memory:
    NewState = State#rr_recon_state{merkle_sync = {SyncSend, [], SyncRcvLeafCount, DirectResolve},
                                    stats = NStats},
    % shutdown if nothing was sent (otherwise we need to wait for the returning CKidx):
    if SyncSend =:= [] -> shutdown(sync_finished, NewState);
       true -> NewState
    end.

%% @doc Decodes all requested keys from merkle_resolve_leaves_receive/3 (as a
%%      result of sending resolve requests) and resolves the appropriate entries
%%      (if non-empty) with our data using a key_upd_send.
-spec merkle_resolve_leaves_ckidx(
        Sync::[merkle_sync_send()], BinKeyList::bitstring(), DestRRPid::comm:mypid(),
        Stats, OwnerL::comm:erl_local_pid(), Params::#merkle_params{},
        ToSend::[?RT:key()], IsInitiator::boolean()) -> NewStats::Stats
    when is_subtype(Stats, rr_recon_stats:stats()).
merkle_resolve_leaves_ckidx([{_OtherMaxItemsCount, MyKVItems} | TL],
                             BinKeyList0,
                             DestRRPid, Stats, OwnerL, Params, ToSend, IsInitiator) ->
    Positions = Params#merkle_params.bucket_size,
    <<ReqKeys:Positions/bitstring-unit:1, BinKeyList/bitstring>> = BinKeyList0,
    ToSend1 = bitstring_to_k_list_kv(ReqKeys, MyKVItems, ToSend),
    merkle_resolve_leaves_ckidx(TL, BinKeyList, DestRRPid, Stats, OwnerL, Params,
                                ToSend1, IsInitiator);
merkle_resolve_leaves_ckidx([], <<>>, DestRRPid, Stats, OwnerL, _Params,
                            [_|_] = ToSend, IsInitiator) ->
    send_resolve_request(Stats, ToSend, OwnerL, DestRRPid, IsInitiator, false).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% art recon
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Gets all leaves in the merkle node list (recursively) which are not
%%      present in the art structure.
-spec art_get_sync_leaves(Nodes::NodeL, art:art(), ToSyncAcc::NodeL,
                          NCompAcc::non_neg_integer(), NSkipAcc::non_neg_integer(),
                          NLSyncAcc::non_neg_integer())
        -> {ToSync::NodeL, NComp::non_neg_integer(), NSkip::non_neg_integer(),
            NLSync::non_neg_integer()} when
    is_subtype(NodeL,  [merkle_tree:mt_node()]).
art_get_sync_leaves([], _Art, ToSyncAcc, NCompAcc, NSkipAcc, NLSyncAcc) ->
    {ToSyncAcc, NCompAcc, NSkipAcc, NLSyncAcc};
art_get_sync_leaves([Node | Rest], Art, ToSyncAcc, NCompAcc, NSkipAcc, NLSyncAcc) ->
    NComp = NCompAcc + 1,
    IsLeaf = merkle_tree:is_leaf(Node),
    case art:lookup(Node, Art) of
        true ->
            NSkip = NSkipAcc + ?IIF(IsLeaf, 0, merkle_tree:size(Node) - 1),
            art_get_sync_leaves(Rest, Art, ToSyncAcc, NComp, NSkip, NLSyncAcc);
        false ->
            if IsLeaf ->
                   art_get_sync_leaves(Rest, Art, [Node | ToSyncAcc],
                                       NComp, NSkipAcc, NLSyncAcc + 1);
               true ->
                   art_get_sync_leaves(
                     lists:append(merkle_tree:get_childs(Node), Rest), Art,
                     ToSyncAcc, NComp, NSkipAcc, NLSyncAcc)
            end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Sends a request_resolve message to the rrepair layer which sends the
%%      entries from the given keys to the other node with a feedback request.
-spec send_resolve_request(Stats, ToSend::[?RT:key()], OwnerL::comm:erl_local_pid(),
                           DestRRPid::comm:mypid(), IsInitiator::boolean(),
                           SkipIfEmpty::boolean()) -> Stats
    when is_subtype(Stats, rr_recon_stats:stats()).
send_resolve_request(Stats, [] = _ToSend, _OwnerL, _DestRRPid, _IsInitiator,
                     true = _SkipIfEmpty) ->
    ?TRACE("Resolve Session=~p ; ToSend=~p",
           [rr_recon_stats:get(session_id, Stats), 0]),
    Stats;
send_resolve_request(Stats, ToSend, OwnerL, DestRRPid, IsInitiator,
                     _SkipIfEmpty) ->
    SID = rr_recon_stats:get(session_id, Stats),
    ?TRACE("Resolve Session=~p ; ToSend=~p", [SID, length(ToSend)]),
    % note: the resolve request is counted at the initiator and
    %       thus from_my_node must be set accordingly on this node!
    ?DBG_ASSERT2(length(ToSend) =:= length(lists:usort(ToSend)),
                 {non_unique_send_list, ToSend}),
    send_local(OwnerL, {request_resolve, SID,
                        {key_upd_send, DestRRPid, ToSend, _ToReq = []},
                        [{from_my_node, ?IIF(IsInitiator, 1, 0)},
                         {feedback_request, comm:make_global(OwnerL)}]}),
    % key_upd_send + one reply from a subsequent feedback response (?key_upd)
    rr_recon_stats:inc([{rs_expected, 2}], Stats).

%% @doc Gets the number of bits needed to encode the given number.
-spec bits_for_number(Number::pos_integer()) -> pos_integer();
                     (0) -> 0.
bits_for_number(0) -> 0;
bits_for_number(Number) ->
    util:ceil(util:log2(Number + 1)).

%% @doc Splits P1E into N equal independent sub-processes and returns the P1E
%%      to use for each of these sub-processes: p_sub = 1 - (1 - p1e)^(1/n).
%%      This is based on p0e(total) = (1 - p1e(total)) = p0e(each)^n = (1 - p1e(each))^n.
-spec calc_n_subparts_p1e(N::number(), P1E::float()) -> P1E_sub::float().
calc_n_subparts_p1e(N, P1E) when N == 1 andalso P1E > 0 andalso P1E < 1 ->
    P1E;
calc_n_subparts_p1e(N, P1E) when P1E > 0 andalso P1E < 1.0e-8 ->
%%     _VP = 1 - math:pow(1 - P1E, 1 / N).
    % BEWARE: we cannot use (1-p1E) since it is near 1 and its floating
    %         point representation is sub-optimal!
    % => use Taylor expansion of 1 - (1 - p1e)^(1/n)  at P1E = 0
    % http://www.wolframalpha.com/input/?i=Taylor+expansion+of+1+-+%281+-+p%29^%281%2Fn%29++at+p+%3D+0
    N2 = N * N, N3 = N2 * N, N4 = N3 * N, N5 = N4 * N,
    P1E2 = P1E * P1E, P1E3 = P1E2* P1E, P1E4 = P1E3 * P1E, P1E5 = P1E4 * P1E,
    _VP = P1E / N + (N - 1) * P1E2 / (2 * N2)
              + (2*N2 - 3*N + 1) * P1E3 / (6 * N3)
              + (6*N3 - 11*N2 + 6*N - 1) * P1E4 / (24 * N4)
              + (24*N4 - 50*N3 + 35*N2 - 10*N + 1) * P1E5 / (120 * N5); % +O[p^6]
calc_n_subparts_p1e(N, P1E) when P1E > 0 andalso P1E < 1 ->
    _VP = 1 - math:pow(1 - P1E, 1 / N).

%% @doc Splits P1E into N further (equal) independent sub-processes and returns
%%      the P1E to use for the next of these sub-processes with the previous
%%      sub-processes having a success probability of PrevP0 (a product of
%%      all (1-P1E_sub)).
%%      This is based on p0e(total) = (1 - p1e(total)) = p0e(each)^n = (1 - p1e(each))^n.
-spec calc_n_subparts_p1e(N::number(), P1E::float(), PrevP0::float())
        -> P1E_sub::float().
calc_n_subparts_p1e(N, P1E, 1.0) when N == 1 andalso P1E > 0 andalso P1E < 1 ->
    % special case with e.g. no items in the first/previous phase
    P1E;
calc_n_subparts_p1e(N, P1E, PrevP0E) when P1E > 0 andalso P1E < 1.0e-8 andalso
                                              PrevP0E > 0 andalso PrevP0E =< 1 ->
    % BEWARE: we cannot use (1-p1E) since it is near 1 and its floating
    %         point representation is sub-optimal!
    % => use Taylor expansion of 1 - ((1 - p1e) / PrevP0E)^(1/n)  at P1E = 0
    % http://www.wolframalpha.com/input/?i=Taylor+expansion+of+1+-+%28%281+-+p%29%2Fq%29^%281%2Fn%29++at+p+%3D+0
    N2 = N * N, N3 = N2 * N, N4 = N3 * N, N5 = N4 * N,
    P1E2 = P1E * P1E, P1E3 = P1E2* P1E, P1E4 = P1E3 * P1E, P1E5 = P1E4 * P1E,
    Q1 = math:pow(1 / PrevP0E, 1 / N),
    VP = (1 - Q1) + (P1E * Q1) / N +
              ((N-1) * P1E2 * Q1) / (2 * N2) +
              ((N-1) * (2 * N - 1) * P1E3 * Q1) / (6 * N3) +
              ((N-1) * (2 * N - 1) * (3 * N - 1) * P1E4 * Q1) / (24 * N4) +
              ((N-1) * (2 * N - 1) * (3 * N - 1) * (4 * N - 1) * P1E5 * Q1) / (120 * N5), % +O[p^6]
    if VP > 0 andalso VP < 1 ->
           VP;
       VP =< 0 ->
           log:log("~w: [ ~p:~.0p ] P1E constraint broken (phase 1 overstepped?)~n"
                   " continuing with smallest possible failure probability"
                   " (instead of ~g)",
                   [?MODULE, pid_groups:my_groupname(), self(), VP]),
           1.0e-16 % do not go below this so that the opposite probability is possible as a float!
    end;
calc_n_subparts_p1e(N, P1E, PrevP0E) when P1E > 0 andalso P1E < 1 andalso
                                              PrevP0E > 0 andalso PrevP0E =< 1 ->
    VP = 1 - math:pow((1 - P1E) / PrevP0E, 1 / N),
    if VP > 0 andalso VP < 1 ->
           VP;
       VP =< 0 ->
           log:log("~w: [ ~p:~.0p ] P1E constraint broken (phase 1 overstepped?)"
                   " - continuing with smallest possible failure probability"
                   " (instead of ~g)",
                   [?MODULE, pid_groups:my_groupname(), self(), VP]),
           1.0e-16 % do not go below this so that the opposite probability is possible as a float!
    end.

%% @doc Calculates the signature sizes for comparing every item in Items
%%      (at most ItemCount) with OtherItemCount other items and expecting at
%%      most min(ItemCount, OtherItemCount) version comparisons.
%%      Sets the bit sizes to have an error below P1E.
-spec trivial_signature_sizes
        (ItemCount::non_neg_integer(), OtherItemCount::non_neg_integer(),
         ExpDelta::number(), P1E::float())
        -> {SigSize::signature_size(), VSize::signature_size()}.
trivial_signature_sizes(0, _, _ExpDelta,  _P1E) ->
    {0, 0}; % invalid but since there are 0 items, this is ok!
trivial_signature_sizes(_, 0, _ExpDelta, _P1E) ->
    {0, 0}; % invalid but since there are 0 items, this is ok!
trivial_signature_sizes(ItemCount, OtherItemCount, ExpDelta, P1E) ->
    MaxKeySize = 128, % see compress_key/2
    case get_min_version_bits() of
        variable ->
            % reduce P1E for the two parts here (key and version comparison)
            P1E_sub = calc_n_subparts_p1e(2, P1E),
            SigSize = calc_signature_size_nm_pair(
                        ItemCount, OtherItemCount, ExpDelta, P1E_sub, MaxKeySize),
            % note: we have n one-to-one comparisons
            VCompareCount = erlang:min(ItemCount, OtherItemCount),
            VP = calc_n_subparts_p1e(erlang:max(1, VCompareCount), P1E_sub),
            VSize = min_max(util:ceil(util:log2(1 / VP)), 1, 128),
            ok;
        VSize ->
            SigSize = calc_signature_size_nm_pair(
                        ItemCount, OtherItemCount, ExpDelta, P1E, MaxKeySize),
            ok
    end,
%%     log:pal("trivial [ ~p ] - P1E: ~p, \tSigSize: ~B, \tVSizeL: ~B~n"
%%             "MyIC: ~B, \tOtIC: ~B",
%%             [self(), P1E, SigSize, VSize, ItemCount, OtherItemCount]),
    {SigSize, VSize}.

%% @doc Calculates the worst-case failure probability of the trivial algorithm
%%      with the given signature size, item counts and expected delta.
%%      NOTE: Precision loss may occur for very high values!
-spec trivial_worst_case_failprob(
        SigSize::signature_size(), ItemCount::non_neg_integer(),
        OtherItemCount::non_neg_integer(), ExpDelta::number()) -> float().
trivial_worst_case_failprob(0, 0, _OtherItemCount, _ExpDelta) ->
    % this is exact! (see special case in trivial_signature_sizes/4)
    0.0;
trivial_worst_case_failprob(0, _ItemCount, 0, _ExpDelta) ->
    % this is exact! (see special case in trivial_signature_sizes/4)
    0.0;
trivial_worst_case_failprob(SigSize, ItemCount, OtherItemCount, ExpDelta) ->
    BK2 = util:pow(2, SigSize),
    % both solutions have their problems with floats near 1
    % -> use fastest as they are quite close
    NT = calc_max_different_hashes(ItemCount, OtherItemCount, ExpDelta),
    % exact:
%%     1 - util:for_to_fold(1, NT - 1,
%%                          fun(I) -> (1 - I / BK2) end,
%%                          fun erlang:'*'/2, 1).
    % approx:
    1 - math:exp(-(NT * (NT - 1) / 2) / BK2).

%% @doc Creates a compressed key-value list comparing every item in Items
%%      (at most ItemCount) with OtherItemCount other items and expecting at
%%      most min(ItemCount, OtherItemCount) version comparisons.
%%      Sets the bit sizes to have an error below P1E.
-spec compress_kv_list_p1e(
        Items::db_chunk_kv(), ItemCount, OtherItemCount, ExpDelta, P1E,
        SigFun::fun((ItemCount, OtherItemCount, ExpDelta, P1E) -> {SigSize, VSize::signature_size()}),
        KeyComprFun::fun(({?RT:key(), client_version()}, SigSize) -> bitstring()))
        -> {KeyDiff::Bin, VBin::Bin, ResortedKOrigList::db_chunk_kv(),
            SigSize::signature_size(), VSize::signature_size()}
    when is_subtype(Bin, bitstring()),
         is_subtype(ItemCount, non_neg_integer()),
         is_subtype(OtherItemCount, non_neg_integer()),
         is_subtype(ExpDelta, number()),
         is_subtype(P1E, float()),
         is_subtype(SigSize, signature_size()).
compress_kv_list_p1e(DBItems, ItemCount, OtherItemCount, ExpDelta, P1E, SigFun, KeyComprFun) ->
    {SigSize, VSize} = SigFun(ItemCount, OtherItemCount, ExpDelta, P1E),
    {HashesKNew, HashesVNew, ResortedBucket} =
        compress_kv_list(DBItems, {<<>>, <<>>}, SigSize, VSize, KeyComprFun),
    % debug compressed and uncompressed sizes:
    ?TRACE("~B vs. ~B items, SigSize: ~B, VSize: ~B, ChunkSize: ~B+~B / ~B+~B bits",
            [ItemCount, OtherItemCount, SigSize, VSize,
             erlang:bit_size(erlang:term_to_binary(HashesKNew)),
             erlang:bit_size(erlang:term_to_binary(HashesVNew)),
             erlang:bit_size(
                 erlang:term_to_binary(HashesKNew,
                                       [{minor_version, 1}, {compressed, 2}])),
             erlang:bit_size(
                 erlang:term_to_binary(HashesVNew,
                                       [{minor_version, 1}, {compressed, 2}]))]),
    {HashesKNew, HashesVNew, ResortedBucket, SigSize, VSize}.

%% @doc Calculates the signature size for comparing ItemCount items with
%%      OtherItemCount other items (including versions into the hashes).
%%      Sets the bit size to have an error below P1E.
-spec shash_signature_sizes
        (ItemCount::non_neg_integer(), OtherItemCount::non_neg_integer(),
         ExpDelta::number(), P1E::float())
        -> {SigSize::signature_size(), _VSize::0}.
shash_signature_sizes(0, _, _ExpDelta, _P1E) ->
    {0, 0}; % invalid but since there are 0 items, this is ok!
shash_signature_sizes(_, 0, _ExpDelta, _P1E) ->
    {0, 0}; % invalid but since there are 0 items, this is ok!
shash_signature_sizes(ItemCount, OtherItemCount, ExpDelta, P1E) ->
    % reduce P1E for the two parts here (hash and trivial phases)
    P1E_sub = calc_n_subparts_p1e(2, P1E),
    MaxKeySize = 128, % see compress_key/2
    SigSize = calc_signature_size_nm_pair(
                ItemCount, OtherItemCount, ExpDelta, P1E_sub, MaxKeySize),
%%     log:pal("shash [ ~p ] - P1E: ~p, \tSigSize: ~B, \tMyIC: ~B, \tOtIC: ~B",
%%             [self(), P1E, SigSize, ItemCount, OtherItemCount]),
    {SigSize, 0}.

%% @doc Calculates the bloom FP, i.e. a single comparison's failure probability,
%%      assuming:
%%      * the other node executes NrChecks number of checks
%%      * the worst case in the number of item checks that could yield false
%%        positives, i.e. with items that are not encoded in the Bloom filter
%%        taking the expected delta into account
-spec bloom_fp(BFCount::non_neg_integer(), NrChecks::non_neg_integer(),
               ExpDelta::number(), P1E::float()) -> float().
bloom_fp(BFCount, NrChecks, ExpDelta, P1E) ->
    NrChecksNotInBF = bloom_calc_max_nr_checks(BFCount, NrChecks, ExpDelta),
    % 1 - math:pow(1 - P1E, 1 / erlang:max(NrChecksNotInBF, 1)).
    % more precise:
    calc_n_subparts_p1e(erlang:max(NrChecksNotInBF, 1), P1E).

%% @doc Helper for bloom_fp/3 calculating the maximum number of item checks
%%      with items not in the Bloom filter when an upper bound on the delta is
%%      known.
-spec bloom_calc_max_nr_checks(
        BFCount::non_neg_integer(), NrChecks::non_neg_integer(),
        ExpDelta::number()) -> non_neg_integer().
bloom_calc_max_nr_checks(BFCount, NrChecks, ExpDelta) ->
    MaxItems = calc_max_different_hashes(BFCount, NrChecks, ExpDelta),
    X = if ExpDelta == 0   -> 0;
           ExpDelta == 100 -> NrChecks; % special case of the one below
           is_float(ExpDelta) ->
               % worst case: we have all the ExpDelta percent items the other node does not have
               util:ceil(MaxItems * ExpDelta / 100);
           is_integer(ExpDelta) ->
               % -> use integer division (and round up) for higher precision:
               (MaxItems * ExpDelta + 99) div 100
        end,
%%     log:pal("[ ~p ] MaxItems: ~B Checks: ~B", [self(), MaxItems, X]),
    X.

%% @doc Calculates the worst-case failure probability of the bloom algorithm
%%      with the Bloom filter and number of items to check inside the filter.
%%      NOTE: Precision loss may occur for very high values!
-spec bloom_worst_case_failprob(
        BF::bloom:bloom_filter(), NrChecks::non_neg_integer(),
        ExpDelta::number()) -> float().
bloom_worst_case_failprob(_BF, 0, _ExpDelta) ->
    0.0;
bloom_worst_case_failprob(BF, NrChecks, ExpDelta) ->
    Fpr = bloom:get_property(BF, fpr),
    BFCount = bloom:get_property(BF, items_count),
    bloom_worst_case_failprob_(Fpr, BFCount, NrChecks, ExpDelta).

%% @doc Helper for bloom_worst_case_failprob/2.
%% @see bloom_worst_case_failprob/2
-spec bloom_worst_case_failprob_(
        Fpr::float(), BFCount::non_neg_integer(), NrChecks::non_neg_integer(),
        ExpDelta::number()) -> float().
bloom_worst_case_failprob_(_Fpr, _BFCount, 0, _ExpDelta) ->
    0.0;
bloom_worst_case_failprob_(Fpr, BFCount, NrChecks, ExpDelta) ->
    ?DBG_ASSERT2(Fpr >= 0 andalso Fpr =< 1, Fpr),
    NrChecksNotInBF = bloom_calc_max_nr_checks(BFCount, NrChecks, ExpDelta),
    % 1 - math:pow(1 - Fpr, NrChecksNotInBF).
    % more precise:
    if Fpr == 0.0 -> 0.0;
       Fpr == 1.0 -> 1.0;
       NrChecksNotInBF == 0 -> 0.0;
       true       -> calc_n_subparts_p1e(1 / NrChecksNotInBF, Fpr)
    end.

-spec build_recon_struct(
        method(), DestI::intervals:non_empty_interval(), db_chunk_kv(),
        InitiatorMaxItems::non_neg_integer() | undefined, % not applicable on iniator
        Params::parameters() | {}) -> {sync_struct(), P1E_p1::float()}.
build_recon_struct(trivial, I, DBItems, InitiatorMaxItems, _Params) ->
    % at non-initiator
    ?DBG_ASSERT(not intervals:is_empty(I)),
    ?DBG_ASSERT(InitiatorMaxItems =/= undefined),
    ItemCount = length(DBItems),
    ExpDelta = get_max_expected_delta(),
    {MyDiffK, MyDiffV, ResortedKVOrigList, SigSize, VSize} =
        compress_kv_list_p1e(DBItems, ItemCount, InitiatorMaxItems,
                             ExpDelta, get_p1e(),
                             fun trivial_signature_sizes/4, fun trivial_compress_key/2),
    {#trivial_recon_struct{interval = I, reconPid = comm:this(), exp_delta = ExpDelta,
                           db_chunk = {MyDiffK, MyDiffV, ResortedKVOrigList},
                           sig_size = SigSize, ver_size = VSize},
     _P1E_p1 = trivial_worst_case_failprob(SigSize, ItemCount, InitiatorMaxItems, ExpDelta)};
build_recon_struct(shash, I, DBItems, InitiatorMaxItems, _Params) ->
    % at non-initiator
    ?DBG_ASSERT(not intervals:is_empty(I)),
    ?DBG_ASSERT(InitiatorMaxItems =/= undefined),
    ItemCount = length(DBItems),
    P1E = get_p1e(),
    ExpDelta = get_max_expected_delta(),
    {MyDiffK, <<>>, ResortedKVOrigList, SigSize, 0} =
        compress_kv_list_p1e(DBItems, ItemCount, InitiatorMaxItems,
                             ExpDelta, P1E,
                             fun shash_signature_sizes/4, fun compress_key/2),
    {#shash_recon_struct{interval = I, reconPid = comm:this(), exp_delta = ExpDelta,
                         db_chunk = {MyDiffK, ResortedKVOrigList},
                         sig_size = SigSize, p1e = P1E},
    % Note: we can only guess the number of items of the initiator here, so
    %       this is not exactly the P1E of phase 1!
     _P1E_p1 = trivial_worst_case_failprob(SigSize, ItemCount, InitiatorMaxItems, ExpDelta)};
build_recon_struct(bloom, I, DBItems, InitiatorMaxItems, _Params) ->
    % at non-initiator
    ?DBG_ASSERT(not intervals:is_empty(I)),
    ?DBG_ASSERT(InitiatorMaxItems =/= undefined),
    % note: for bloom, parameters don't need to match (only one bloom filter at
    %       the non-initiator is created!) - use our own parameters
    MyMaxItems = length(DBItems),
    P1E = get_p1e(),
    P1E_p1 = calc_n_subparts_p1e(2, P1E),
    P1E_p1_bf = calc_n_subparts_p1e(2, P1E_p1), % one bloom filter on each side!
    % decide for a common Bloom filter size (and number of hash functions)
    % for an efficient diff BF - use a combination where both Bloom filters
    % are below the targeted P1E_p1_bf (we may thus not reach P1E_p1 exactly):
    ExpDelta = get_max_expected_delta(),
    FP1 = bloom_fp(MyMaxItems, InitiatorMaxItems, ExpDelta, P1E_p1_bf),
    FP2 = bloom_fp(InitiatorMaxItems, MyMaxItems, ExpDelta, P1E_p1_bf),
    {K1, M1} = bloom:calc_HF_num_Size_opt(MyMaxItems, FP1),
    {K2, M2} = bloom:calc_HF_num_Size_opt(InitiatorMaxItems, FP2),
%%     log:pal("My: ~B OtherMax: ~B~nbloom1: ~p~nbloom2: ~p",
%%             [MyMaxItems, InitiatorMaxItems, {FP1, K1, M1}, {FP2, K2, M2}]),
    FP1_MyFP = bloom_worst_case_failprob_(
                 bloom:calc_FPR(M1, MyMaxItems, K1), MyMaxItems, InitiatorMaxItems, ExpDelta),
    FP1_OtherFP = bloom_worst_case_failprob_(
                    bloom:calc_FPR(M1, InitiatorMaxItems, K1), InitiatorMaxItems, MyMaxItems, ExpDelta),
    FP2_MyFP = bloom_worst_case_failprob_(
                 bloom:calc_FPR(M2, MyMaxItems, K2), MyMaxItems, InitiatorMaxItems, ExpDelta),
    FP2_OtherFP = bloom_worst_case_failprob_(
                    bloom:calc_FPR(M2, InitiatorMaxItems, K2), InitiatorMaxItems, MyMaxItems, ExpDelta),
    FP1_P1E_p1 = 1 - (1 - FP1_MyFP) * (1 - FP1_OtherFP),
    FP2_P1E_p1 = 1 - (1 - FP2_MyFP) * (1 - FP2_OtherFP),
    BF0 = if FP1_P1E_p1 =< P1E_p1 andalso FP2_P1E_p1 =< P1E_p1 andalso M1 =< M2 ->
                 bloom:new(M1, ?REP_HFS:new(K1));
             FP1_P1E_p1 =< P1E_p1 andalso FP2_P1E_p1 =< P1E_p1 andalso M1 > M2 ->
                 bloom:new(M2, ?REP_HFS:new(K2));
             FP1_P1E_p1 =< P1E_p1 ->
                 bloom:new(M1, ?REP_HFS:new(K1));
             FP2_P1E_p1 =< P1E_p1 ->
                 bloom:new(M2, ?REP_HFS:new(K2));
             true ->
                 % all other cases are probably due to floating point inefficiencies
                 log:log("~w: [ ~p:~.0p ] P1E constraint for phase 1 probably broken",
                         [?MODULE, pid_groups:my_groupname(), self()]),
                 bloom:new(M1, ?REP_HFS:new(K1))
          end,
%%     log:pal("~w: [ ~p:~.0p ]~n NI:~p, P1E_bf=~p "
%%             " m=~B k=~B NICount=~B ICount=~B~n"
%%             " P1E_bf1=~p P1E_bf2=~p",
%%             [?MODULE, pid_groups:my_groupname(), self(),
%%              comm:this(), P1E_p1_bf, bloom:get_property(BF0, size),
%%              ?REP_HFS:size(bloom:get_property(BF0, hfs)),
%%              MyMaxItems, InitiatorMaxItems,
%%              bloom_worst_case_failprob_(
%%                bloom:calc_FPR(
%%                  bloom:get_property(BF0, size), MyMaxItems,
%%                  ?REP_HFS:size(bloom:get_property(BF0, hfs))), InitiatorMaxItems),
%%              bloom_worst_case_failprob_(
%%                bloom:calc_FPR(
%%                  bloom:get_property(BF0, size), InitiatorMaxItems,
%%                  ?REP_HFS:size(bloom:get_property(BF0, hfs))), MyMaxItems)]),
    HfCount = ?REP_HFS:size(bloom:get_property(BF0, hfs)),
    BF = bloom:add_list(BF0, DBItems),
    {#bloom_recon_struct{interval = I, reconPid = comm:this(), exp_delta = ExpDelta,
                         bf = BF, item_count = MyMaxItems,
                         hf_count = HfCount, p1e = P1E},
    % Note: we can only guess the number of items of the initiator here, so
    %       this is not exactly the P1E of phase 1!
    %       (also we miss the returned BF's probability here)
     _P1E_p1 = bloom_worst_case_failprob(BF, InitiatorMaxItems, ExpDelta)};
build_recon_struct(merkle_tree, I, DBItems, _InitiatorMaxItems, Params) ->
    ?DBG_ASSERT(not intervals:is_empty(I)),
    P1E_p1 = 0.0, % needs to be set at the end of phase 1!
    case Params of
        {} ->
            % merkle_tree - at non-initiator!
            ?DBG_ASSERT(_InitiatorMaxItems =/= undefined),
            MOpts = [{branch_factor, get_merkle_branch_factor()},
                     {bucket_size, get_merkle_bucket_size()}],
            % do not build the real tree here - build during begin_sync so that
            % the initiator can start creating its struct earlier and in parallel
            % the actual build process is executed in begin_sync/2
            {merkle_tree:new(I, [{keep_bucket, true} | MOpts]), P1E_p1};
        #merkle_params{branch_factor = BranchFactor,
                       bucket_size = BucketSize,
                       num_trees = NumTrees} ->
            % merkle_tree - at initiator!
            ?DBG_ASSERT(_InitiatorMaxItems =:= undefined),
            MOpts = [{branch_factor, BranchFactor},
                     {bucket_size, BucketSize}],
            % build now
            RootsI = intervals:split(I, NumTrees),
            ICBList = merkle_tree:keys_to_intervals(DBItems, RootsI),
            {[merkle_tree:get_root(
               merkle_tree:new(SubI, Bucket, [{keep_bucket, true} | MOpts]))
               || {SubI, _Count, Bucket} <- ICBList], P1E_p1};
        #art_recon_struct{branch_factor = BranchFactor,
                          bucket_size = BucketSize} ->
            % ART at initiator
            MOpts = [{branch_factor, BranchFactor},
                     {bucket_size, BucketSize},
                     {leaf_hf, fun art:merkle_leaf_hf/2}],
            {merkle_tree:new(I, DBItems, [{keep_bucket, true} | MOpts]),
             P1E_p1 % TODO
            }
    end;
build_recon_struct(art, I, DBItems, _InitiatorMaxItems, _Params = {}) ->
    % ART at non-initiator
    ?DBG_ASSERT(not intervals:is_empty(I)),
    ?DBG_ASSERT(_InitiatorMaxItems =/= undefined),
    BranchFactor = get_merkle_branch_factor(),
    BucketSize = merkle_tree:get_opt_bucket_size(length(DBItems), BranchFactor, 1),
    Tree = merkle_tree:new(I, DBItems, [{branch_factor, BranchFactor},
                                        {bucket_size, BucketSize},
                                        {leaf_hf, fun art:merkle_leaf_hf/2},
                                        {keep_bucket, true}]),
    % create art struct:
    {#art_recon_struct{art = art:new(Tree, get_art_config()),
                       reconPid = comm:this(),
                       branch_factor = BranchFactor,
                       bucket_size = BucketSize},
     _P1E_p1 = 0.0 % TODO
    }.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% HELPER
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec send(Pid::comm:mypid(), Msg::comm:message() | comm:group_message()) -> ok.
send(Pid, Msg) ->
    ?TRACE_SEND(Pid, Msg),
    comm:send(Pid, Msg).

-spec send_local(Pid::comm:erl_local_pid(), Msg::comm:message() | comm:group_message()) -> ok.
send_local(Pid, Msg) ->
    ?TRACE_SEND(Pid, Msg),
    comm:send_local(Pid, Msg).

%% @doc Sends a get_chunk request to the local DHT_node process.
%%      Request responds with a list of {Key, Version, Value} tuples (if set
%%      for resolve) or {Key, Version} tuples (anything else).
%%      The mapping to DestI is not done here!
-spec send_chunk_req(DhtPid::LPid, AnswerPid::LPid, ChunkI::intervals:interval(),
                     MaxItems::pos_integer() | all) -> ok when
    is_subtype(LPid,        comm:erl_local_pid()).
send_chunk_req(DhtPid, SrcPid, I, MaxItems) ->
    SrcPidReply = comm:reply_as(SrcPid, 2, {process_db, '_'}),
    send_local(DhtPid,
               {get_chunk, SrcPidReply, I, fun get_chunk_filter/1,
                fun get_chunk_kv/1, MaxItems}).

-spec get_chunk_filter(db_entry:entry()) -> boolean().
get_chunk_filter(DBEntry) -> db_entry:get_version(DBEntry) =/= -1.
-spec get_chunk_kv(db_entry:entry()) -> {?RT:key(), client_version() | -1}.
get_chunk_kv(DBEntry) -> {db_entry:get_key(DBEntry), db_entry:get_version(DBEntry)}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec exit_reason_to_rc_status(exit_reason()) -> rr_recon_stats:status().
exit_reason_to_rc_status(sync_finished) -> finish;
exit_reason_to_rc_status(sync_finished_remote) -> finish;
exit_reason_to_rc_status(_) -> abort.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Maps any key (K) into a given interval (I). If K is already in I, K is returned.
%%      If K has more than one associated key in I, the closest one is returned.
%%      If all associated keys of K are not in I, none is returned.
-spec map_key_to_interval(?RT:key(), intervals:interval()) -> ?RT:key() | none.
map_key_to_interval(Key, I) ->
    RGrp = [K || K <- ?RT:get_replica_keys(Key), intervals:in(K, I)],
    case RGrp of
        [] -> none;
        [R] -> R;
        [H|T] ->
            element(1, lists:foldl(fun(X, {_KeyIn, DistIn} = AccIn) ->
                                           DistX = key_dist(X, Key),
                                           if DistX < DistIn -> {X, DistX};
                                              true -> AccIn
                                           end
                                   end, {H, key_dist(H, Key)}, T))
    end.

-compile({inline, [key_dist/2]}).

-spec key_dist(Key1::?RT:key(), Key2::?RT:key()) -> number().
key_dist(Key, Key) -> 0;
key_dist(Key1, Key2) ->
    Dist1 = ?RT:get_range(Key1, Key2),
    Dist2 = ?RT:get_range(Key2, Key1),
    erlang:min(Dist1, Dist2).

%% @doc Maps an abitrary key to its associated key in replication quadrant Q.
-spec map_key_to_quadrant(?RT:key(), rt_beh:segment()) -> ?RT:key().
map_key_to_quadrant(Key, Q) ->
    RKeys = ?RT:get_replica_keys(Key),
    map_rkeys_to_quadrant(RKeys, Q).

%% @doc Returns a key in the given replication quadrant Q from a list of
%%      replica keys.
-spec map_rkeys_to_quadrant([?RT:key(),...], rt_beh:segment()) -> ?RT:key().
map_rkeys_to_quadrant(RKeys, Q) ->
    SegM = case lists:member(?MINUS_INFINITY, RKeys) of
               true -> Q rem config:read(replication_factor) + 1;
               _ -> Q
           end,
    hd(lists:dropwhile(fun(K) -> ?RT:get_key_segment(K) =/= SegM end, RKeys)).

%% @doc Gets the quadrant intervals.
-spec quadrant_intervals() -> [intervals:non_empty_interval(),...].
quadrant_intervals() ->
    case ?RT:get_replica_keys(?MINUS_INFINITY) of
        [_]               -> [intervals:all()];
        [HB,_|_] = Borders -> quadrant_intervals_(Borders, [], HB)
    end.

%% @doc Internal helper for quadrant_intervals/0 - keep in sync with
%%      map_key_to_quadrant/2!
%%      PRE: keys in Borders and HB must be unique (as created in quadrant_intervals/0)!
%% TODO: use intervals:new('[', A, B, ')') instead so ?MINUS_INFINITY is in quadrant 1?
%%       -> does not fit ranges that well as they are normally defined as (A,B]
-spec quadrant_intervals_(Borders::[?RT:key(),...], ResultIn::[intervals:non_empty_interval()],
                          HeadB::?RT:key()) -> [intervals:non_empty_interval(),...].
quadrant_intervals_([K], Res, HB) ->
    lists:reverse(Res, [intervals:new('(', K, HB, ']')]);
quadrant_intervals_([A | [B | _] = TL], Res, HB) ->
    quadrant_intervals_(TL, [intervals:new('(', A, B, ']') | Res], HB).

%% @doc Gets all sub intervals of the given interval which lay only in
%%      a single quadrant.
-spec quadrant_subints_(A::intervals:interval(), Quadrants::[intervals:interval()],
                        AccIn::[intervals:interval()]) -> AccOut::[intervals:interval()].
quadrant_subints_(_A, [], Acc) -> Acc;
quadrant_subints_(A, [Q | QT], Acc) ->
    Sec = intervals:intersection(A, Q),
    case intervals:is_empty(Sec) of
        false when Sec =:= Q ->
            % if a quadrant is completely covered, only return this
            % -> this would reconcile all the other keys, too!
            % it also excludes non-continuous intervals
            [Q];
        false -> quadrant_subints_(A, QT, [Sec | Acc]);
        true  -> quadrant_subints_(A, QT, Acc)
    end.

%% @doc Gets all replicated intervals of I.
%%      PreCond: interval (I) is continuous and is inside a single quadrant!
-spec replicated_intervals(intervals:continuous_interval())
        -> [intervals:continuous_interval()].
replicated_intervals(I) ->
    ?DBG_ASSERT(intervals:is_continuous(I)),
    ?DBG_ASSERT(1 =:= length([ok || Q <- quadrant_intervals(),
                                not intervals:is_empty(
                                  intervals:intersection(I, Q))])),
    case intervals:is_all(I) of
        false ->
            case intervals:get_bounds(I) of
                {_LBr, ?MINUS_INFINITY, ?PLUS_INFINITY, _RBr} ->
                    [I]; % this is the only interval possible!
                {'[', Key, Key, ']'} ->
                    [intervals:new(X) || X <- ?RT:get_replica_keys(Key)];
                {LBr, LKey, RKey0, RBr} ->
                    LKeys = lists:sort(?RT:get_replica_keys(LKey)),
                    % note: get_bounds may also return ?PLUS_INFINITY but this is not a valid key in ?RT!
                    RKey = ?IIF(RKey0 =:= ?PLUS_INFINITY, ?MINUS_INFINITY, RKey0),
                    RKeys = case lists:sort(?RT:get_replica_keys(RKey)) of
                                [?MINUS_INFINITY | RKeysTL] ->
                                    lists:append(RKeysTL, [?MINUS_INFINITY]);
                                X -> X
                            end,
                    % since I is in a single quadrant, RKey >= LKey
                    % -> we can zip the sorted keys to get the replicated intervals
                    lists:zipwith(
                      fun(LKeyX, RKeyX) ->
                              % this debug statement only holds for replication factors that are a power of 2:
%%                               ?DBG_ASSERT(?RT:get_range(LKeyX, ?IIF(RKeyX =:= ?MINUS_INFINITY, ?PLUS_INFINITY, RKeyX)) =:=
%%                                           ?RT:get_range(LKey, RKey0)),
                              intervals:new(LBr, LKeyX, RKeyX, RBr)
                      end, LKeys, RKeys)
            end;
        true -> [I]
    end.

%% @doc Gets a randomly selected sync interval as an intersection of the two
%%      given intervals as a sub interval of A inside a single quadrant.
%%      Result may be empty, otherwise it is also continuous!
-spec find_sync_interval(intervals:continuous_interval(), intervals:continuous_interval())
        -> intervals:interval().
find_sync_interval(A, B) ->
    ?DBG_ASSERT(intervals:is_continuous(A)),
    ?DBG_ASSERT(intervals:is_continuous(B)),
    Quadrants = quadrant_intervals(),
    InterSecs = [I || AQ <- quadrant_subints_(A, Quadrants, []),
                      BQ <- quadrant_subints_(B, Quadrants, []),
                      RBQ <- replicated_intervals(BQ),
                      not intervals:is_empty(
                        I = intervals:intersection(AQ, RBQ))],
    case InterSecs of
        [] -> intervals:empty();
        [_|_] -> util:randomelem(InterSecs)
    end.

%% @doc Maps interval B into interval A.
%%      PreCond: the second (continuous) interval must be in a single quadrant!
%%      The result is thus also only in a single quadrant.
%%      Result may be empty, otherwise it is also continuous!
-spec map_interval(intervals:continuous_interval(), intervals:continuous_interval())
        -> intervals:interval().
map_interval(A, B) ->
    ?DBG_ASSERT(intervals:is_continuous(A)),
    ?DBG_ASSERT(intervals:is_continuous(B)),
    ?DBG_ASSERT(1 =:= length([ok || Q <- quadrant_intervals(),
                                not intervals:is_empty(
                                  intervals:intersection(B, Q))])),
    
    % note: The intersection may only be non-continuous if A is covering more
    %       than a quadrant. In this case, another intersection will be larger
    %       and we can safely ignore this one!
    InterSecs = [I || RB <- replicated_intervals(B),
                      not intervals:is_empty(
                        I = intervals:intersection(A, RB)),
                      intervals:is_continuous(I)],
    case InterSecs of
        [] -> intervals:empty();
        [_|_] -> util:randomelem(InterSecs)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% STARTUP
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc init module
-spec init(state()) -> state().
init(State) ->
    _ = gen_component:monitor(State#rr_recon_state.ownerPid),
    State.

-spec start(SessionId::rrepair:session_id(), SenderRRPid::comm:mypid())
        -> {ok, pid()}.
start(SessionId, SenderRRPid) ->
    State = #rr_recon_state{ ownerPid = self(),
                             dest_rr_pid = SenderRRPid,
                             stats = rr_recon_stats:new(SessionId) },
    PidName = lists:flatten(io_lib:format("~s_~p.~s", [?MODULE, SessionId, randoms:getRandomString()])),
    gen_component:start_link(?MODULE, fun ?MODULE:on/2, State,
                             [{pid_groups_join_as, pid_groups:my_groupname(),
                               {short_lived, PidName}}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Config parameter handling
%
% rr_recon_p1e              - probability of a single false positive,
%                             i.e. false positive absolute count
% rr_art_inner_fpr          - 
% rr_art_leaf_fpr           -  
% rr_art_correction_factor  - 
% rr_merkle_branch_factor   - merkle tree branching factor thus number of childs per node
% rr_merkle_bucket_size     - size of merkle tree leaf buckets
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Checks whether a config parameter is float and in [0,1].
-spec check_percent(atom()) -> boolean().
check_percent(Atom) ->
    config:cfg_is_float(Atom) andalso
        config:cfg_is_greater_than(Atom, 0) andalso
        config:cfg_is_less_than(Atom, 1).

%% @doc Checks whether config parameters exist and are valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_in(rr_recon_method, [trivial, shash, bloom, merkle_tree, art]) andalso
        config:cfg_is_float(rr_recon_p1e) andalso
        config:cfg_is_greater_than(rr_recon_p1e, 0) andalso
        config:cfg_is_less_than_equal(rr_recon_p1e, 1) andalso
        config:cfg_is_number(rr_recon_expected_delta) andalso
        config:cfg_is_in_range(rr_recon_expected_delta, 0, 100) andalso
        config:cfg_test_and_error(rr_recon_version_bits,
                                  fun(variable) -> true;
                                     (X) -> erlang:is_integer(X) andalso X > 0
                                  end, "is not 'variable' or an integer > 0"),
        config:cfg_test_and_error(rr_max_items,
                                  fun(all) -> true;
                                     (X) -> erlang:is_integer(X) andalso X > 0
                                  end, "is not 'all' or an integer > 0"),
        config:cfg_is_integer(rr_recon_min_sig_size) andalso
        config:cfg_is_greater_than(rr_recon_min_sig_size, 0) andalso
        config:cfg_is_integer(rr_merkle_branch_factor) andalso
        config:cfg_is_greater_than(rr_merkle_branch_factor, 1) andalso
        config:cfg_is_integer(rr_merkle_bucket_size) andalso
        config:cfg_is_greater_than(rr_merkle_bucket_size, 0) andalso
        config:cfg_is_integer(rr_merkle_num_trees) andalso
        config:cfg_is_greater_than(rr_merkle_num_trees, 0) andalso
        check_percent(rr_art_inner_fpr) andalso
        check_percent(rr_art_leaf_fpr) andalso
        config:cfg_is_integer(rr_art_correction_factor) andalso
        config:cfg_is_greater_than(rr_art_correction_factor, 0).

-spec get_p1e() -> float().
get_p1e() ->
    config:read(rr_recon_p1e).

%% @doc Specifies what the maximum expected delta is (in percent between 0 and
%%      100, inclusive). The failure probabilities will take this into account.
-spec get_max_expected_delta() -> number().
get_max_expected_delta() ->
    config:read(rr_recon_expected_delta).

%% @doc Use at least these many bits for compressed version numbers.
-spec get_min_version_bits() -> pos_integer() | variable.
get_min_version_bits() ->
    config:read(rr_recon_version_bits).

%% @doc Use at least these many bits for hashes.
-spec get_min_hash_bits() -> pos_integer().
get_min_hash_bits() ->
    config:read(rr_recon_min_sig_size).

%% @doc Specifies how many items to retrieve from the DB at once.
%%      Tries to reduce the load of a single request in the dht_node process.
-spec get_max_items() -> pos_integer() | all.
get_max_items() ->
    config:read(rr_max_items).

%% @doc Merkle number of childs per inner node.
-spec get_merkle_branch_factor() -> pos_integer().
get_merkle_branch_factor() ->
    config:read(rr_merkle_branch_factor).

%% @doc Merkle number of childs per inner node.
-spec get_merkle_num_trees() -> pos_integer().
get_merkle_num_trees() ->
    config:read(rr_merkle_num_trees).

%% @doc Merkle max items in a leaf node.
-spec get_merkle_bucket_size() -> pos_integer().
get_merkle_bucket_size() ->
    config:read(rr_merkle_bucket_size).

-spec get_art_config() -> art:config().
get_art_config() ->
    [{correction_factor, config:read(rr_art_correction_factor)},
     {inner_bf_fpr, config:read(rr_art_inner_fpr)},
     {leaf_bf_fpr, config:read(rr_art_leaf_fpr)}].

-spec tester_create_kvi_tree(
        [{KeyShort::non_neg_integer(),
          {VersionShort::non_neg_integer(), Idx::non_neg_integer()}}]) -> kvi_tree().
tester_create_kvi_tree(KVList) ->
    mymaps:from_list(KVList).

-spec tester_is_kvi_tree(Map::any()) -> boolean().
tester_is_kvi_tree(Map) ->
    try mymaps:to_list(Map) of
        KVList -> lists:all(fun({K, {V, Idx}}) when is_integer(K) andalso K >= 0
                                 andalso is_integer(V) andalso V >= 0
                                 andalso is_integer(Idx) andalso Idx >= 0 ->
                                    true;
                               ({_, _}) ->
                                    false
                            end, KVList)
    catch _:_ -> false % probably no map
    end.
