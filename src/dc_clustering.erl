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
%% @author Marie Hoffmann <hoffmann@zib.de>
%% @doc    Re-register with boot nodes
%% @end
%% @reference T. Schuett, A. Reinefeld,F. Schintke, M. Hoffmann.
%% Gossip-based Topology Inference for Efficient Overlay Mapping on Data Centers.
%% 9th Int. Conf. on Peer-to-Peer Computing Seattle, Sept. 2009.
%% @version $Id$
-module(dc_clustering).
-author('schuett@zib.de').
-vsn('$Id$').

-behaviour(gen_component).
-include("scalaris.hrl").

-export([start_link/1]).

-export([init/1, on_inactive/2, on_active/2,
         activate/0, deactivate/0,
         check_config/0]).

-record(state_active,{
        centroids = [] :: dc_centroids:centroids()
        , local_epoch = 0 :: non_neg_integer()
        , reset_trigger_state :: trigger:state()
        , cluster_trigger_state :: trigger:state()
        , radius :: float()
}).

-record(state_inactive,{
        queued_messages :: msg_queue:msg_queue()
        , reset_trigger_state :: trigger:state()
        , cluster_trigger_state :: trigger:state()
        , radius :: float()
}).

% state of the clustering loop
-type(state_active() :: #state_active{}).
-type(state_inactive() :: #state_inactive{}).
%% -type(state() :: state_active() | state_inactive()).

% accepted messages of an initialized dc_clustering process
-type(message() :: 
    {start_clustering_shuffle} |
    {reset_clustering} |
    {vivaldi_get_coordinate_response, vivaldi:network_coordinate(), vivaldi:error()} |
    {cy_cache, [node:node_type()]} |
    {clustering_shuffle, comm:mypid(), dc_centroids:centroids(), non_neg_integer()} |
    {clustering_shuffle_reply, comm:mypid(), dc_centroids:centroids(), non_neg_integer()} |
    {query_clustering, comm:mypid()} |
    {query_epoch, comm:mypid()} |
    {query_my, atom(), comm:mypid()}
).

%% @doc Sends an initialization message to the node's dc_clustering process.
-spec activate() -> ok | ignore.
activate() ->
    case config:read(dc_clustering_enable) of
        true ->
            Pid = pid_groups:get_my(dc_clustering),
            comm:send_local(Pid, {activate_clustering});
        _ ->
            ignore
    end.

%% @doc Deactivates the cyclon process.
-spec deactivate() -> ok | ignore.
deactivate() ->
    case config:read(dc_clustering_enable) of
        true ->
            Pid = pid_groups:get_my(dc_clustering),
            comm:send_local(Pid, {deactivate_clustering});
        _ ->
            ignore
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Init
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Starts the dc_clustering process, registers it with the process
%%      dictionary and returns its pid for use by a supervisor.
-spec start_link(pid_groups:groupname()) -> {ok, pid()} | ignore.
start_link(DHTNodeGroup) ->
    case config:read(dc_clustering_enable) of
        true ->
            ResetTrigger = config:read(dc_clustering_reset_trigger),
            ClusterTrigger = config:read(dc_clustering_cluster_trigger),
            gen_component:start_link(?MODULE, fun ?MODULE:on_inactive/2, {ResetTrigger, ClusterTrigger},
                                     [{pid_groups_join_as, DHTNodeGroup, dc_clustering}]);
        _ ->
            ignore
    end.

%% @doc Initialises the module with an empty state.
-spec init({module(), module()}) -> state_inactive().
init({ResetTrigger, ClusterTrigger}) ->
    ResetTriggerState = trigger:init(ResetTrigger, fun get_clustering_reset_interval/0, reset_clustering),
    ClusterTriggerState = trigger:init(ClusterTrigger, fun get_clustering_interval/0, start_clustering_shuffle),
    #state_inactive{
        queued_messages = msg_queue:new()
        , reset_trigger_state = ResetTriggerState
        , cluster_trigger_state = ClusterTriggerState
        , radius = config:read(dc_clustering_radius)
    }
    .

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message Loop
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Message handler during start up phase (will change to on_active/2 when a
%%      'activate_clustering' message is received).
-spec on_inactive(message(), state_inactive()) -> state_inactive();
                ({activate_clustering}, state_inactive())
            -> {'$gen_component', [{on_handler, Handler::gen_component:handler()}], State::state_active()}.
on_inactive({activate_clustering}, #state_inactive{
                                    queued_messages=QueuedMessages
                                    ,reset_trigger_state=ResetTriggerState
                                    ,cluster_trigger_state=ClusterTriggerState
                                    ,radius=R
                                }) ->
    log:log(info, "[ Clustering ~.0p ] activating...~n", [comm:this()]),
    ResetTriggerState2 = trigger:now(ResetTriggerState),
    ClusterTriggerState2 = trigger:now(ClusterTriggerState),
    msg_queue:send(QueuedMessages),
    StateActive = #state_active{
        centroids = dc_centroids:empty_centroids_list()
        , reset_trigger_state = ResetTriggerState2
        , cluster_trigger_state = ClusterTriggerState2
        , radius=R
    },
    gen_component:change_handler(StateActive, fun ?MODULE:on_active/2)
    ;

