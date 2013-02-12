% @copyright 2009-2012 Zuse Institute Berlin,
%            2009 onScale solutions GmbH
% @end

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

%% @author Florian Schintke <schintke@onscale.de>
%% @doc Cheap message delay.
%%      Instead of using send_after, which is slow in Erlang, as it
%%      performs a system call, this module allows for a weaker
%%      message delay.
%%      You can specify the minimum message delay in seconds and the
%%      component will send the message sometime afterwards.
%%      Only local messages inside a VM are supported.
%%      Internally it triggers itself periodically to schedule sending.
%% @end
%% @version $Id$
-module(msg_delay).
-author('schintke@onscale.de').
-vsn('$Id$').

%-define(TRACE(X,Y), io:format(X,Y)).
-define(TRACE(_X,_Y), ok).
-behaviour(gen_component).

%% public interface for delayed messages
-export([send_local/3,
         send_local_as_client/3]).

%% functions for gen_component module and supervisor callbacks
-export([start_link/1, on/2, init/1]).

% accepted messages of the msg_delay process
-type message() ::
    {msg_delay_req, Seconds::pos_integer(), Dest::comm:erl_local_pid(), Msg::comm:message()} |
    {msg_delay_periodic}.

% internal state
-type state() :: {TimeTable :: pdb:tableid(), Round :: non_neg_integer()}.

-spec send_local_as_client(Seconds::non_neg_integer(),
                           Dest::comm:erl_local_pid(),
                           Msg::comm:message()) -> ok.
send_local_as_client(Seconds, Dest, Msg) ->
    Delayer = pid_groups:pid_of("clients_group", msg_delay),
    comm:send_local(Delayer, {msg_delay_req, Seconds, Dest, Msg}).

-spec send_local(Seconds::non_neg_integer(), Dest::comm:erl_local_pid(), Msg::comm:message()) -> ok.
send_local(Seconds, Dest, Msg) ->
    Delayer = pid_groups:find_a(msg_delay),
    comm:send_local(Delayer, {msg_delay_req, Seconds, Dest, Msg}).

%% be startable via supervisor, use gen_component
-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(DHTNodeGroup) ->
    gen_component:start_link(?MODULE, fun ?MODULE:on/2,
                             [], % parameters passed to init
                             [{pid_groups_join_as, DHTNodeGroup, msg_delay}]).

%% userdevguide-begin gen_component:sample
%% initialize: return initial state.
-spec init([]) -> state().
init([]) ->
    MyGroup = pid_groups:my_groupname(),
    ?TRACE("msg_delay:init for pid group ~p~n", [MyGroup]),
    TimeTable = pdb:new(MyGroup ++ "_msg_delay", [set, protected, named_table]),
    %% use random table name provided by ets to *not* generate an atom
    %% TimeTable = pdb:new(?MODULE, [set, private]),
    comm:send_local(self(), {msg_delay_periodic}),
    _State = {TimeTable, _Round = 0}.

-spec on(message(), state()) -> state().
on({msg_delay_req, Seconds, Dest, Msg} = _FullMsg,
   {TimeTable, Counter} = State) ->
    ?TRACE("msg_delay:on(~.0p, ~.0p)~n", [_FullMsg, State]),
    Future = trunc(Counter + Seconds),
    EMsg = case erlang:get(trace_mpath) of
               undefined -> Msg;
               PState -> trace_mpath:epidemic_reply_msg(PState, comm:this(), Dest, Msg)
           end,
    case pdb:get(Future, TimeTable) of
        undefined ->
            pdb:set({Future, [{Dest, EMsg}]}, TimeTable);
        {_, MsgQueue} ->
            pdb:set({Future, [{Dest, EMsg} | MsgQueue]}, TimeTable)
    end,
    State;

%% periodic trigger
on({msg_delay_periodic} = Trigger, {TimeTable, Counter} = _State) ->
    ?TRACE("msg_delay:on(~.0p, ~.0p)~n", [Trigger, State]),
    _ = case pdb:take(Counter, TimeTable) of
        undefined -> ok;
        {_, MsgQueue} ->
            _ = [ case Msg of
                      {'$gen_component', trace_mpath, PState, _From, _To, OrigMsg} ->
                          Restore = erlang:get(trace_mpath),
                          trace_mpath:start(PState),
                          comm:send_local(Dest, OrigMsg),
                          erlang:put(trace_mpath, Restore);
                      _ -> comm:send_local(Dest, Msg)
                  end || {Dest, Msg} <- MsgQueue ]
    end,
    ETrigger =
        case erlang:get(trace_mpath) of
            undefined -> Trigger;
            PState -> trace_mpath:epidemic_reply_msg(PState, comm:this(), comm:this(), Trigger)
        end,
    comm:send_local_after(1000, self(), ETrigger),
    {TimeTable, Counter + 1};

on({web_debug_info, Requestor}, {TimeTable, Counter} = State) ->
    KeyValueList =
        [{"queued messages (in 0-10s, messages):", ""} |
         [begin
              Future = trunc(Counter + Seconds),
              Queue = case pdb:get(Future, TimeTable) of
                          undefined -> none;
                          {_, Q}    -> Q
                      end,
              {webhelpers:safe_html_string("~p", [Seconds]),
               webhelpers:safe_html_string("~p", [Queue])}
          end || Seconds <- lists:seq(0, 10)]],
    comm:send_local(Requestor, {web_debug_info_reply, KeyValueList}),
    State.
%% userdevguide-end gen_component:sample
