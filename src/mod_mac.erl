%% Copyright (c) 2015, Oleksiy Kebkal <lesha@evologics.de>
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
-module(mod_mac).
-behaviour(fsm_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/4, register_fsms/4]).

% Protocols:
% csma aloha - carrer sense multiple access
% cut lohi   - conservative unsynchronized tone lohi
% aut lohi   - aggressive unsynchronized tone lohi
% dacap      - distance aware collision avoidance

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  Module =
  case P = parse_conf(ArgS, Share) of
    csma_alh  -> fsm_csma_alh;
    cut_lohi  -> fsm_t_lohi;
    aut_lohi  -> fsm_t_lohi;
    dacap     -> fsm_dacap;
    _         -> io:format("!!! ERROR, no MAC protocol with the name ~p~n", [P]),
                error
  end,
  Roles = fsm_worker:role_info(Role_IDs, [at, alh]),
  if Module =:= error->
      ?ERROR(Mod_ID, "No MAC protocol ID!~n", []);
    true ->
      [#sm{roles = [hd(Roles)], module = fsm_conf}, #sm{roles = Roles, module = Module}]
  end.


parse_conf(ArgS, Share) ->
  [Protocol]      = [P     || {mac_protocol, P} <- ArgS],
  SoundSpeedSet   = [Vel   || {sound_speed, Vel} <- ArgS],
  PMaxSet         = [Time  || {prop_time_max, Time} <- ArgS],
  TDectSet        = [Time  || {t_detect_time, Time} <- ArgS],
  DistSet         = [D     || {distance, D} <- ArgS],
  Tmo_backoff_set = [Time  || {tmo_backoff, Time} <- ArgS],
  Tmo_retransmit_set = [Time  || {tmo_retransmit, Time} <- ArgS],
  Max_rc_set         = [Retry_count    || {max_retransmit_count, Retry_count} <- ArgS],

  PMax        = set_params(PMaxSet, 500), %ms
  TDect       = set_params(TDectSet, 5),  %ms
  Sound_speed = set_params(SoundSpeedSet, 1500),  %m
  U           = set_params(DistSet, 3000),  %m
  Tmo_backoff = set_timeouts(Tmo_backoff_set, {1,3}), %s
  Max_Retry_count = set_params(Max_rc_set, 3),
  Tmo_retransmit  = set_params(Tmo_retransmit_set, 5), % ca. 2 * max Tmo_backoff -> 2 * 3 = 6

  ets:insert(Share, [{sound_speed, Sound_speed}]),
  ets:insert(Share, [{pmax, PMax}]),
  ets:insert(Share, [{tdetect, TDect}]),
  ets:insert(Share, [{max_retransmit_count, Max_Retry_count}]),
  ets:insert(Share, [{tmo_retransmit, Tmo_retransmit}]),

  case Protocol of
    cut_lohi ->
      ets:insert(Share, [{cr_time, 2 * (PMax + TDect)}]);
    aut_lohi ->
      ets:insert(Share, [{cr_time, (PMax + TDect)}]);
    dacap ->
      ets:insert(Share, [{tmo_backoff, Tmo_backoff}]),
      % TODO: duration of the data packet to be transmitted in s
      ets:insert(Share, [{t_data, 1}]),
      % max distance between nodes in the network in m
      ets:insert(Share, [{u, U}]);
    _  -> nothing
  end,
  io:format("!!! Name of current protocol ~p~n", [Protocol]),
  Protocol.

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.

set_timeouts(Tmo, Defaults) ->
  case Tmo of
    []            -> Defaults;
    [{Start, End}]-> {Start, End}
  end.
