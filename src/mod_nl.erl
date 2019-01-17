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
-module(mod_nl).
-behaviour(fsm_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/4, register_fsms/4]).

%%  Commands:        NL,send,<Protocol_Name>,<Dst>,<Data>
%%                   NL,recv,<Src>,<Dst>,<Data>
%%  Answers sync:    NL,ok
%%                   NL,error
%%                   NL,busy
%%  Answers async:   NL,delivered,<Src>,<Dst>
%%                   NL,failed,<Src>,<Dst>
%%  Commands:        NL,get,protocols
%%                   NL,get,protocol,<Protocol_Name>,info
%%                   NL,get,protocol,<Protocol_Name>,routing
%%                   NL,get,protocol,<Protocol_Name>,neighbours
%%                   NL,get,protocol,<Protocol_Name>,state
%%                   NL,get,protocol,<Protocol_Name>,states
%%                   NL,get,stats,<Protocol_Name>,paths
%%                   NL,get,stats,<Protocol_Name>,neighbours
%%                   NL,get,stats,<Protocol_Name>,data
%%
%%                   For debug:
%%                   NL,get,fsm,state
%%                   NL,get,fsm,states
%%                   NL,get,protocol,<Protocol_Name>,state
%%                   NL,get,protocol,<Protocol_Name>,states
%% Static:
%% + staticr         - Static routing
%% + staticrack      - Static routing with acknowledgement
%%
%% Flooding:
%% + sncfloodr       - Sequence Number Controlled Flooding
%% + sncfloodrack    - Sequence Number Controlled Flooding with acknowledgement
%% + dpfloodr        - Dynamic Probabilistic Flooding
%% + dpfloodrack     - Dynamic Probabilistic Flooding with acknowledgement
%% + icrpr           - Information carrying routing protocol
%%
%% Path finding
%% + sncfloodpfr     - Pathfind and relay, based on sequence number controlled flooding
%% + sncfloodpfrack  - Pathfind and relay, based on sequence number controlled flooding with acknowledgement
%% + evoicrppfr      - based on ICRP protocol (Information carrying based routing protocol)
%%                     Pathfind and relay, based on sequence number controlled flooding, path is chosend using Rssi and Integrity of Evo DMACE Header
%% + evoicrppfrack   - Evologics information carrying routing protocol, path find and relay protocol with acknowledgement
%% + dblfloodpfr     - Double flooding path finder, two flooding waves to find path and 1 wave to send path back
%% + dblfloodpfrack  - Double flooding path finder with acknowledgement
%% + laorp           - Low overhead routing protocol
%%
%% TODO: Max number protocol is p7, temporaly all bigger than 7, are equal 7

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  CurrentProtocol = parse_conf(Mod_ID, ArgS, Share),

  InsideList = lists:filter(fun(X) -> X =:= CurrentProtocol end, ?LIST_ALL_PROTOCOLS),
  if InsideList =:= [] ->
    ?ERROR(Mod_ID, "!!!  ERROR, no network layer protocol with the name ~p~n", [CurrentProtocol]),
    io:format("!!! ERROR, no network layer protocol with the name ~p~n", [CurrentProtocol]);
  true -> nothing
  end,

  lists:foldr(
    fun(X, _)->
      [ParamsTmp, SMTmp] = conf_fsm(X),
      conf_protocol(CurrentProtocol, Share, X, ParamsTmp, SMTmp)
    end, [], ?LIST_ALL_PROTOCOLS),

  Module = conf_fsm(CurrentProtocol),
  if Module =:= error ->
    ?ERROR(Mod_ID, "!!! No NL protocol ID!~n", []);
  true ->
    [_, SMN] = Module,
    ShareID = #sm{share = Share},
    La = share:get(ShareID, local_address),
    Share_file_path = case [P || {share_file_path,P} <- ArgS] of [] -> "."; [P] -> P end,
    DetsName = lists:flatten([Share_file_path,"/","share_file_",integer_to_list(La)]),
    Roles = fsm_worker:role_info(Role_IDs, [at, at_impl, nl, nl_impl]),
    {ok, Ref} = dets:open_file(DetsName,[]),
    [#sm{roles = [hd(Roles)], module = fsm_conf}, #sm{roles = Roles, dets_share = Ref, module = SMN}]
  end.
%%-------------------------------------- Parse config file ---------------------------------
parse_conf(Mod_ID, ArgS, Share) ->
  [NL_Protocol] = [Protocol_name  || {nl_protocol, Protocol_name} <- ArgS],
  Addr_set      = [Addrs          || {local_addr, Addrs} <- ArgS],
  Blacklist_set = [Addrs          || {blacklist, Addrs} <- ArgS],
  Routing       = [Addrs          || {routing, Addrs} <- ArgS],
  Max_address_set = [Addrs        || {max_address, Addrs} <- ArgS],
  Prob_set      = [P              || {probability, P} <- ArgS],
  Max_hops_Set  = [Hops           || {max_hops, Hops} <- ArgS],
  Pkg_life_Set  = [Time           || {pkg_life, Time} <- ArgS],

  Tmo_wv            = [Time || {tmo_wv, Time} <- ArgS],
  Tmo_wack          = [Time || {tmo_wack, Time} <- ArgS],
  STmo_path         = [Time || {stmo_path, Time} <- ArgS],
  WTmo_path_set     = [Time || {wtmo_path, Time} <- ArgS],
  Tmo_Neighbour_set = [Time || {tmo_neighbour, Time} <- ArgS],
  Path_life_set     = [Time || {path_life, Time} <- ArgS],
  Neighbour_life_set= [Time || {neighbour_life, Time} <- ArgS],
  Tmo_dbl_wv_set    = [Time || {tmo_dbl_wv, Time} <- ArgS],

  Local_retries_set  = [C   || {retries, C} <- ArgS],
  TTL_set  = [C   || {ttl, C} <- ArgS],
  Tmo_sensing  = [Time || {tmo_sensing, Time} <- ArgS],

  Path_retries_set  = [C   || {path_retries, C} <- ArgS],

  Max_TTL        = set_params(TTL_set, 20),
  Local_retries  = set_params(Local_retries_set, 3), % optimal 3, % optimal 4 for icrpr
  {Tmo_sensing_start, Tmo_sensing_end} = set_timeouts(Tmo_sensing, {0, 1}), % optimal aloha {0,1}
                                                                            % optimal tlohi {1,5} / {0,4}
                                                                            % optimal for ack {2, 5}

  Path_retries    = set_params(Path_retries_set, 2),
  Addr            = set_params(Addr_set, 1),
  Max_address     = set_params(Max_address_set, 20),
  Pkg_life        = set_params(Pkg_life_Set, 180), % in sek

  {Wwv_tmo_start, Wwv_tmo_end}    = set_timeouts(Tmo_wv, {0.3, 2}),
  {Wack_tmo_start, Wack_tmo_end}  = set_timeouts(Tmo_wack, {1, 2}),
  {Spath_tmo_start, Spath_tmo_end}= set_timeouts(STmo_path, {1, 2}),

  Blacklist                       = set_blacklist(Blacklist_set, []),
  Routing_table                   = set_routing(Routing, NL_Protocol, ?ADDRESS_MAX),
  Probability                     = set_params(Prob_set, {0.4, 0.9}),

  Max_hops = set_params(Max_hops_Set, 3),
  %RTT = count_RTT(Max_hops, Wwv_tmo_end, Wack_tmo_end),
  RTT = count_RTT(Max_hops, Tmo_sensing_end),

  Default_Tmo_Neighbour = 5 + round(Spath_tmo_end),
  Tmo_Neighbour   = set_params(Tmo_Neighbour_set, Default_Tmo_Neighbour),
  Tmo_dbl_wv      = set_params(Tmo_dbl_wv_set, Tmo_Neighbour + 1),
  WTmo_path       = set_params(WTmo_path_set, RTT + RTT/2),

  Path_life       = set_params(Path_life_set, 2 * WTmo_path),
  Neighbour_life  = set_params(Neighbour_life_set, WTmo_path),

  Start_time = erlang:monotonic_time(milli_seconds),
  ShareID = #sm{share = Share},
  share:put(ShareID, [{nl_start_time, Start_time},
                      {nl_protocol, NL_Protocol},
                      {routing_table, Routing_table},
                      {local_address, Addr},
                      {max_address, Max_address},
                      {blacklist, Blacklist},
                      {wwv_tmo,   {Wwv_tmo_start, Wwv_tmo_end} },
                      {wack_tmo,  {Wack_tmo_start, Wack_tmo_end} },
                      {spath_tmo, {Spath_tmo_start, Spath_tmo_end} },
                      {wpath_tmo, WTmo_path},
                      {neighbour_tmo, Tmo_Neighbour},
                      {max_rtt, 2 * RTT},
                      {min_rtt, RTT},
                      {path_life, Path_life},
                      {neighbour_life, Neighbour_life},
                      {max_pkg_id, ?PKG_ID_MAX},
                      {rtt, RTT + RTT/2},
                      {send_wv_dbl_tmo, Tmo_dbl_wv},
                      {probability, Probability},
                      {pkg_life, Pkg_life},
                      {retries, Local_retries},
                      {path_retries, Path_retries},
                      {ttl, Max_TTL},
                      {tmo_sensing, {Tmo_sensing_start, Tmo_sensing_end}}
                     ]),

  ?TRACE(Mod_ID, "NL Protocol ~p ~n", [NL_Protocol]),
  ?TRACE(Mod_ID, "Routing Table ~p ~n", [Routing_table]),
  ?TRACE(Mod_ID, "Local address ~p ~n", [Addr]),
  ?TRACE(Mod_ID, "MAX local address ~p ~n", [Max_address]),
  ?TRACE(Mod_ID, "Blacklist ~p ~n", [Blacklist]),
  ?TRACE(Mod_ID, "Probability ~p ~n", [Probability]),
  ?TRACE(Mod_ID, "Max RTT ~p Start RTT ~p ~n", [2 * RTT, RTT + RTT/2]),
  ?TRACE(Mod_ID, "Tmo_Neighbour ~p ~n", [Tmo_Neighbour]),
  ?TRACE(Mod_ID, "Wait Tmo_path ~p ~n", [WTmo_path]),
  ?TRACE(Mod_ID, "Path_life ~p ~n", [Path_life]),
  ?TRACE(Mod_ID, "Neighbour_life ~p ~n", [Neighbour_life]),
  ?TRACE(Mod_ID, "Pkg_life ~p ~n", [Pkg_life]),
  ?TRACE(Mod_ID, "Retries ~p ~n", [Local_retries]),
  ?TRACE(Mod_ID, "Sensing time {~p,~p} ~n", [Tmo_sensing_start, Tmo_sensing_end]),

  NL_Protocol.

count_RTT(Max_hops, Time) ->
  2 * Max_hops * (Time + 1).

conf_fsm(Protocol) ->
  [{_, Decr}] = lists:filter(fun({PN, _})-> PN =:= Protocol end, ?PROTOCOL_CONF),
  Decr.

conf_protocol(CurrentProtocol, Share, Protocol, Params, SMName) ->
  ShareID = #sm{share = Share},
  if (CurrentProtocol =:= Protocol) ->
      share:put(ShareID, protocol_name, Protocol);
    true -> nothing
  end,
  parse_pr_params(Share, Params, Protocol),
  SMName.

parse_pr_params(Share, Params, Protocol) ->
  ShareID = #sm{share = Share},
  NP = #pr_conf{},
  List_config = lists:foldr(
    fun(LP, A) ->
      R = lists:filter(fun(P)-> P =:= LP end, tuple_to_list(Params)),
      if R =/= [] -> [PR] = R, [PR | A];
      true -> A
      end
    end, [], ?LIST_ALL_PARAMS),
  Config = lists:foldr(fun(X, NPP) ->
      setelement(get_nfield(X), NPP, true)
    end, NP, List_config),
  share:put(ShareID, protocol_config, Protocol, Config).

get_nfield(Param) ->
  {_, FNumber}=
    lists:foldr(
      fun(X, {Found, Num}) ->
        case Param of
          X -> {f, Num};
          _ when Found =:= nf -> {Found, Num + 1};
          _ -> {Found, Num}
        end
      end, {nf, 1}, lists:reverse(?LIST_ALL_PARAMS)),
    FNumber + 1.

set_blacklist([], Default) -> Default;
set_blacklist([Blacklist], _) -> Blacklist.

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

set_routing(Routing, Protocol, Default) ->
  case Protocol of
    _ when ( ((Protocol =:= staticr) or (Protocol =:= staticrack)) and (Routing =:= [])) ->
      io:format("!!! Static routing needs to set addesses in routing table, no parameters in config file. ~n!!! As a default value will be set 255 broadcast ~n",[]),
      Default;
    _ when (Routing =/= []) ->
      [TupleRouting] = Routing,
      [{?ADDRESS_MAX, ?ADDRESS_MAX} | tuple_to_list(TupleRouting)];
    _ -> Default
  end.
