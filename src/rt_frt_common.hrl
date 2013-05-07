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

%% @author Magnus Mueller <mamuelle@informatik.hu-berlin.de>
%% @doc Flexible routing table. This header file is to be included by modules which want
%% to implement the RT behaviour and a flexible routing table.
%%
%%                   +-----------------------+
%%                   |    RT Behaviour       |
%%                   +-----------------------+
%%                              ^
%%                              |
%%                              |
%%                   +----------+------------+
%%             +---->|    FRT Common Header |<------+
%%             |     +----------------------+       |
%%             |                                    |
%%    +--------+--------+                   +-------+---------+
%%    |    FRTChord     |                   |    GFRTChord    |
%%    +-----------------+                   +-----------------+
%%
%% @end
%% @version $Id$
-author('mamuelle@informatik.hu-berlin.de').
-behaviour(rt_beh).

-export([dump_to_csv/1, get_source_id/1, get_source_node/1]).

% exports for unit tests
-export([check_rt_integrity/1, check_well_connectedness/1, get_random_key_from_generator/3]).

%% Make dialyzer stop complaining about unused functions

% The following functions are only used when ?RT == rt_frtchord. Dialyzer should not
% complain when they are not called.
-export([get_num_active_learning_lookups/1,
         set_num_active_learning_lookups/2,
         inc_num_active_learning_lookups/1]).
-export([rt_entry_distance/2, rt_entry_id/1, set_custom_info/2, get_custom_info/1]).

