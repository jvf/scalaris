%  @copyright 2009-2014 Zuse Institute Berlin

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

%% @author Christian Hennig <hennig@zib.de>
%% @doc    Periodic trigger for (parameterized) modules.
%%
%% Can be used by a module <code>Module</code> in order to get a configurable
%% message (by default <code>{trigger}</code>) every
%% <code>BaseInterval</code> milliseconds.
%% 
%% Use this module through the interface provided by the trigger module,
%% initializing it with trigger_periodic!
%% @version $Id$
-module(trigger_periodic).
-author('hennig@zib.de').
-vsn('$Id$').

-behaviour(trigger_beh).

-include("scalaris.hrl").

-export([init/4, now/2, next/3, stop/1]).

-type state() :: {trigger:interval_time(), comm:msg_tag(), reference() | ok}.

%% @doc Initializes the trigger with the given interval functions and the given
%%      message tag used for the trigger message.
-spec init(BaseInterval::trigger:interval_time(), MinInterval::trigger:interval_time(),
           MaxInterval::trigger:interval_time(), comm:msg_tag()) -> state().
init(BaseInterval, _MinInterval, _MaxInterval, MsgTag) when is_integer(BaseInterval) ->
    {BaseInterval, MsgTag, ok}.

%% @doc Sets the trigger to send its message immediately to the given Pid, for
%%      example after its initialization. Any previous trigger will be canceled!
-spec now(state(), ReplyTo::comm:erl_local_pid()) -> state().
now({BaseInterval, MsgTag, ok}, ReplyTo) ->
    ok = comm:send_local(ReplyTo, {MsgTag}),
    {BaseInterval, MsgTag, ok};
now({BaseInterval, MsgTag, TimerRef}, ReplyTo) ->
    % timer still running
    _ = erlang:cancel_timer(TimerRef),
    ok = comm:send_local(ReplyTo, {MsgTag}),
    {BaseInterval, MsgTag, ok}.

%% @doc Sets the trigger to send its message after BaseInterval
%%      milliseconds. Any previous trigger will be canceled!
-spec next(state(), IntervalTag::trigger:interval(), ReplyTo::comm:erl_local_pid()) -> state().
next({BaseInterval, MsgTag, ok}, _IntervalTag, ReplyTo) ->
%    io:format("new timer~n"),
    NewTimerRef = comm:send_local_after(BaseInterval, ReplyTo, {MsgTag}),
    {BaseInterval, MsgTag, NewTimerRef};
next({BaseInterval, MsgTag, TimerRef}, _IntervalTag, ReplyTo) ->
    % timer still running
    _ = erlang:cancel_timer(TimerRef),
%    io:format("new timer 2~n"),
    NewTimerRef = comm:send_local_after(BaseInterval, ReplyTo, {MsgTag}),
    {BaseInterval, MsgTag, NewTimerRef}.

%% @doc Stops the trigger until next or now are called again.
-spec stop(state()) -> state().
stop({_BaseInterval, _MsgTag, ok} = State) ->
    State;
stop({BaseInterval, MsgTag, TimerRef}) ->
    % timer still running?
    _ = erlang:cancel_timer(TimerRef),
    {BaseInterval, MsgTag, ok}.
