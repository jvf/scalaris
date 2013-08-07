% @copyright 2010-2011 Zuse Institute Berlin

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
%% @doc    Hash Function Set Behaviour
%% @end
%% @version $Id$

% export
-export([new/1, new/2, apply_val/2, apply_val/3, apply_val_rem/3]).
-export([size/1]).

% types
-type itemKey() :: any().
-type hfs()     :: hfs_t(). %todo make opaque

-ifdef(with_export_type_support).
-export_type([hfs/0]).
-endif.

% API functions

-spec new([hfs_fun(),...], pos_integer()) -> hfs().
new(HashFunList, HashFunCount) -> new_(HashFunList, HashFunCount).

-spec new(pos_integer()) -> hfs().
new(HFCount) -> new_(HFCount).

-spec apply_val(hfs(), itemKey()) -> [non_neg_integer()].
apply_val(Hfs, Item) -> apply_val_(Hfs, Item).

% @doc apply Item on hash function I of function set Hfs; I = 1..hfs_size
-spec apply_val(hfs(), pos_integer(), itemKey()) -> non_neg_integer().
apply_val(Hfs, I, Item) -> apply_val_(Hfs, I, Item).

-spec apply_val_rem(hfs(), itemKey(), pos_integer()) -> [non_neg_integer()].
apply_val_rem(Hfs, Item, Rem) -> apply_val_rem_(Hfs, Item, Rem).

% @doc returns the number of hash functions in the set
-spec size(hfs()) -> pos_integer().
size(Hfsc) -> size_(Hfsc).