% Functions which are to be implemented in modules including this header
-export([allowed_nodes/1, frt_check_config/0, rt_entry_info/4]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% RT Implementation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type key_t() :: 0..16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF. % 128 bit numbers
-type external_rt_t() :: gb_tree().

% define the possible types of nodes in the routing table:
%  - normal nodes are nodes which have been added by entry learning
%  - source is the node at which this RT is
%  - sticky is a node which is not to be deleted with entry filtering
-type entry_type() :: normal | source | sticky.
-type custom_info() :: undefined | term().

-record(rt_entry, {
        node :: node:node_type(),
        type :: entry_type(),
        adjacent_fingers = {undefined, undefined} :: {key_t() |
                                                        'undefined', key_t() |
                                                        'undefined'},
        custom = undefined :: custom_info()
    }).

-type(rt_entry() :: #rt_entry{}).
-ifdef(with_export_type_support).
-export_type([rt_entry/0]).
-endif.

-record(rt_t, {
        source = undefined :: key_t() | undefined
        , num_active_learning_lookups = 0 :: non_neg_integer()
        , nodes = gb_trees:empty() :: gb_tree()
    }).

-type(rt_t() :: #rt_t{}).

-type custom_message() :: {get_rt, SourcePID :: comm:mypid()}
                        | {get_rt_reply, RT::rt_t()}
                        | {trigger_random_lookup}
                        | {rt_get_node, From :: comm:mypid()}
                        | {rt_learn_node, NewNode :: node:node_type()}
                        .

-include("scalaris.hrl").
-include("rt_beh.hrl").

% @doc Maximum number of entries in a routing table
-spec maximum_entries() -> non_neg_integer().
maximum_entries() -> config:read(rt_frt_max_entries).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Key Handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% @doc Initialize the routing table. This function is allowed to send messages.
-spec init(nodelist:neighborhood()) -> rt().
init(Neighbors) ->
    % trigger a random lookup after initializing the table
    case config:read(rt_frtchord_al) of
        true -> comm:send_local(self(), {trigger_random_lookup});
        false -> ok
    end,
    % ask the successor node for its routing table
    Msg = {?send_to_group_member, routing_table, {get_rt, comm:this()}},
    comm:send(node:pidX(nodelist:succ(Neighbors)), Msg),
    update_entries(Neighbors, add_source_entry(nodelist:node(Neighbors), #rt_t{})).

%% @doc Hashes the key to the identifier space.
-spec hash_key(client_key() | binary()) -> key().
hash_key(Key) -> hash_key_(Key).

%% @doc Hashes the key to the identifier space (internal function to allow
%%      use in e.g. get_random_node_id without dialyzer complaining about the
%%      opaque key type).
-spec hash_key_(client_key() | binary()) -> key_t().
hash_key_(Key) ->
    <<N:128>> = crypto:md5(client_key_to_binary(Key)),
    N.
%% userdevguide-end rt_frtchord:hash_key

%% userdevguide-begin rt_frtchord:get_random_node_id
%% @doc Generates a random node id, i.e. a random 128-bit number.
-spec get_random_node_id() -> key().
get_random_node_id() ->
    case config:read(key_creator) of
        random -> hash_key_(randoms:getRandomString());
        random_with_bit_mask ->
            {Mask1, Mask2} = config:read(key_creator_bitmask),
            (hash_key_(randoms:getRandomString()) band Mask2) bor Mask1
    end.
%% userdevguide-end rt_frtchord:get_random_node_id

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% RT Management
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% userdevguide-begin rt_frtchord:init_stabilize
%% @doc Triggered by a new stabilization round, renews the routing table.
%% Check:
%% - if node id changed, just renew the complete table and maybe tell known nodes
%%  that something changed (async and optimistic -> if they don't care, we don't care)
%% - if pred/succ changed, update sticky entries
-spec init_stabilize(nodelist:neighborhood(), rt()) -> rt().
init_stabilize(Neighbors, RT) -> 
    case node:id(nodelist:node(Neighbors)) =:= entry_nodeid(get_source_node(RT)) of
        true -> update_entries(Neighbors, RT) ;
        false -> % source node changed, replace the complete table
            init(Neighbors)
    end
    .


%% userdevguide-end rt_frtchord:init_stabilize

% Get the adjacent nodes. The source node is filtered.
-spec get_node_neighbors(nodelist:neighborhood()) -> set().
get_node_neighbors(Neighborhood) ->
    Source = nodelist:node(Neighborhood),
    % filter the source node and add other nodes to a set
    Filter = fun(Entry, Acc) -> case Entry of
                Source -> Acc;
                _Else -> sets:add_element(Entry, Acc) end
    end,

    lists:foldl(Filter,
        lists:foldl(Filter, sets:new(),
            nodelist:preds(Neighborhood)),
        nodelist:succs(Neighborhood))
    .

%% @doc Update sticky entries
%% This function converts sticky nodes from the RT which aren't in the neighborhood
%% anymore to normal nodes. Afterwards it adds new nodes from the neighborhood.
-spec update_entries(NewNeighbors :: nodelist:neighborhood(),
                              RT :: rt()) -> rt().
update_entries(NewNeighbors, RT) ->
    OldStickyNodes = sets:from_list(lists:map(fun rt_entry_node/1,
            get_sticky_entries(RT))),
    NewStickyNodes = get_node_neighbors(NewNeighbors),

    ConvertNodes = sets:subtract(OldStickyNodes, NewStickyNodes),
    ConvertNodesIds = util:sets_map(fun node:id/1, ConvertNodes),

    ToBeAddedNodes = sets:subtract(NewStickyNodes, ConvertNodes),

    % convert former neighboring nodes to normal nodes and add sticky nodes
    FilteredRT = lists:foldl(fun sticky_entry_to_normal_node/2, RT, ConvertNodesIds),
    NewRT = sets:fold(fun add_sticky_entry/2, FilteredRT, ToBeAddedNodes),
    check_helper(RT, NewRT, true),
    NewRT
    .

%% userdevguide-begin rt_frtchord:update
%% @doc Updates the routing table due to a changed node ID, pred and/or succ.
%% - We must rebuild the complete routing table when the source node id changed
%% - If only the preds/succs changed, adapt the old routing table
-spec update(OldRT::rt(), OldNeighbors::nodelist:neighborhood(),
    NewNeighbors::nodelist:neighborhood()) -> {trigger_rebuild, rt()} | {ok, rt()}.
update(OldRT, Neighbors, Neighbors) -> {ok, OldRT};
update(OldRT, OldNeighbors, NewNeighbors) ->
    case nodelist:node(OldNeighbors) =:= nodelist:node(NewNeighbors) of
        true -> % source node didn't change
            % update the sticky nodes: delete old nodes and add new nodes
            {ok, update_entries(NewNeighbors, OldRT)}
            ;
        _Else -> % source node changed, rebuild the complete table
            {trigger_rebuild, OldRT}
    end
    .
%% userdevguide-end rt_frtchord:update

%% userdevguide-begin rt_frtchord:filter_dead_node
%% @doc Removes dead nodes from the routing table (rely on periodic
%%      stabilization here).
-spec filter_dead_node(rt(), comm:mypid()) -> rt().
filter_dead_node(RT, DeadPid) -> 
    % find the node id of DeadPid and delete it from the RT
    case [N || N <- internal_to_list(RT), node:pidX(N) =:= DeadPid] of
        [Node] -> entry_delete(node:id(Node), RT);
        [] -> RT
    end
    .
%% userdevguide-end rt_frtchord:filter_dead_node

%% userdevguide-begin rt_frtchord:to_pid_list
%% @doc Returns the pids of the routing table entries.
-spec to_pid_list(rt()) -> [comm:mypid()].
to_pid_list(RT) -> [node:pidX(N) || N <- internal_to_list(RT)].
%% userdevguide-end rt_frtchord:to_pid_list

%% @doc Get the size of the RT excluding entries which are not tagged as normal entries.
-spec get_size_without_special_nodes(rt()) -> non_neg_integer().
get_size_without_special_nodes(#rt_t{} = RT) ->
    util:gb_trees_foldl(
        fun(_Key, Val, Acc) ->
                Acc + case entry_type(Val) of
                    normal -> 1;
                    _else -> 0
                end
        end, 0, get_rt_tree(RT)).

%% userdevguide-begin rt_frtchord:get_size
%% @doc Returns the size of the routing table.
-spec get_size(rt() | external_rt()) -> non_neg_integer().
get_size(#rt_t{} = RT) -> gb_trees:size(get_rt_tree(RT));
get_size(RT) -> gb_trees:size(RT). % size of external rt
%% userdevguide-end rt_frtchord:get_size

%% userdevguide-begin rt_frtchord:n
%% @doc Returns the size of the address space.
-spec n() -> integer().
n() -> n_().
%% @doc Helper for n/0 to make dialyzer happy with internal use of n/0.
-spec n_() -> 16#100000000000000000000000000000000.
n_() -> 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1.
%% userdevguide-end rt_frtchord:n

%% @doc Keep a key in the address space. See n/0.
-spec normalize(Key::key_t()) -> key_t().
normalize(Key) -> Key band 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF.

%% @doc Gets the number of keys in the interval (Begin, End]. In the special
%%      case of Begin==End, the whole key range as specified by n/0 is returned.
-spec get_range(Begin::key(), End::key() | ?PLUS_INFINITY_TYPE) -> number().
get_range(Begin, End) -> get_range_(Begin, End).

%% @doc Helper for get_range/2 to make dialyzer happy with internal use of
%%      get_range/2 in the other methods, e.g. get_split_key/3.
-spec get_range_(Begin::key_t(), End::key_t() | ?PLUS_INFINITY_TYPE) -> number().
get_range_(Begin, Begin) -> n_(); % I am the only node
get_range_(?MINUS_INFINITY, ?PLUS_INFINITY) -> n_(); % special case, only node
get_range_(Begin, End) when End > Begin -> End - Begin;
get_range_(Begin, End) when End < Begin -> (n_() - Begin) + End.

%% @doc Gets the key that splits the interval (Begin, End] so that the first
%%      interval will be (Num/Denom) * range(Begin, End). In the special case of
%%      Begin==End, the whole key range is split.
%%      Beware: SplitFactor must be in [0, 1]; the final key will be rounded
%%      down and may thus be Begin.
-spec get_split_key(Begin::key(), End::key() | ?PLUS_INFINITY_TYPE,
                    SplitFraction::{Num::non_neg_integer(), Denom::pos_integer()}) -> key().
get_split_key(Begin, _End, {Num, _Denom}) when Num == 0 -> Begin;
get_split_key(_Begin, End, {Num, Denom}) when Num == Denom -> End;
get_split_key(Begin, End, {Num, Denom}) ->
    normalize(Begin + (get_range_(Begin, End) * Num) div Denom).

%% userdevguide-begin rt_frtchord:get_replica_keys
%% @doc Returns the replicas of the given key.
-spec get_replica_keys(key()) -> [key()].
get_replica_keys(Key) ->
    [Key,
     Key bxor 16#40000000000000000000000000000000,
     Key bxor 16#80000000000000000000000000000000,
     Key bxor 16#C0000000000000000000000000000000
    ].
%% userdevguide-end rt_frtchord:get_replica_keys

-spec get_key_segment(key()) -> pos_integer().
get_key_segment(Key) ->
    (Key bsr 126) + 1.

%% userdevguide-begin rt_frtchord:dump
%% @doc Dumps the RT state for output in the web interface.
-spec dump(RT::rt()) -> KeyValueList::[{Index::string(), Node::string()}].
dump(RT) -> [{"0", webhelpers:safe_html_string("~p", [RT])}].
%% userdevguide-end rt_frtchord:dump

% @doc Dump the routing table into a CSV string
-spec dump_to_csv(RT :: rt()) -> [char()].
dump_to_csv(RT) ->
    Fingers = internal_to_list(RT),
    IndexedFingers = lists:zip(lists:seq(1,length(Fingers)), Fingers),
    MyId = get_source_id(RT),
    lists:flatten(
        [
            "Finger,Id\n"
            , io_lib:format("0,~p~n", [MyId])
        ] ++
        [
            io_lib:format("~p,~p~n",[Index,node:id(Finger)])
            || {Index, Finger} <- IndexedFingers
        ]
    )
    .


%% @doc Checks whether config parameters of the rt_frtchord process exist and are
%%      valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_in(key_creator, [random, random_with_bit_mask]) and
        case config:read(key_creator) of
            random -> true;
            random_with_bit_mask ->
                config:cfg_is_tuple(key_creator_bitmask, 2,
                                fun({Mask1, Mask2}) ->
                                        erlang:is_integer(Mask1) andalso
                                            erlang:is_integer(Mask2) end,
                                "{int(), int()}");
            _ -> false
        end and
    config:cfg_is_bool(rt_frtchord_al) and
    config:cfg_is_greater_than_equal(rt_frtchord_al_interval, 0) and
    config:cfg_is_integer(rt_frt_max_entries) and
    config:cfg_is_greater_than(rt_frt_max_entries, 0) and
    frt_check_config()
    .

%% @doc Generate a random key from the pdf as defined in (Nagao, Shudo, 2011)
%% TODO I floor the key for now; the key generator should return ints, but returns
%float. It is currently unclear if this is a bug in the original paper by Nagao and
%Shudo. Using erlang:trunc/1 should be enough for flooring, as X >= 0
% TODO using the remainder might destroy the CDF. why can X > 2^128?
-spec get_random_key_from_generator(SourceNodeId :: key(),
                                    PredId :: key(),
                                    SuccId :: key()
                                   ) -> key().
get_random_key_from_generator(SourceNodeId, PredId, SuccId) ->
    Rand = random:uniform(),
    X = SourceNodeId + get_range(SourceNodeId, SuccId) *
        math:pow(get_range(SourceNodeId, PredId) /
                    get_range(SourceNodeId, SuccId),
                    Rand
                ),
    erlang:trunc(X) rem n()
    .

%% userdevguide-begin rt_frtchord:handle_custom_message
%% @doc Handle custom messages. The following messages can occur:
%%      - TODO explain messages

% send the RT to a node asking for it
-spec handle_custom_message(custom_message(), rt_loop:state_active()) ->
                                   rt_loop:state_active() | unknown_event.
handle_custom_message({get_rt, Pid}, State) ->
    comm:send(Pid, {get_rt_reply, rt_loop:get_rt(State)}),
    State
    ;

handle_custom_message({get_rt_reply, RT}, State) ->
    %% merge the routing tables. Note: We don't care if this message is not from our
    %current successor. We just have to make sure that the merged entries are valid.
    OldRT = rt_loop:get_rt(State),
    NewRT = case OldRT =/= RT of
        true ->
            % - add each entry from the other RT if it doesn't already exist
            % - entries to be added have to be normal entries as RM invokes adding sticky
            % nodes
            util:gb_trees_foldl(
                fun(Key, Entry, Acc) ->
                        case entry_exists(Key, Acc) of
                            true -> Acc;
                            false -> add_normal_entry(rt_entry_node(Entry), Acc)
                        end
                end,
                OldRT, get_rt_tree(RT));

        false -> OldRT
    end,
    ?RT:check(OldRT, NewRT, rt_loop:get_neighb(State), true),
    rt_loop:set_rt(State, NewRT);

% lookup a random key chosen with a pdf:
% x = sourcenode + d(s,succ)*(d(s,pred)/d(s,succ))^rnd
% where rnd is chosen uniformly from [0,1)
handle_custom_message({trigger_random_lookup}, State) ->
    RT = rt_loop:get_rt(State),
    SourceNode = ?RT:get_source_node(RT),
    SourceNodeId = entry_nodeid(SourceNode),
    {PredId, SuccId} = adjacent_fingers(SourceNode),
    Key = get_random_key_from_generator(SourceNodeId, PredId, SuccId),

    % schedule the next random lookup
    Interval = config:read(rt_frtchord_al_interval),
    msg_delay:send_local(Interval, self(), {trigger_random_lookup}),

    api_dht_raw:unreliable_lookup(Key, {?send_to_group_member, routing_table,
                                        {rt_get_node, comm:this()}}),
    State
    ;

handle_custom_message({rt_get_node, From}, State) ->
    MyNode = nodelist:node(rt_loop:get_neighb(State)),
    comm:send(From, {rt_learn_node, MyNode}),
    State
    ;

handle_custom_message({rt_learn_node, NewNode}, State) ->
    OldRT = rt_loop:get_rt(State),
    NewRT = case ?RT:rt_lookup_node(node:id(NewNode), OldRT) of
        none -> RT = ?RT:add_normal_entry(NewNode, OldRT),
                ?RT:check(OldRT, RT, rt_loop:get_neighb(State), true),
                RT
            ;
        {value, _RTEntry} -> OldRT
    end,
    rt_loop:set_rt(State, NewRT)
    ;

handle_custom_message(_Message, _State) -> unknown_event.
%% userdevguide-end rt_frtchord:handle_custom_message

%% userdevguide-begin rt_frtchord:check
%% @doc Notifies the dht_node and failure detector if the routing table changed.
%%      Provided for convenience (see check/5).
-spec check(OldRT::rt(), NewRT::rt(), Neighbors::nodelist:neighborhood(),
            ReportToFD::boolean()) -> ok.
check(OldRT, NewRT, Neighbors, ReportToFD) ->
    check(OldRT, NewRT, Neighbors, Neighbors, ReportToFD).

%% @doc Notifies the dht_node if the (external) routing table changed.
%%      Also updates the failure detector if ReportToFD is set.
%%      Note: the external routing table only changes if the internal RT has
%%      changed.
-spec check(OldRT::rt(), NewRT::rt(), OldNeighbors::nodelist:neighborhood(),
            NewNeighbors::nodelist:neighborhood(), ReportToFD::boolean()) -> ok.
check(OldRT, NewRT, OldNeighbors, NewNeighbors, ReportToFD) ->
    % if the routing tables haven't changed and the successor/predecessor haven't changed
    % as well, do nothing
    case OldRT =:= NewRT andalso 
         nodelist:succ(OldNeighbors) =:= nodelist:succ(NewNeighbors) andalso
         nodelist:pred(OldNeighbors) =:= nodelist:pred(NewNeighbors) of
        true -> ok;
        _Else -> export_to_dht(NewRT, ReportToFD)
    end.

% @doc Helper to send the new routing table to the dht node
-spec export_to_dht(rt(), ReportToFD :: boolean()) -> ok.
export_to_dht(NewRT, ReportToFD) ->
    Pid = pid_groups:get_my(dht_node),
    case Pid of
        failed -> ok;
        _E     ->
            RTExt = export_rt_to_dht_node_helper(NewRT),
            comm:send_local(Pid, {rt_update, RTExt})
    end,
    % update failure detector:
    case ReportToFD of
        true -> add_fd(NewRT);
        _Else -> ok
    end,
    ok
    .

% @doc Helper to check for routing table changes, excluding changes to the neighborhood.
-spec check_helper(OldRT :: rt(), NewRT :: rt(), ReportToFD :: boolean()) -> ok.
check_helper(OldRT, NewRT, ReportToFD) ->
    case OldRT =:= NewRT
    of
        true -> ok;
        false -> export_to_dht(NewRT, ReportToFD)
    end.

%% @doc Filter the source node's pid from a list.
-spec filter_source_pid(rt(), [comm:mypid()]) -> [comm:mypid()].
filter_source_pid(RT, ListOfPids) ->
    SourcePid = node:pidX(rt_entry_node(get_source_node(RT))),
    [P || P <- ListOfPids, P =/= SourcePid].

%% @doc Set up a set of subscriptions from a routing table
-spec add_fd(RT :: rt())  -> ok.
add_fd(#rt_t{} = RT) ->
    NewPids = to_pid_list(RT),
    % Filter the source node from the Pids, as we don't need an FD for that node. If the
    % source node crashes (which is the process calling this function), we are done
    % for.
    fd:subscribe(filter_source_pid(RT, NewPids)).

%% @doc Update subscriptions
-spec update_fd(OldRT :: rt(), NewRT :: rt()) -> ok.
update_fd(OldRT, OldRT) -> ok;
update_fd(#rt_t{} = OldRT, #rt_t{} = NewRT) ->
    OldPids = filter_source_pid(OldRT, to_pid_list(OldRT)),
    NewPids = filter_source_pid(NewRT, to_pid_list(NewRT)),
    fd:update_subscriptions(OldPids, NewPids).

%% userdevguide-end rt_frtchord:check

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Communication with dht_node
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% userdevguide-begin rt_frtchord:empty_ext
-spec empty_ext(nodelist:neighborhood()) -> external_rt().
empty_ext(_Neighbors) -> gb_trees:empty().
%% userdevguide-end rt_frtchord:empty_ext

%% userdevguide-begin rt_frtchord:next_hop
%% @doc Returns the next hop to contact for a lookup.
-spec next_hop(dht_node_state:state(), key()) -> comm:mypid().
next_hop(State, Id) ->
    Neighbors = dht_node_state:get(State, neighbors),
    case intervals:in(Id, nodelist:succ_range(Neighbors)) of
        true -> node:pidX(nodelist:succ(Neighbors));
        _ ->
            % check routing table:
            RT = dht_node_state:get(State, rt),
            RTSize = get_size(RT),
            NodeRT = case util:gb_trees_largest_smaller_than(Id, RT) of
                {value, _Key, N} -> N;
                nil when RTSize =:= 0 -> nodelist:succ(Neighbors);
                nil -> % forward to largest finger
                    {_Key, N} = gb_trees:largest(RT),
                    N
            end,
            FinalNode =
                case RTSize < config:read(rt_size_use_neighbors) of
                    false -> NodeRT;
                    _     -> % check neighborhood:
                             nodelist:largest_smaller_than(Neighbors, Id, NodeRT)
                end,
            node:pidX(FinalNode)
    end.
%% userdevguide-end rt_frtchord:next_hop

%% userdevguide-begin rt_frtchord:export_rt_to_dht_node
%% @doc Converts the internal RT to the external RT used by the dht_node.
%% The external routing table is optimized to speed up ?RT:next_hop/2. For this, it is
%%  only a gb_tree with keys being node ids and values being of type node:node_type().
-spec export_rt_to_dht_node_helper(rt()) -> external_rt().
export_rt_to_dht_node_helper(RT) ->
    % From each rt_entry, we extract only the field "node" and add it to the tree
    % under the node id. The source node is filtered.
    util:gb_trees_foldl(
        fun(_K, V, Acc) ->
                case entry_type(V) of
                    source -> Acc;
                    _Else -> Node = rt_entry_node(V),
                        gb_trees:enter(node:id(Node), Node, Acc)
                end
        end, gb_trees:empty(),get_rt_tree(RT)).

-spec export_rt_to_dht_node(rt(), Neighbors::nodelist:neighborhood()) -> external_rt().
export_rt_to_dht_node(RT, _Neighbors) ->
    export_rt_to_dht_node_helper(RT).
%% userdevguide-end rt_frtchord:export_rt_to_dht_node

%% userdevguide-begin rt_frtchord:to_list
%% @doc Converts the external representation of the routing table to a list
%%      in the order of the fingers, i.e. first=succ, second=shortest finger,
%%      third=next longer finger,...
-spec to_list(dht_node_state:state()) -> nodelist:snodelist().
to_list(State) -> % match external RT
    RT = dht_node_state:get(State, rt),
    Neighbors = dht_node_state:get(State, neighbors),
    nodelist:mk_nodelist([nodelist:succ(Neighbors) | gb_trees:values(RT)],
        nodelist:node(Neighbors))
    .

%% @doc Converts the internal representation of the routing table to a list
%%      in the order of the fingers, i.e. first=succ, second=shortest finger,
%%      third=next longer finger,...
-spec internal_to_list(rt()) -> nodelist:snodelist().
internal_to_list(#rt_t{} = RT) ->
    SourceNode = get_source_node(RT),
    ListOfNodes = [rt_entry_node(N) || N <- gb_trees:values(get_rt_tree(RT))],
    sorted_nodelist(ListOfNodes, node:id(rt_entry_node(SourceNode)))
    .

% @doc Helper to do the actual work of converting a list of node:node_type() records
% to list beginning with the source node and wrapping around at 0
-spec sorted_nodelist(nodelist:snodelist(), SourceNode::key()) -> nodelist:snodelist().
sorted_nodelist(ListOfNodes, SourceNode) ->
    % sort
    Sorted = lists:sort(fun(A, B) -> node:id(A) =< node:id(B) end,
        ListOfNodes),
    % rearrange elements: all until the source node must be attached at the end
    {Front, Tail} = lists:splitwith(fun(N) -> node:id(N) =< SourceNode end, Sorted),
    Tail ++ Front
    .
%% userdevguide-end rt_frtchord:to_list

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% FRT specific algorithms and functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% @doc Filter one element from a set of nodes. Do it in a way that filters such a node
% that the resulting routing table is the best one under all _possible_ routing tables.

-spec entry_filtering(rt()) -> rt().
entry_filtering(#rt_t{} = RT) ->
    entry_filtering(RT, allowed_nodes(RT)).

-spec entry_filtering(rt(),[#rt_entry{type :: 'normal'}]) -> rt().
entry_filtering(RT, []) -> RT; % only sticky entries and the source node given; nothing to do
entry_filtering(RT, [_|_] = AllowedNodes) ->
    Spacings = [
        begin PredNode = predecessor_node(RT,Node),
              {Node, spacing(Node, RT) + spacing(PredNode, RT)}
        end || Node <- AllowedNodes],
    % remove the element with the smallest canonical spacing range between its predecessor
    % and its successor. TODO beware of numerical errors!
    {FilterEntry, _Spacing} = hd(lists:sort(
            fun ({_,SpacingA}, {_, SpacingB})
                -> SpacingA =< SpacingB
            end, Spacings)
    ),
    FilteredNode = rt_entry_node(FilterEntry),
    entry_delete(node:id(FilteredNode), RT)
    .

% @doc Delete an entry from the routing table
-spec entry_delete(EntryKey :: key(), RT :: rt()) -> RefinedRT :: rt().
entry_delete(EntryKey, RT) ->
    Tree = gb_trees:delete(EntryKey, get_rt_tree(RT)),
    Node = rt_get_node(EntryKey, RT),

    % update affected routing table entries (adjacent fingers)
    {PredId, SuccId} = adjacent_fingers(Node),
    Pred = rt_get_node(PredId, RT),
    Succ = rt_get_node(SuccId, RT),

    UpdatedTree = case PredId =:= SuccId of
        true ->
            Entry = set_adjacent_fingers(Pred, PredId, PredId),
            gb_trees:enter(PredId, Entry, Tree);
        false ->
            NewPred = set_adjacent_succ(Pred, SuccId),
            NewSucc = set_adjacent_pred(Succ, PredId),
            gb_trees:enter(PredId, NewPred,
                gb_trees:enter(SuccId, NewSucc, Tree))
    end,
    % Note: We don't update the subscription here, as it is unclear at this point wether
    % the node died and the FD informed us on that or if the node is alive and was
    % filtered due to a full routing table. If the node died, the FD
    % already removed the subscription.

    RT#rt_t{nodes=UpdatedTree}
    .

% @doc Convert a sticky entry to a normal node
-spec sticky_entry_to_normal_node(EntryKey::key(), RT::rt()) -> rt().
sticky_entry_to_normal_node(EntryKey, RT) ->
    Node = #rt_entry{type=sticky} = rt_get_node(EntryKey, RT),
    NewNode = Node#rt_entry{type=normal},
    UpdatedTree = gb_trees:enter(EntryKey, NewNode, get_rt_tree(RT)),
    RT#rt_t{nodes=UpdatedTree}.


-spec rt_entry_from(Node::node:node_type(), Type :: entry_type(),
                    PredId :: key_t(), SuccId :: key_t()) -> rt_entry().
rt_entry_from(Node, Type, PredId, SuccId) ->
    #rt_entry{node=Node , type=Type , adjacent_fingers={PredId, SuccId},
             custom=rt_entry_info(Node, Type, PredId, SuccId)}.

% @doc Create an rt_entry and return the entry together with the Pred und Succ node, where
% the adjacent fingers are changed for each node.
-spec create_entry(Node :: node:node_type(), Type :: entry_type(), RT :: rt()) ->
    {rt_entry(), rt_entry(), rt_entry()}.
create_entry(Node, Type, RT) ->
    NodeId = node:id(Node),
    Tree = get_rt_tree(RT),
    FirstNode = node:id(Node) =:= get_source_id(RT),
    case util:gb_trees_largest_smaller_than(NodeId, Tree)of
        nil when FirstNode -> % this is the first entry of the RT
            NewEntry = rt_entry_from(Node, Type, NodeId, NodeId),
            {NewEntry, NewEntry, NewEntry};
        nil -> % largest finger
            {_PredId, Pred} = gb_trees:largest(Tree),
            get_adjacent_fingers_from(Pred, Node, Type, RT);
        {value, _PredId, Pred} ->
            get_adjacent_fingers_from(Pred, Node, Type, RT)
    end.

% Get the tuple of adjacent finger ids with Node being in the middle:
% {Predecessor, Node, Successor}
-spec get_adjacent_fingers_from(Pred::rt_entry(), Node::node:node_type(),
    Type::entry_type(), RT::rt()) -> {rt_entry(), rt_entry(), rt_entry()}.
get_adjacent_fingers_from(Pred, Node, Type, RT) ->
    PredId = entry_nodeid(Pred),
    Succ = successor_node(RT, Pred),
    SuccId = entry_nodeid(Succ),
    NodeId = node:id(Node),
    NewEntry = rt_entry_from(Node, Type, PredId, SuccId),
    case PredId =:= SuccId of
        false ->
            {set_adjacent_succ(Pred, NodeId),
             NewEntry,
             set_adjacent_pred(Succ, NodeId)
            };
        true ->
            AdjacentNode = set_adjacent_fingers(Pred, NodeId, NodeId),
            {AdjacentNode, NewEntry, AdjacentNode}
    end
    .

% @doc Add a new entry to the routing table. A source node is only allowed to be added
% once.
-spec entry_learning(Entry :: node:node_type(), Type :: entry_type(), RT :: rt()) -> RefinedRT :: rt().
entry_learning(Entry, Type, RT) -> 
    % only add the entry if it doesn't exist yet or if it is a sticky node. If its a
    % stickynode, RM told us about a new neighbour -> if the neighbour was already added
    % as a normal node, convert it to a sticky node now.
    case gb_trees:lookup(node:id(Entry), get_rt_tree(RT)) of
        none ->
            % change the type to 'sticky' if the node is between the neighbors of the source
            % node
            AdaptedType = case Type of
                sticky -> Type;
                source -> Type;
                normal ->
                    {Pred, Succ} = adjacent_fingers(get_source_node(RT)),
                    ShouldBeAStickyNode = case Pred =/= Succ of
                        true ->
                            case Pred =< Succ of
                                true ->
                                    Interval = intervals:new('[', Pred, Succ, ']'),
                                    intervals:in(node:id(Entry), Interval);
                                false ->
                                    Interval = intervals:new('[', Pred, 0, ']'),
                                    Interval2 = intervals:new('[', 0, Succ, ']'),
                                    intervals:in(node:id(Entry), Interval) orelse
                                        intervals:in(node:id(Entry), Interval2)
                            end;
                        false ->
                            % Only two nodes are existing in the ring (otherwise, Pred == Succ
                            % means there is a bug somewhere!). When two nodes are in the
                            % system, another third node will be either the successor or
                            % predecessor of the source node when added.
                            true
                    end,
                    case ShouldBeAStickyNode of
                        true -> sticky;
                        false -> Type
                    end
            end,

            Ns = {NewPred, NewNode, NewSucc} = create_entry(Entry, AdaptedType, RT),
            % - if the nodes are all the same, we entered the first node and thus only enter
            % a single node to the tree
            % - if pred and succ are the same, we enter the second node: add that node and
            % an updated pred
            % - else, add the new node and update succ and pred
            Nodes = case Ns of
                {NewNode, NewNode, NewNode} ->
                    gb_trees:enter(entry_nodeid(NewNode), NewNode, get_rt_tree(RT));
                {NewPred, NewNode, NewPred} ->
                    gb_trees:enter(entry_nodeid(NewNode), NewNode,
                            gb_trees:enter(entry_nodeid(NewPred), NewPred,
                                get_rt_tree(RT)));
                _Else ->
                    gb_trees:enter(entry_nodeid(NewSucc), NewSucc,
                        gb_trees:enter(entry_nodeid(NewNode), NewNode,
                            gb_trees:enter(entry_nodeid(NewPred), NewPred, get_rt_tree(RT))
                        )
                    )
            end,
            rt_set_nodes(RT, Nodes);
        {value, ExistingEntry} ->
            % Always update a sticky entry, as that information was send from ring
            % maintenance.
            case Type of
                sticky -> % update entry
                    StickyEntry = rt_get_node(node:id(Entry), RT),
                    Nodes = gb_trees:enter(node:id(Entry),
                        StickyEntry#rt_entry{type=sticky},
                        get_rt_tree(RT)),
                    rt_set_nodes(RT, Nodes);
                _ ->
                    case node:is_newer(Entry, rt_entry_node(ExistingEntry)) of
                        true -> % replace an existing node with a newer version
                            Nodes = gb_trees:enter(rt_entry_id(ExistingEntry),
                                           rt_entry_set_node(ExistingEntry, Entry),
                                           get_rt_tree(RT)),
                            rt_set_nodes(RT, Nodes);
                        false -> RT
                    end
            end
    end.

% @doc Combines entry learning and entry filtering.
-spec entry_learning_and_filtering(node:node_type(), entry_type(), rt()) -> rt().
entry_learning_and_filtering(Entry, Type, RT) ->
    IntermediateRT = entry_learning(Entry, Type, RT),

    SizeOfRT = get_size_without_special_nodes(IntermediateRT),
    MaxEntries = maximum_entries(),
    case SizeOfRT > MaxEntries of
        true ->
            NewRT = entry_filtering(IntermediateRT),
            %% only delete the subscription if the newly added node was not filtered;
            %otherwise, there isn't a subscription yet
            case rt_lookup_node(node:id(Entry), NewRT) of
                none -> ok;
                {value, _RTEntry} -> update_fd(RT, NewRT)
            end,
            NewRT;
        false ->
            add_fd(IntermediateRT),
            IntermediateRT
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% RT and RT entry record accessors
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% @doc Get the source node of a routing table
-spec get_source_node(RT :: rt()) -> rt_entry().
get_source_node(#rt_t{source=undefined}) -> erlang:error("routing table source unknown");
get_source_node(#rt_t{source=NodeId, nodes=Nodes}) ->
    case Nodes =:= gb_trees:empty() of
            false -> gb_trees:get(NodeId, Nodes);
            true  -> exit(rt_broken_tree_empty)
    end.

% @doc Get the id of the source node.
-spec get_source_id(RT :: rt()) -> key().
get_source_id(#rt_t{source=NodeId}) -> NodeId.

% @doc Set the source node of a routing table
-spec set_source_node(SourceId :: key(), RT :: rt()) -> rt().
set_source_node(SourceId, #rt_t{source=undefined}=RT) ->
    RT#rt_t{source=SourceId}.

% @doc Get the gb_tree of the routing table containing its nodes
-spec get_rt_tree(Nodes::rt()) -> gb_tree().
get_rt_tree(#rt_t{nodes=Nodes}) -> Nodes.

% @doc Get the number of active learning lookups which have happened
-spec get_num_active_learning_lookups(RT :: rt()) -> non_neg_integer().
get_num_active_learning_lookups(RT) -> RT#rt_t.num_active_learning_lookups.

% @doc Set the number of happened active learning lookups
-spec set_num_active_learning_lookups(RT :: rt(), Num :: non_neg_integer()) -> rt().
set_num_active_learning_lookups(RT,Num) -> RT#rt_t{num_active_learning_lookups=Num}.

% @doc Increment the number of happened active learning lookups
-spec inc_num_active_learning_lookups(RT :: rt()) -> rt().
inc_num_active_learning_lookups(RT) ->
    Inc = get_num_active_learning_lookups(RT) + 1,
    set_num_active_learning_lookups(RT, Inc).

% @doc Get all sticky entries of a routing table
-spec get_sticky_entries(rt()) -> [rt_entry()].
get_sticky_entries(#rt_t{nodes=Nodes}) ->
    util:gb_trees_foldl(fun(_K, #rt_entry{type=sticky} = E, Acc) -> [E|Acc];
                      (_,_,Acc) -> Acc
                  end, [], Nodes).

% @doc Check if a node exists in the routing table
-spec entry_exists(EntryKey :: key(), rt()) -> boolean().
entry_exists(EntryKey, #rt_t{nodes=Nodes}) ->
    case gb_trees:lookup(EntryKey, Nodes) of
        none -> false;
        _Else -> true
    end.

% @doc Add an entry of a specific type to the routing table
%-spec add_entry(Node :: node:node_type(), Type :: entry_type(), RT :: rt()) -> rt().
-spec add_entry(node:node_type(),'normal' | 'source' | 'sticky',rt()) -> rt().
add_entry(Node, Type, RT) ->
    entry_learning_and_filtering(Node, Type, RT).

% @doc Add a sticky entry to the routing table
-spec add_sticky_entry(Entry :: node:node_type(), rt()) -> rt().
add_sticky_entry(Entry, RT) -> add_entry(Entry, sticky, RT).

% @doc Add the source entry to the routing table
-spec add_source_entry(Entry :: node:node_type(), rt()) -> rt().
add_source_entry(Entry, #rt_t{source=undefined} = RT) ->
    IntermediateRT = set_source_node(node:id(Entry), RT),
    % only learn; the RT must be empty, so there is no filtering needed afterwards
    NewRT = entry_learning(Entry, source, IntermediateRT),
    add_fd(NewRT),
    NewRT.

% @doc Add a normal entry to the routing table
-spec add_normal_entry(Entry :: node:node_type(), rt()) -> rt().
add_normal_entry(Entry, RT) ->
    add_entry(Entry, normal, RT).

% @doc Get the inner node:node_type() of a rt_entry
-spec rt_entry_node(N :: rt_entry()) -> node:node_type().
rt_entry_node(#rt_entry{node=N}) -> N.

% @doc Set the inner node:node_type() of a rt_entry
-spec rt_entry_set_node(Entry :: rt_entry(), Node :: node:node_type()) -> rt_entry().
rt_entry_set_node(#rt_entry{} = Entry, Node) -> Entry#rt_entry{node=Node}.

% @doc Calculate the distance between two nodes in the routing table
-spec rt_entry_distance(From :: rt_entry(), To :: rt_entry()) -> non_neg_integer().
rt_entry_distance(From, To) ->
    get_range(node:id(rt_entry_node(From)), node:id(rt_entry_node(To))).

% @doc Get all nodes within the routing table
-spec rt_get_nodes(RT :: rt()) -> [rt_entry()].
rt_get_nodes(RT) -> gb_trees:values(get_rt_tree(RT)).

% @doc Set the treeof nodes of the routing table.
-spec rt_set_nodes(RT :: rt(), Nodes :: gb_tree()) -> rt().
rt_set_nodes(#rt_t{source=undefined}, _) -> erlang:error(source_node_undefined);
rt_set_nodes(#rt_t{} = RT, Nodes) -> RT#rt_t{nodes=Nodes}.

%% Get the node with the given Id. This function will crash if the node doesn't exist.
-spec rt_get_node(NodeId :: key(), RT :: rt()) -> rt_entry().
rt_get_node(NodeId, RT)  -> gb_trees:get(NodeId, get_rt_tree(RT)).

% @doc Similar to rt_get_node/2, but doesn't crash when the id doesn't exist
-spec rt_lookup_node(NodeId :: key(), RT :: rt()) -> {value, rt_entry()} | none.
rt_lookup_node(NodeId, RT) -> gb_trees:lookup(NodeId, get_rt_tree(RT)).

% @doc Get the id of a given node
-spec rt_entry_id(Entry :: rt_entry()) -> key_t().
rt_entry_id(Entry) -> node:id(rt_entry_node(Entry)).

%% @doc Check if the given routing table entry is of the given entry type.
-spec entry_is_of_type(rt_entry(), Type::entry_type()) -> boolean().
entry_is_of_type(#rt_entry{type=Type}, Type) -> true;
entry_is_of_type(_,_) -> false.

%% @doc Check if the given routing table entry is a source entry.
-spec is_source(Entry :: rt_entry()) -> boolean().
is_source(Entry) -> entry_is_of_type(Entry, source).

%% @doc Check if the given routing table entry is a sticky entry.
-spec is_sticky(Entry :: rt_entry()) -> boolean().
is_sticky(Entry) -> entry_is_of_type(Entry, sticky).

-spec entry_type(Entry :: rt_entry()) -> entry_type().
entry_type(Entry) -> Entry#rt_entry.type.

%% @doc Get the node id of a routing table entry
-spec entry_nodeid(Node :: rt_entry()) -> key().
entry_nodeid(#rt_entry{node=Node}) -> node:id(Node).

% @doc Get the adjacent fingers from a routing table entry
-spec adjacent_fingers(rt_entry()) -> {key(), key()}.
adjacent_fingers(#rt_entry{adjacent_fingers=Fingers}) -> Fingers.

%% @doc Get the adjacent predecessor key() of the current node.
-spec adjacent_pred(rt_entry()) -> key().
adjacent_pred(#rt_entry{adjacent_fingers={Pred,_Succ}}) -> Pred.

%% @doc Get the adjacent successor key of the current node
-spec adjacent_succ(rt_entry()) -> key().
adjacent_succ(#rt_entry{adjacent_fingers={_Pred,Succ}}) -> Succ.

%% @doc Set the adjacent fingers of a node
-spec set_adjacent_fingers(rt_entry(), key(), key()) -> rt_entry().
set_adjacent_fingers(#rt_entry{} = Entry, PredId, SuccId) ->
    Entry#rt_entry{adjacent_fingers={PredId, SuccId}}.

%% @doc Set the adjacent successor of the finger
-spec set_adjacent_succ(rt_entry(), key()) -> rt_entry().
set_adjacent_succ(#rt_entry{adjacent_fingers={PredId, _Succ}} = Entry, SuccId) ->
    set_adjacent_fingers(Entry, PredId, SuccId).

%% @doc Set the adjacent predecessor of the finger
-spec set_adjacent_pred(rt_entry(), key()) -> rt_entry().
set_adjacent_pred(#rt_entry{adjacent_fingers={_Pred, SuccId}} = Entry, PredId) ->
    set_adjacent_fingers(Entry, PredId, SuccId).

%% @doc Set the custom info field of a rt entry
-spec set_custom_info(rt_entry(), custom_info()) -> rt_entry().
set_custom_info(#rt_entry{} = Entry, CustomInfo) ->
    Entry#rt_entry{custom=CustomInfo}.

%% @doc Get the custom info field of a rt entry
-spec get_custom_info(rt_entry()) -> custom_info().
get_custom_info(#rt_entry{custom=CustomInfo}) ->
    CustomInfo.

%% @doc Get the adjacent predecessor rt_entry() of the given node.
-spec predecessor_node(RT :: rt(), Node :: rt_entry()) -> rt_entry().
predecessor_node(RT, Node) ->
    gb_trees:get(adjacent_pred(Node), get_rt_tree(RT)).

-spec successor_node(RT :: rt(), Node :: rt_entry()) -> rt_entry().
successor_node(RT, Node) ->
    try gb_trees:get(adjacent_succ(Node), get_rt_tree(RT)) catch
         error:function_clause -> exit('stale adjacent fingers')
    end.

-spec spacing(Node :: rt_entry(), RT :: rt()) -> float().
spacing(Node, RT) ->
    SourceNodeId = entry_nodeid(get_source_node(RT)),
    canonical_spacing(SourceNodeId, entry_nodeid(Node),
        adjacent_succ(Node)).

%% @doc Calculate the canonical spacing, which is defined as
%%  S_i = log_2(distance(SourceNode, SuccId) / distance(SourceNode, Node))
canonical_spacing(SourceId, NodeId, SuccId) ->
    util:log2(get_range(SourceId, SuccId) / get_range(SourceId, NodeId)).

% @doc Check that all entries in an rt are well connected by their adjacent fingers
-spec check_rt_integrity(RT :: rt()) -> boolean().
check_rt_integrity(#rt_t{} = RT) ->
    Nodes = [node:id(N) || N <- internal_to_list(RT)],

    %  make sure that the entries are well-connected
    Currents = Nodes,
    Last = lists:last(Nodes),
    Preds = [Last| lists:filter(fun(E) -> E =/= Last end, Nodes)],
    Succs = tl(Nodes) ++ [hd(Nodes)],

    % for each 3-tuple of pred, current, succ, check if the RT obeys the fingers
    Checks = [begin Node = rt_get_node(C, RT),
                case adjacent_fingers(Node) of
                    {P, S} ->
                        true;
                    _Else ->
                        false
                end end || {P, C, S} <- lists:zip3(Preds, Currents, Succs)],
    lists:all(fun(X) -> X end, Checks)
    .

%% userdevguide-begin rt_frtchord:wrap_message
%% @doc Wrap lookup messages.
%% For node learning in lookups, a lookup message is wrapped with the global Pid of the
-spec wrap_message(Msg::comm:message(), State::dht_node_state:state(),
                   Hops::non_neg_integer()) ->
    {'$wrapped', comm:mypid(), comm:message()} | comm:message().
wrap_message(Msg, State, 0) -> {'$wrapped', dht_node_state:get(State, node), Msg};
wrap_message({'$wrapped', Issuer, _} = Msg, _State, _) ->
    % learn a node when forwarding it's request
    comm:send_local(self(), {?send_to_group_member, routing_table,
                             {rt_learn_node, Issuer}}),
    Msg.
%% userdevguide-end rt_frtchord:wrap_message

%% userdevguide-begin rt_frtchord:unwrap_message
%% @doc Unwrap lookup messages.
%% The Pid is retrieved and the Pid of the current node is sent to the retrieved Pid
-spec unwrap_message(Msg::comm:message(), State::dht_node_state:state()) -> comm:message().
unwrap_message({'$wrapped', Issuer, UnwrappedMessage}, State) ->
    comm:send(node:pidX(Issuer),
         {?send_to_group_member, routing_table,
             {rt_learn_node, dht_node_state:get(State, node)}
         }),
    UnwrappedMessage.
%% userdevguide-end rt_frtchord:unwrap_message

% @doc Check that the adjacent fingers of a RT are building a ring
-spec check_well_connectedness(RT::rt()) -> boolean().
check_well_connectedness(RT) ->
    Nodes = [N || {_, N} <- gb_trees:to_list(get_rt_tree(RT))],
    NodeIds = lists:sort([Id || {Id, _} <- gb_trees:to_list(get_rt_tree(RT))]),
    % traverse the adjacent fingers of the nodes and add each visited node to a list
    % NOTE: each node should only be visited once
    InitVisitedNodes = ordsets:from_list([{N, false} || N <- Nodes]),
    %% check forward adjacent fingers
    Visit = fun(Visit, Current, Visited, Direction) ->
            case ordsets:is_element({Current, false}, Visited) of
                true -> % node wasn't visited
                    AccVisited = ordsets:add_element({Current, true},
                        ordsets:del_element({Current, false}, Visited)),
                    Next = case Direction of
                        succ -> rt_get_node(adjacent_succ(Current), RT);
                        pred -> rt_get_node(adjacent_pred(Current), RT)
                    end,
                    Visit(Visit, Next, AccVisited, Direction);
                false ->
                    Filtered = ordsets:filter(fun({_, true}) -> true; (_) -> false end,
                        Visited),
                    lists:sort([entry_nodeid(N) || {N, true} <- ordsets:to_list(Filtered)])
            end
    end,
    Succs = Visit(Visit, get_source_node(RT), InitVisitedNodes, succ),
    Preds = Visit(Visit, get_source_node(RT), InitVisitedNodes, pred),
    try
        NodeIds = Succs,
        NodeIds = Preds,
        true
    catch
        _:_ -> false
    end
    .
