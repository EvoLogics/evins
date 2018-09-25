%% Copyright (c) 2018, Veronika Kebkal <veronika.kebkal@evologics.de>
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. The name of the author may not be used to endorse or promote products
%%    derived from this software without specific prior written permission.
%%
%% Alternatively, this software may be distributed under the terms of the
%% GNU General Public License ("GPL") version 2 as published by the Free
%% Software Foundation.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-module(mod_nl_traffic).
-behaviour(fsm_worker).

-include("fsm.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  parse_conf(Mod_ID, ArgS, Share),
  Roles = fsm_worker:role_info(Role_IDs, [nl_impl, nl]),
  [#sm{roles = Roles, module = fsm_nl_traffic}].

parse_conf(_Mod_ID, ArgS, Share) ->
  Generators_Set  = [G  || {generators, G} <- ArgS],
  Destinations_Set = [D  || {destinations, D} <- ArgS],
  Transmit_Tmo = [Time || {transmit_tmo, Time} <- ArgS],
  Traffic_Time_Set = [Time || {traffic_time_max, Time} <- ArgS],

  Generators  = set_params(Generators_Set, [1]),
  Destinations = set_params(Destinations_Set, [7]),
  Traffic_Time = set_params(Traffic_Time_Set, 1), % minutes
  {Transmit_Tmo_Start, Transmit_Tmo_End} = set_timeouts(Transmit_Tmo, {2, 2}),

  Start_time = erlang:monotonic_time(milli_seconds),
  ShareID = #sm{share = Share},
  share:put(ShareID, [{start_time, Start_time},
                      {generators, Generators},
                      {destinations, Destinations},
                      {traffic_time_max, Traffic_Time},
                      {transmit_tmo, {Transmit_Tmo_Start, Transmit_Tmo_End}}]).


set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.

set_timeouts(Tmo, Defaults) ->
  case Tmo of
    [] -> Defaults;
    [{Start, End}]-> {Start, End}
  end.
