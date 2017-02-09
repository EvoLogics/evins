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
-module(mod_mux_nl).
-behaviour(fsm_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  parse_conf(Mod_ID, ArgS, Share),
  Roles = fsm_worker:role_info(Role_IDs, [nl_mux, nl]),
  [#sm{roles = Roles, module = fsm_mux_nl}].

parse_conf(_Mod_ID, ArgS, Share) ->
  Time_discovery_set  = [Time  || {time_discovery, Time} <- ArgS],
  Discovery_perod_set = [Time  || {discovery_perod, Time} <- ArgS],
  Protocols_set = [P  || {protocols, P} <- ArgS],

  Time_discovery  = set_params(Time_discovery_set, 15), %s
  Discovery_perod = set_params(Discovery_perod_set, 5), %s

  ShareID = #sm{share = Share},

  set_protocols(ShareID, Protocols_set, [{discovery, sncfloodr}, {burst, staticr}]),
  share:put(ShareID, [{time_discovery, Time_discovery},
                      {discovery_perod, Discovery_perod}]).

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.

set_protocols(ShareID, Protocols_set, Default) ->
 Protocols =
  lists:filtermap(
    fun(X) ->
      {Protocol_type, _} = X,
      IfConf = lists:keyfind(Protocol_type, 1, Protocols_set),
      case IfConf of
        false -> {true, X};
        _ -> {true, IfConf}
      end
    end, Default),

  lists:map(
    fun(X) ->
      case X of
        {discovery, P} ->
          share:put(ShareID, [{discovery_protocol, P}]);
        {burst, P} ->
          share:put(ShareID, [{burst_protocol, P}]);
        _ -> nothing
      end
    end, Protocols).
