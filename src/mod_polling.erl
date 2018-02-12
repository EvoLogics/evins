%% Copyright (c) 2015, Veronika Kebkal <veronika.kebkal@evologics.de>
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
-module(mod_polling).
-behaviour(fsm_worker).

-include("fsm.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
    fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  parse_conf(Mod_ID, ArgS, Share),
  Roles = fsm_worker:role_info(Role_IDs, [at, nl_impl, nmea]),
  [#sm{roles = [hd(Roles)], module = fsm_conf}, #sm{roles = Roles, module = fsm_polling_mux}].

parse_conf(_Mod_ID, ArgS, Share) ->
  ShareID = #sm{share = Share},

  [NL_Protocol] = [Protocol_name  || {nl_protocol, Protocol_name} <- ArgS],

  Time_wait_recv_set  = [Time  || {time_wait_recv, Time} <- ArgS],
  Max_sensitive_queue_set  = [Max  || {max_sensitive_queue, Max} <- ArgS],
  Max_packets_transmit_sens_set  = [Max  || {max_packets_sensitive_transmit, Max} <- ArgS],
  Max_packets_tolerant_transmit_set  = [Max  || {max_packets_tolerant_transmit, Max} <- ArgS],
  Max_burst_len_set  = [Max  || {max_burst_len, Max} <- ArgS],

  Time_wait_recv  = set_params(Time_wait_recv_set, 20), %s
  Max_sensitive_queue  = set_params(Max_sensitive_queue_set, 3),
  Max_burst_len  = set_params(Max_burst_len_set, 127),
  Max_packets_transmit_sens  = set_params(Max_packets_transmit_sens_set, 3),
  Max_packets_tolerant_transmit  = set_params(Max_packets_tolerant_transmit_set, 3),

  Ref =
    case [{LatRef, LonRef} || {reference_position, {LatRef, LonRef}} <- ArgS] of
      [{Lat, Lon}] -> {Lat, Lon};
      _ -> {63.444158, 10.365286}
    end,

  share:put(ShareID, reference_position, Ref),
  share:put(ShareID, [{nl_protocol, NL_Protocol}]),
  share:put(ShareID, [{time_wait_recv, Time_wait_recv}]),
  share:put(ShareID, [{max_burst_len, Max_burst_len}]),
  share:put(ShareID, [{max_sensitive_queue, Max_sensitive_queue}]),
  share:put(ShareID, [{max_packets_sensitive_transmit, Max_packets_transmit_sens}]),
  share:put(ShareID, [{max_packets_tolerant_transmit, Max_packets_tolerant_transmit}]).

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.
