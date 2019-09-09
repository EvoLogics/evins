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
-module(mod_nl_burst).
-behaviour(fsm_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
    fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  parse_conf(Mod_ID, ArgS, Share),
  Roles = fsm_worker:role_info(Role_IDs, [at, nl_impl]),
  Logger = case lists:keyfind(logger, 1, ArgS) of
             {logger,L} -> L; _ -> nothing
           end,
  [#sm{roles = [hd(Roles)], module = fsm_conf}, #sm{roles = Roles, logger = Logger, module = fsm_nl_burst}].


parse_conf(Mod_ID, ArgS, Share) ->
  ShareID = #sm{share = Share},
  Start_time = erlang:monotonic_time(milli_seconds),
  [NL_Protocol] = [Protocol_name  || {nl_protocol, Protocol_name} <- ArgS],
  Max_queue_set = [Addrs          || {max_queue, Addrs} <- ArgS],
  Max_burst_len_set  = [Max  || {max_burst_len, Max} <- ArgS],
  Wait_ack_set  = [Time  || {wait_ack, Time} <- ArgS],
  Send_ack_set  = [Time  || {send_ack_tmo, Time} <- ArgS],
  Update_retries_set = [P  || {update_retries, P} <- ArgS],
  Tmo_transmit = [Time || {tmo_transmit, Time} <- ArgS],
  Delay_set = [Time || {transmission_delay, Time} <- ArgS],
  Retransmissions_set = [P  || {retransmissions_allowed, P} <- ArgS],

  Max_queue  = set_params(Max_queue_set, 3),
  Wait_ack  = set_params(Wait_ack_set, 120), %s
  Send_ack  = set_params(Send_ack_set, 3),
  Max_burst_len  = set_params(Max_burst_len_set, Max_queue * 1000),
  Update_retries  = set_params(Update_retries_set, 1),
  Delay = set_params(Delay_set, 1), %s
  Retransmissions = set_params(Retransmissions_set, true), %s

  {Tmo_start, Tmo_end}    = set_timeouts(Tmo_transmit, {1, 4}),

  share:put(ShareID, [{nl_start_time, Start_time},
                      {nl_protocol, NL_Protocol},
                      {max_queue, Max_queue},
                      {wait_ack, Wait_ack},
                      {send_ack_tmo, Send_ack},
                      {max_burst_len, Max_burst_len},
                      {transmission_delay, Delay},
                      {retransmissions_allowed, Retransmissions},
                      {tmo_transmit,   {Tmo_start, Tmo_end}},
                      {update_retries, Update_retries}]),

  ?TRACE(Mod_ID, "NL Protocol ~p ~n", [NL_Protocol]).

set_timeouts(Tmo, Defaults) ->
  case Tmo of
    [] -> Defaults;
    [{Start, End}]-> {Start, End}
  end.

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.
