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
%% + icrp            - Information carrying routing protocol
%%
%% Path finding
%% + sncfloodpfr     - Pathfind and relay, based on sequence number controlled flooding
%% + sncfloodpfrack  - Pathfind and relay, based on sequence number controlled flooding with acknowledgement
%% + evoicrppfr      - based on ICRP protocol (Information carrying based routing protocol)
%%                     Pathfind and relay, based on sequence number controlled flooding, path is chosend using Rssi and Integrity of Evo DMACE Header
%% + evoicrppfrack   - Evologics information carrying routing protocol, path find and relay protocol with acknowledgement
%% + dbfloodpfr      - Double flooding path finder, two flooding waves to find path and 1 wave to send path back
%% + dbfloodpfrack   - Double flooding path finder with acknowledgement
%% + laorp           - Low overhead routing protocol
%%
%% TODO: Max number protocol is p7, temporaly all bigger than 7, are equal 7

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
    fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
    CurrentProtocol = parse_conf(ArgS, Share),
    lists:foldr(fun(X,_)-> [PIDTmp, ParamsTmp, SMTmp] = conf_fsm(X), conf_protocol(CurrentProtocol, Share, X, PIDTmp, ParamsTmp, SMTmp) end, [], ?LIST_ALL_PROTOCOLS),

    Module = conf_fsm(CurrentProtocol),
    if Module =:= error ->  ?ERROR(Mod_ID, "!!! No NL protocol ID!~n", []);
       true ->
	    [_,_, SMN] = Module,
        [{local_address, La}] = ets:lookup(Share, local_address),
        DetsName = list_to_atom(atom_to_list(share_file_) ++ integer_to_list(La)),
	    Roles = fsm_worker:role_info(Role_IDs, [alh, nl]),
        {ok,Ref} = dets:open_file(DetsName,[]),
	    [#sm{roles = Roles, dets_share = Ref, module = SMN}]
    end.
%%-------------------------------------- Parse config file ---------------------------------
parse_conf(ArgS, Share) ->
    [NL_Protocol] =     [Protocol_name   || {nl_protocol, Protocol_name} <- ArgS],
    Addr_set =          [Addrs           || {local_addr, Addrs} <- ArgS],
    Bll_addrs =         [Addrs           || {bll_addrs, Addrs} <- ArgS],
    Routing_addrs =     [Addrs           || {routing, Addrs} <- ArgS],
    Max_hops_set =      [Count_hops      || {max_hops, Count_hops} <- ArgS],
    Max_rc_set  =       [Retry_count     || {max_retry_count, Retry_count} <- ArgS],
    Prob_set  =         [P               || {probability, P} <- ArgS],

    Tmo_wv =            [Time            || {tmo_wv, Time} <- ArgS],
    STmo_path =         [Time            || {stmo_path, Time} <- ArgS],
    WTmo_path_set =     [Time            || {wtmo_path, Time} <- ArgS],
    Tmo_Neighbour_set = [Time            || {tmo_neighbour, Time} <- ArgS],
    Path_life_set     = [Time            || {path_life, Time} <- ArgS],
    Neighbour_life_set= [Time            || {neighbour_life, Time} <- ArgS],
    Tmo_dbl_wv_set =    [Time            || {tmo_dbl_wv, Time} <- ArgS],

    Addr                             = set_params(Addr_set, 1),
    RTT                              = set_params(Max_hops_set, 60),
    Max_Retry_count                  = set_params(Max_rc_set, 2),
    WTmo_path                        = set_params(WTmo_path_set, 30),
    Tmo_Neighbour                    = set_params(Tmo_Neighbour_set, 30),
    Tmo_dbl_wv                       = set_params(Tmo_dbl_wv_set, 10),
    Path_life                        = set_params(Path_life_set, 120),
    Neighbour_life                   = set_params(Neighbour_life_set, 120),

    {Wwv_tmo_start, Wwv_tmo_end}     = set_timeouts(Tmo_wv, {1,3}),
    {Wack_tmo_start, Wack_tmo_end}   = set_timeouts(Tmo_wv, {1,3}),
    {Spath_tmo_start, Spath_tmo_end} = set_timeouts(STmo_path, {2,4}),
    Blacklist                        = set_blacklist(Bll_addrs, []),
    Routing_table                    = set_routing(Routing_addrs, NL_Protocol, 255),
    Probability                      = set_params(Prob_set, {0.4, 0.9}),

    ets:insert(Share, [{nl_protocol, NL_Protocol}]),
    ets:insert(Share, [{routing_table, Routing_table}]),
    ets:insert(Share, [{local_address, Addr}]),
    ets:insert(Share, [{blacklist, Blacklist}]),
    ets:insert(Share, [{wwv_tmo,   {Wwv_tmo_start, Wwv_tmo_end} }]),
    ets:insert(Share, [{wack_tmo,  {Wack_tmo_start, Wack_tmo_end} }]),
    ets:insert(Share, [{spath_tmo, {Spath_tmo_start, Spath_tmo_end} }]),
    ets:insert(Share, [{wpath_tmo, WTmo_path}]),
    ets:insert(Share, [{neighbour_tmo, Tmo_Neighbour}]),
    ets:insert(Share, [{max_rtt, 2 * RTT}]),
    ets:insert(Share, [{path_life, Path_life}]),
    ets:insert(Share, [{neighbour_life, Neighbour_life}]),
    ets:insert(Share, [{max_pkg_id, 255}]),
    ets:insert(Share, [{rtt, RTT}]),
    ets:insert(Share, [{max_retry_count, Max_Retry_count}]),
    ets:insert(Share, [{send_wv_dbl_tmo, Tmo_dbl_wv}]),
    ets:insert(Share, [{probability, Probability}]),
    NL_Protocol.

conf_fsm(Protocol) ->
    [{_, Decr}] = lists:filter(fun({PN,_})-> PN =:= Protocol end, ?PROTOCOL_CONF),
    Decr.

conf_protocol(CurrentProtocol, Share, Protocol, Pid, Params, SMName) ->
    if (CurrentProtocol =:= Protocol) ->
	    ets:insert(Share, [{pid, Pid}]),
	    ets:insert(Share, [{np,  Protocol}]);
       true -> nothing
    end,
    parse_pr_params(Share, Params, Protocol),
    SMName.

parse_pr_params(Share, Params, Protocol) ->
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
    ets:insert(Share, [{ {protocol_config, Protocol}, Config }]).

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

set_blacklist(Bll_addrs, Default) ->
    case Bll_addrs of
        [] -> Default;
        [Addrs] -> if is_tuple(Addrs) -> tuple_to_list(Addrs); true -> error end
    end.

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

set_routing(Routing_addrs, NL_Protocol, Default) ->
    case NL_Protocol of
        _ when ( ((NL_Protocol =:= staticr) or (NL_Protocol =:= staticrack)) and (Routing_addrs=/=[])) ->
	    [TupleRouting] = Routing_addrs, [{255,255} | tuple_to_list(TupleRouting)];
        _ when ( ((NL_Protocol =:= staticr) or (NL_Protocol =:= staticrack)) and (Routing_addrs=:=[])) ->
	    io:format("!!! Static routing needs to set addesses in routing table, no parameters in config file. \n!!! As a defualt value will be set 255 broadcast"), Default;
        _ -> Default
    end.
