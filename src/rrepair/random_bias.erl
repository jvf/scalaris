% @copyright 2011, 2012 Zuse Institute Berlin

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
%% @doc    biased random number generator
%% @end
%% @version $Id$
-module(random_bias).
-author('malange@informatik.hu-berlin.de').
-vsn('$Id$').

-include("record_helpers.hrl").
-include("scalaris.hrl").

-export([binomial/2]).

% for tester:
-export([tester_create_distribution_fun/3]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% type definitions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-ifdef(with_export_type_support).
-export_type([distribution_fun/0]).
-endif.

-type binomial_state() :: {binom,
                           N         :: pos_integer(),
                           P         :: float(),             %only works for ]0,1[
                           X         :: non_neg_integer(),
                           UseApprox :: boolean()
                          }.

-type distribution_fun() :: fun(() -> {ok | last, float()}).
-type distribution_state() :: binomial_state(). %or others
-type generator_state() :: { State       :: distribution_state(),
                             CalcFun     :: fun((distribution_state()) -> float()),
                             NewStateFun :: fun((distribution_state()) -> distribution_state() | exit)}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% creates a new binomial distribution generation fun.
-spec binomial(pos_integer(), float()) -> distribution_fun().
binomial(N, P) ->
    ?ASSERT(P > 0 andalso P < 1),
    UseApprox = approx_valid(N, P),
    create_distribution_fun({ {binom, N, P, 0, UseApprox},
                              fun calc_binomial/1,
                              fun next_state/1 }).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec create_distribution_fun(generator_state()) -> distribution_fun().
create_distribution_fun(State) ->
    Pid = spawn(fun() -> generator(State) end),
    fun() ->
            comm:send_local(Pid, {next, self()}),
            receive
                ?SCALARIS_RECV({last_response, V}, {last, V});
                ?SCALARIS_RECV({next_response, V}, {ok, V})
            end
    end.

-spec generator(generator_state()) -> ok.
generator({ DS, CalcFun, NextFun }) ->
    receive
        ?SCALARIS_RECV(
            {next, Pid}, %% ->
            begin
                V = CalcFun(DS),
                case NextFun(DS) of
                    exit -> comm:send_local(Pid, {last_response, V});
                    NewDS -> comm:send_local(Pid, {next_response, V}),
                             generator({NewDS, CalcFun, NextFun})
                end
            end
          )          
    end.

-spec calc_normal(X::float(), M::float(), E::float()) -> float().
calc_normal(X, M, Dev) ->
    A = 1 / (Dev * math:sqrt(2 * math:pi())),
    B = -1/2 * math:pow(((X-M) / Dev), 2),
    A * math:pow(math:exp(1), B).

-spec calc_binomial(binomial_state()) -> float().
calc_binomial({binom, N, P, X, Approx }) ->
    case Approx of
        true -> calc_normal(X, N * P, math:sqrt(N * P * (1 - P)));
        false -> mathlib:binomial_coeff(N, X) * math:pow(P, X) * math:pow(1 - P, N - X)
    end.

-spec next_state(distribution_state()) -> distribution_state() | exit.
next_state({binom, N, _P, X, _}) when N =:= X + 1 -> 
    exit;
next_state({binom, N, P, X, Approx}) -> 
    {binom, N, P, X + 1, Approx}.

% @doc approximation is good if this conditions hold
%      SRC: http://www.vosesoftware.com/ModelRiskHelp/index.htm#Distributions/Approximating_one_distribution_with_another/Approximations_to_the_Binomial_Distribution.htm
-spec approx_valid(pos_integer(), float()) -> boolean().
approx_valid(_N, 0) -> false;
approx_valid(_N, 1) -> false;
approx_valid(N, P) ->
    One = N > ((9 * P) / (1 - P)),
    Two = N > ((9 * (1 - P)) / P),
    One andalso Two.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Tester
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec tester_create_distribution_fun(pos_integer(), 1..1000000,
                                     1..1000000) -> distribution_fun().
tester_create_distribution_fun(N, P1, P2) when P2 > P1 ->
    binomial(N, P1 / P2);
tester_create_distribution_fun(N, P1, P2) when P2 < P1 ->
    binomial(N, P2 / P1);
tester_create_distribution_fun(N, P, P) ->
    binomial(N, 0.9999999999).