on_inactive(Msg = {query_clustering, _Pid}, #state_inactive{queued_messages=QueuedMessages} = State) ->
    State#state_inactive{queued_messages=msg_queue:add(QueuedMessages, Msg)}
    ;

on_inactive({query_epoch, _Pid} = Msg, #state_inactive{queued_messages=Q} = State) ->
    State#state_inactive{queued_messages=msg_queue:add(Q, Msg)}
    ;

on_inactive({web_debug_info, Requestor}, #state_inactive{queued_messages=Q} = State) ->
    % get a list of up to 50 queued messages to display:
    MessageListTmp = [{"", webhelpers:safe_html_string("~p", [Message])}
                  || Message <- lists:sublist(Q, 50)],
    MessageList = case length(Q) > 50 of
                      true -> lists:append(MessageListTmp, [{"...", ""}]);
                      _    -> MessageListTmp
                  end,
    KeyValueList = [{"", ""}, {"inactive clustering process", ""}, {"queued messages:", ""} | MessageList],
    comm:send_local(Requestor, {web_debug_info_reply, KeyValueList}),
    State;

on_inactive(_Msg, State) ->
    State.

%% @doc Message handler when the module is fully initialized.
-spec on_active(Message::message(), State::state_active()) -> state_active();
         ({deactivate_clustering}, state_active()) -> {'$gen_component', [{on_handler, Handler::gen_component:handler()}], State::state_inactive()}.
on_active({deactivate_clustering}
          , #state_active{
                          reset_trigger_state=ResetTriggerState
                          , cluster_trigger_state=ClusterTriggerState
                          , radius=R
                      }) ->
    log:log(info, "[ Clustering ~.0p ] deactivating...~n", [comm:this()]),
    StateInactive = #state_inactive{
        queued_messages = msg_queue:new()
        , reset_trigger_state = ResetTriggerState
        , cluster_trigger_state = ClusterTriggerState
        , radius=R
    },
    gen_component:change_handler(StateInactive, fun ?MODULE:on_inactive/2);

% ignore activate_clustering messages in active state
% note: remove this if the clustering process is to be deactivated on leave (see
% dht_node_move.erl). In the current implementation we can not distinguish
% between the first join and a re-join but after every join, the process is
% (re-)activated.
on_active({activate_clustering}, State) ->
    State;
    
on_active({start_clustering_shuffle}, #state_active{cluster_trigger_state = C} = State) ->
    % start new clustering shuffle -> gossip communication
    NewClusterTriggerState = trigger:next(C),
    cyclon:get_subset_rand(1),
    State#state_active{cluster_trigger_state=NewClusterTriggerState}
    ;

% ask vivaldi for network coordinate
on_active({reset_clustering}
          , #state_active{reset_trigger_state = ResetTriggerState} = State) ->
    vivaldi:get_coordinate(),
    NewResetTriggerState = trigger:next(ResetTriggerState),
    State#state_active{reset_trigger_state=NewResetTriggerState}
    ;

% reset the local state and start a new epoche
on_active({vivaldi_get_coordinate_response, Coordinate, _Confidence}
           , #state_active{local_epoch=Epoch} = State) ->
    State#state_active{
        local_epoch=Epoch + 1
        , centroids=[dc_centroids:new(Coordinate, 1.0)]
    }
    ;

on_active({cy_cache, []}, State)  ->
    % ignore empty cache from cyclon
    State;

% got random node from cyclon
on_active({cy_cache, [Node] = _Cache}
          , #state_active{centroids=C, local_epoch=E} = State) ->
    %io:format("~p~n",[_Cache]),
    comm:send(node:pidX(Node), {clustering_shuffle, comm:this(), C, E},
              [{group_member, dc_clustering}]),
    State;

% have been asked to shuffle
on_active({clustering_shuffle, RemoteNode, RemoteCentroids, RemoteEpoch}, State) ->
    %io:format("{shuffle, ~p, ~p}~n", [RemoteCoordinate, RemoteConfidence]),
    handle_shuffle(State, {RemoteNode, RemoteEpoch, RemoteCentroids})
    ;

% got shuffle response
on_active({clustering_shuffle_reply, _RemoteNode, RemoteCentroids, RemoteEpoch}, State) ->
    %io:format("{shuffle_reply, ~p, ~p}~n", [RemoteCoordinate, RemoteConfidence]),
    %vivaldi_latency:measure_latency(RemoteNode, RemoteCoordinate, RemoteConfidence),
    handle_shuffle(State, {ignore, RemoteEpoch, RemoteCentroids})
    ;

% return my clusters
on_active({query_clustering, Pid}, #state_active{centroids=C} = State) ->
    comm:send(Pid, {query_clustering_response, C}),
    State
    ;

on_active({query_my, Atom, Pid}, State) ->
    case Atom of
        local_epoch -> Msg = State#state_active.local_epoch
            , comm:send(Pid, {query_my_response, local_epoch, Msg})
            ;
        radius -> Msg = State#state_active.radius
            , comm:send(Pid, {query_my_response, radius, Msg})
    end,
    State
    .

%% @doc Checks whether config parameters exist and are valid.
-spec check_config() -> boolean().
check_config() ->
    case config:read(dc_clustering_enable) of
        true ->
            config:cfg_is_integer(dc_clustering_reset_interval) andalso
            config:cfg_is_greater_than(dc_clustering_reset_interval, 0) andalso
            config:cfg_is_integer(dc_clustering_interval) andalso
            config:cfg_is_greater_than(dc_clustering_interval, 0) andalso
            config:cfg_is_module(dc_clustering_reset_trigger) andalso
            config:cfg_is_module(dc_clustering_cluster_trigger) andalso
            config:cfg_is_float(dc_clustering_radius) andalso
            config:cfg_is_greater_than(dc_clustering_radius, 0.0);
        _ -> true
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec cluster(dc_centroids:centroids(), dc_centroids:centroids(), float()) -> dc_centroids:centroids().
cluster([], RemoteCentroids, _Radius) -> RemoteCentroids;
cluster(Centroids, RemoteCentroids, Radius) ->
    NewCentroids = mathlib:aggloClustering(Centroids ++ RemoteCentroids, Radius),
    NormalizedCentroids = lists:map(fun (Centroid) ->
                dc_centroids:set_relative_size(Centroid,
                    0.5 * dc_centroids:get_relative_size(Centroid))
                end, NewCentroids),
    NormalizedCentroids.

%% @doc Gets the clustering reset interval set in scalaris.cfg.
-spec get_clustering_reset_interval() -> pos_integer().
get_clustering_reset_interval() ->
    config:read(dc_clustering_reset_interval).

%% @doc Gets the clustering interval, e.g. how often to calculate clusters, set
%%      in scalaris.cfg.
-spec get_clustering_interval() -> pos_integer().
get_clustering_interval() ->
    config:read(dc_clustering_interval).

-spec handle_shuffle(state_active(),
        {RemoteNode :: comm:mypid() | ignore, RemoteEpoch :: non_neg_integer(),
         RemoteCentroids :: dc_centroids:centroids()}) -> state_active().
handle_shuffle(#state_active{
        centroids=Centroids
        , local_epoch=Epoch
        , reset_trigger_state=ResetTriggerState
        , cluster_trigger_state=ClusterTriggerState
        , radius=Radius
    } = State, {RemoteNode, RemoteEpoch, RemoteCentroids}) ->
    % Check the epoch to swallow old messages and delete old state:
    %
    % - if the local epoch is less than the remote epoch, we didn't see a certain wave yet and
    % have to reset the local cluster state.
    % - if the local epoch is bigger than the remote epoch, we ignore the information we
    % received and only send our information, as the remote node is behind the last wave
    % we saw.

    % With this, we purge "zombie centroids" (stale centroids far away from any real
    % clusters) over time: clusters can not survive a wave if they seized to exist during
    % the cut.

    {NewEpoch, NewCentroids} =
    if Epoch < RemoteEpoch -> % reset and merge remote information
            vivaldi:get_coordinate(),
            {RemoteEpoch, []}
            ;
        Epoch > RemoteEpoch -> % ignore remote information, keep talking
            case RemoteNode of
                ignore -> ok;
                R -> comm:send(R, {clustering_shuffle_reply, comm:this(), Centroids, Epoch})
            end,
            {Epoch, Centroids};
        true -> % Epoch == RemoteEpoch
            case RemoteNode of
                ignore -> ok;
                R -> comm:send(R, {clustering_shuffle_reply, comm:this(), Centroids, Epoch})
            end,
            {Epoch, cluster(Centroids, RemoteCentroids, Radius)}
    end,
    case NewEpoch of % reset needed?
        Epoch -> State#state_active{centroids=NewCentroids};
        _Else ->
            NewResetTriggerState = trigger:next(ResetTriggerState),
            NewClusterTriggerState = trigger:next(ClusterTriggerState),
            % Note: NewEpoch - 1 because we will increment it in the handler for the
            % vivaldi reply
            State#state_active{
                centroids=NewCentroids
                , local_epoch=NewEpoch - 1
                , reset_trigger_state=NewResetTriggerState
                , cluster_trigger_state=NewClusterTriggerState
            }
    end
    .
