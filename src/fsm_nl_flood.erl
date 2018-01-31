%% Copyright (c) 2015, Veronika Kebkal <veronika.kebkal@evologics.de>
%%                     Oleksiy Kebkal <lesha@evologics.de>
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
-module(fsm_nl_flood).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_final/3]).
-export([handle_swv/3, handle_rwv/3]).
-export([handle_wack/3, handle_sack/3]).
-export([handle_wpath/3, handle_spath/3]).

%%  Flooding Flood is a communication primitive that can be initiated by
%%  the base station of a sensor network to send a copy of some message
%%  to every sensor in the network. When a flood of some message is initiated,
%%  the message is forwarded by every sensor that receives the message until
%%  the sensors decide not to forward the message any more.
%%
%%  http://en.wikipedia.org/wiki/Flooding_(computer_networking)
%%
%%  sncf - Sequence Number Controlled Flooding, the node attaches its own
%%  address and sequence number to the packet, since every node has a memory
%%  of addresses and sequence numbers. If it receives a packet in memory, it
%%  drops it immediately
%%
%% Evologics specification:
%%
%% 1. Allowed are only instant messages (“*SENDIM”, DMACE protocol)
%% 2. For protocols with pf and ack not allowed destination address - 255 (broadcast)
%%
%%  Abbreviation:
%%  ll  - lower layer
%%  ul  - upper layer
%%  RTT - round trip time
%%  pf  - path finder

-define(TRANS, [
                {idle,
                 [{init,  idle},
                  {not_relay, idle},
                  {rcv_wv, rwv},
                  {send_wv, swv},
                  {send_path, spath}
                 ]},

                {swv,
                 [{relay_wv,  swv},
                  {error, idle},
                  {rcv_wv,  rwv},
                  {noack_data_sent, idle},
                  {wait_ack, wack},
                  {wait_pf, wpath},
                  {rcv_ack, idle},
                  {rcv_path, idle}
                 ]},

                {rwv,
                 [{relay_wv, swv},
                  {send_ack, sack},
                  {send_path, spath},
                  {rcv_wv, rwv},
                  {dst_reached, idle}
                 ]},

                {wack,
                 [{timeout_ack, idle},
                 {dst_rcv_ack, idle},
                 {relay_wv, swv},
                 {send_ack, sack},
                 {rcv_wv, wack}
                 ]},

                {wpath,
                 [{error, idle},
                  {timeout_path,idle},
                  {send_data, idle},
                  {relay_wv, swv},
                  {rcv_wv, wpath},
                  {send_ack, sack},
                  {dst_rcv_path,swv}
                 ]},

                {sack,
                 [{error, idle},
                  {ack_data_sent,idle}
                 ]},

                {spath,
                 [{error, idle},
                  {wait_pf, wpath},
                  {path_data_sent, idle}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> init.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  ?TRACE(?ID, "handle_event ~120p~n", [Term]),
  Local_address = share:get(SM, local_address),
  NProtocol = share:get(SM, nlp),
  Protocol  = share:get(SM, {protocol_config, NProtocol}),
  Pid = share:get(SM, pid),
  case Term of
    {timeout, Event} ->
      ?INFO(?ID, "timeout ~140p~n", [Event]),
      case Event of
        {drop_pkg, Tuple} ->
          Q = share:get(SM, queue_ids),
          NQ = nl_mac_hf:deleteQKey(Q, Tuple, queue:new()),
          share:put(SM, queue_ids, NQ),
          SM;
        {path_life, Tuple} ->
          nl_mac_hf:process_path_life(SM, Tuple);
        {neighbour_life, Addr} ->
          %% TODO: if neighbour does not exist any more, delete from routing table
          Neighbours_channel = share:get(SM, neighbours_channel),
          El = lists:keyfind(Addr, 1, Neighbours_channel),
          Updated_neighbours_channel = lists:delete(El, Neighbours_channel),
          share:put(SM, neighbours_channel, Updated_neighbours_channel),
          share:update_with(SM, current_neighbours, fun(L) -> lists:delete(Addr, L) end);
        {relay_wv, Tuple = {send, {Flag, _}, _}} ->
          [SMN, PTuple] = nl_mac_hf:process_relay(SM, Tuple),
          case PTuple of
            not_relay when (Flag =:= path) ->
              fsm:run_event(MM, SMN#sm{event = not_relay, state=idle}, {});
            not_relay ->
              SM;
            _ ->
              fsm:run_event(MM, SMN#sm{event=relay_wv,  state=swv}, PTuple)
          end;
        {send_ack, PkgID, Tuple} ->
          fsm:run_event(MM, SM#sm{event=send_ack,   state=rwv}, {send_ack,  PkgID, Tuple});
        {send_path, PkgID, Tuple} ->
          fsm:run_event(MM, SM#sm{event=send_path,  state=rwv}, {send_path, PkgID, Tuple});
        {wack_timeout, {_Packet_id, Real_src, Real_dst}} ->
          case share:get(SM, current_pkg) of
            {nl, send, _, Payload} ->
              nl_mac_hf:analyse(SM, st_data, {Payload, Real_dst, 0, "Failed"}, {Real_src, Real_dst});
            _ ->
              nothing
          end,
          nl_mac_hf:smooth_RTT(SM, reverse, {rtt, Local_address, Real_dst}),
          if (Real_src =:= Local_address) ->
               fsm:cast(SM, nl_impl, {send, {nl, failed, 0, Real_src, Real_dst}});
             true ->
               nothing
          end,
          fsm:run_event(MM, SM#sm{event=timeout_ack,  state=wack}, {});
        {wpath_timeout, {_Packet_id, Real_src, Real_dst}} ->
          case share:get(SM, current_pkg) of
            {nl, send, _, Payload} ->
              nl_mac_hf:analyse(SM, st_data, {Payload, Real_dst, 0, "Failed"}, {Real_src, Real_dst});
            _ ->
              nothing
          end,
          if ((Real_src =:= Local_address) and Protocol#pr_conf.ack) ->
               fsm:cast(SM, nl_impl, {send, {nl, failed, 0, Real_src, Real_dst}});
             true -> nothing
          end,
          fsm:run_event(MM, SM#sm{event=timeout_path,  state = wpath}, {});
        {send_wv_dbl, {Flag,[_,Real_src, PAdditional]}, {nl, send, Real_dst, Data}} ->
          PkgID = nl_mac_hf:increase_pkgid(SM, Real_src, Real_dst),
          Params = {Flag,[PkgID, Real_dst, PAdditional]},
          fsm:run_event(MM, SM#sm{state = idle, event=send_path}, {send_path, Params, {nl, send, Real_src, Data}});
        _ ->
          fsm:run_event(MM, SM#sm{event=Event}, {})
      end;
    {allowed} when MM#mm.role == at ->
      NPid = share:get(SM, {pid, MM}),
      ?INFO(?ID, ">>>>>> Pid: ~p~n", [NPid]),
      share:put(SM, pid, NPid),
      SM;
    {connected} ->
      SM;
    {disconnected, _} ->
      ?INFO(?ID, "disconnected ~n", []),
      SM;
    {sync, _, _} ->
      %% case NLMsg = share:get(SM, last_nl_sent) of
      case share:get(SM, last_nl_sent) of
        %% rcv sync message for NL
        {send, {Flag, [_, Real_src, _]}, _} ->
          Print_to_NL = if_print_to_nl(SM, Real_src, Flag),
          share:put(SM, path_exists, false),
          SMC =
          case parse_ll_msg(SM, Term) of
            [SMN, NT = {nl, send, busy}] ->
              % !!!!!!!!!!!!!! TODO: if busy, how much should be transmitted?
              %fsm:set_timeout(SMN#sm{event = eps}, {s, 2}, {relay_wv, NLMsg});
              fsm:cast(SMN, nl_impl, {send, NT});
            [SMN, NT] when Print_to_NL == true, NT =/= nothing ->
              fsm:cast(SMN, nl_impl, {send, NT});
            _ ->
              SM
          end,
          share:clean(SM, last_nl_sent),
          SMC;
        _ -> % rcv sync message not for NL
          SM
      end;

    {async, {delivered, mac, BDst}} ->
      fsm:cast(SM, nl_impl, {send, {nl, delivered, 0, Local_address, BDst}});
    {async, {failed, mac, BDst}} ->
      fsm:cast(SM, nl_impl, {send, {nl, failed, 0, Local_address, BDst}});
    {async, {pid, Pid}, Tuple} ->
      ?INFO(?ID, "My message: ~p~n", [Tuple]),
      [SMN, NT] = parse_ll_msg(SM, {async, Tuple}),
      ?INFO(?ID, "parse_ll_msg: ~p~n", [NT]),
      case NT of
        nothing ->
          SMN;
        {relay, Params, RTuple = {nl, send, Real_dst, Payl}} ->
          NTuple=
          case Params of
          {ack, _} ->
            Count_hops = nl_mac_hf:extract_ack(SM, Payl),
            BCount_hops = nl_mac_hf:create_ack(Count_hops + 1),
            {nl,send, Real_dst, BCount_hops};
          _ ->
            RTuple
          end,
          fsm:run_event(MM, SMN#sm{event=rcv_wv}, {relay_wv, Params, NTuple});
        {rcv_processed, {data, _}, DTuple} ->
          {nl,recv,ISrc,IDst,Payload} = DTuple,
          {_, NData, _} = nl_mac_hf:parse_path_data(SM, Payload),
          fsm:cast(SM, nl_impl, {send, {nl, recv, ISrc, IDst, NData}});
        {dst_reached, Params, DTuple} ->
          SMN1 = nl_mac_hf:save_path(SMN, Params, DTuple),
          fsm:run_event(MM, SMN1#sm{event=rcv_wv}, {dst_reached, Params, DTuple});
        {dst_and_relay, DstTuple, RyTuple} ->
          {dst_reached, {Flag,_}, Send_tuple} = DstTuple,
          {nl, recv, ISrc, IDst, BData} = Send_tuple,
          {_, NData, _} = nl_mac_hf:parse_path_data(SM, BData),
          BroadcastTuple = {nl, recv, ISrc, IDst, NData},
          case Flag of
            data when ISrc =/= Local_address ->
              fsm:cast(SMN, nl_impl, {send, BroadcastTuple});
            _ -> nothing
          end,
          case RyTuple of
            {rcv_processed,_,_} ->
              SMN;
            {relay, Params, RDTuple} ->
              fsm:run_event(MM, SMN#sm{event=rcv_wv}, {relay_wv, Params, RDTuple })
          end;
        _ ->
          SMN
        end;
    {async, {pid, _}, Tuple} ->
      ?INFO(?ID, "Overheard message: ~p~n", [Tuple]),
      {Src, Rssi, Integrity} =
        case Tuple of
          {recvpbm,_,ISrc,_,_,  IRssi,IIntegrity,_,_} ->
            {ISrc, IRssi, IIntegrity};
          {Recv   ,_,ISrc,_,_,_,IRssi,IIntegrity,_,_} when Recv == recvim; Recv == recvims; Recv == recv ->
            {ISrc, IRssi, IIntegrity}
        end,
      case nl_mac_hf:add_neighbours(SM, overheard, Src, {nothing, nothing}, {Rssi, Integrity}) of
        neighbours_other_format -> SM;
        SMN -> SMN
      end;
    {nl,error,_} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}}),
      SM;
    {nl, reset, state} ->
      fsm:cast(SM, at, {send, {at, "Z1", ""}}),
      %fsm:send_at_command(SM, {at, "Z1", ""}),
      fsm:cast(SM, nl_impl, {send, {nl, state, ok}}),
      SM#sm{state = idle};
    {nl, clear, statistics, data} ->
      share:clean(SM, st_data),
      share:put(SM, st_data, queue:new()),
      fsm:cast(SM, nl_impl, {send, {nl, statistics, data, empty}});
    {nl, get, protocol} ->
      fsm:cast(SM, nl_impl, {send, {nl, protocol, share:get(SM, nlp)}});
    {nl, get, help} ->
      fsm:cast(SM, nl_impl, {send, {nl, help, ?HELP}});
    {nl, get, version} ->
      %% FIXME: define rultes to generate version
      fsm:cast(SM, nl_impl, {send, {nl, version, 0, 1, "emb"}});
    {nl, get, statistics, Some_statistics} ->
      nl_mac_hf:process_command(SM, false, {statistics, Some_statistics});
    {nl, get, protocolinfo, Some_protocol} ->
      nl_mac_hf:process_command(SM, false, {protocolinfo, Some_protocol});
    {nl,get,time,monotonic} ->
      Current_time = erlang:monotonic_time(milli_seconds) - share:get(SM, nl_start_time),
      fsm:cast(SM, nl_impl, {send, {nl, time, monotonic, Current_time}});
    {nl, get, Command} ->
      nl_mac_hf:process_command(SM, false, Command);
    {nl, set, address, Addr} ->
      share:put(SM, local_address, Addr),
      fsm:cast(SM, nl_impl, {send, {nl, address, Addr}});
    {nl, set, neighbours, NL} when NProtocol =:= staticr;
                                   NProtocol =:= staticrack ->
      case NL of
        empty ->
          share:put(SM, current_neighbours, []),
          share:put(SM, neighbours_channel, []);
        [H|_] when is_integer(H) ->
          share:put(SM, current_neighbours, NL),
          share:put(SM, neighbours_channel, NL);
        _ ->
          CurrentTime = erlang:monotonic_time(milli_seconds),
          Neighbours_channel = [ {A, I, R, CurrentTime - T } || {A, I, R, T} <- NL],
          Neighbours = [ A || {A, _, _, _} <- NL],
          share:put(SM, neighbours_channel, Neighbours_channel),
          share:put(SM, current_neighbours, Neighbours)
      end,
      fsm:cast(SM, nl_impl, {send, {nl, neighbours, NL}});
    {nl, set, neighbours, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, neighbours, error}});
    {nl, set, routing, Routing} when NProtocol =:= staticr;
                                     NProtocol =:= staticrack ->
      Routing_inner_format = lists:map(fun({default,To}) -> To; (Other) -> Other end, Routing),
      share:put(SM, routing_table, Routing_inner_format),
      fsm:cast(SM, nl_impl, {send, {nl, routing, Routing}});
    {nl, set, routing, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, routing, error}});
    {nl, set, protocol, AProtocolID} ->
      case lists:member(AProtocolID, ?LIST_ALL_PROTOCOLS) of
        true ->
          share:put(SM, nlp, AProtocolID),
          fsm:cast(SM, nl_impl, {send, {nl, protocol, AProtocolID}});
        _ ->
          fsm:cast(SM, nl_impl, {send, {nl, protocol, error}})
      end;
    {nl, delete, neighbour, Addr} ->
      nl_mac_hf:process_command(SM, false, {delete, neighbour, Addr});
    {nl, send, _, _} when SM#sm.state =/= idle ->
      fsm:cast(SM, nl_impl, {send, {nl, send, busy}});
    {nl, send, IDst, Payload} ->
      case byte_size(Payload) < ?MAX_IM_LEN of
        true when NProtocol =:= staticr; NProtocol =:= staticrack ->
          Routing_table = share:get(SM, routing_table),
          RAddr = nl_mac_hf:find_in_routing_table(Routing_table, IDst),
          if RAddr =/= ?ADDRESS_MAX ->
              ?TRACE(?ID, "Routing exists ~p ~p~n", [Routing_table, RAddr]),
              case process_sendim(SM, Term) of
                error  -> fsm:cast(SM, nl_impl, {send, {nl, send, error}});
                Params -> fsm:run_event(MM, SM#sm{event = send_wv}, Params)
              end;
             true ->
              ?TRACE(?ID, "NO routing available ~p ~p~n", [Routing_table, RAddr]),
              fsm:cast(SM, nl_impl, {send, {nl, error, norouting}})
          end;
        true ->
          case process_sendim(SM, Term) of
            error  -> fsm:cast(SM, nl_impl, {send, {nl, send, error}});
            Params -> fsm:run_event(MM, SM#sm{event = send_wv}, Params)
          end;
        false ->
          Routing_table = share:get(SM, routing_table),
          RAddr = nl_mac_hf:find_in_routing_table(Routing_table, IDst),
          if RAddr =/= ?ADDRESS_MAX ->
              ?TRACE(?ID, "Routing exists ~p ~p~n", [Routing_table, RAddr]),
              case process_send(SM, Term) of
                error  -> fsm:cast(SM, nl_impl, {send, {nl, send, error}});
                Params -> fsm:run_event(MM, SM#sm{event = send_wv}, Params)
              end;
             true ->
              ?TRACE(?ID, "NO routing available ~p ~p~n", [Routing_table, RAddr]),
              fsm:cast(SM, nl_impl, {send, {nl, error, norouting}})
          end
      end;
    {ignore,_} -> SM;
    _ when MM#mm.role == nl_impl ->
      case tuple_to_list(Term) of
        [nl | _] ->
          fsm:cast(SM, nl_impl, {send, {nl, error}});
        _ ->
          ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, Term]),
          SM
      end;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

%%------------------------------------------ init -----------------------------------------------------
init_flood(SM) ->
  {H, M, Ms} = erlang:timestamp(),
  LA = share:get(SM, local_address),
  rand:seed(exsplus, {H + LA, M + LA, Ms + (H * LA + M * LA)}),
  share:put(SM, [{path_exists, false},
                 {list_current_wvp, []},
                 {s_total_sent, 1},
                 {r_total_sent, 1},
                 {queue_ids, queue:new()},
                 {last_states, queue:new()},
                 {pr_states, queue:new()},
                 {paths, queue:new()},
                 {st_neighbours, queue:new()},
                 {st_data, queue:new()}]),
  SM1 = nl_mac_hf:init_dets(SM),
  nl_mac_hf:init_nl_addrs(SM1).

%%------------------------------------------ handle functions -----------------------------------------
handle_idle(_MM, SMP, Term) ->
  case SMP#sm.event of
    init -> init_flood(SMP);
    _    -> nothing
  end,
  nl_mac_hf:update_states_list(SMP),
  [Param_Term, SM] = nl_mac_hf:event_params(SMP, Term, error),
  ?TRACE(?ID, "handle_idle ~120p~n", [Term]),
  Protocol    = share:get(SM, protocol_config, share:get(SM, nlp)),
  Local_address = share:get(SM, local_address),
  case SM#sm.event of
    error when Protocol#pr_conf.ack ->
      case Param_Term of
        {error, {Real_src, Real_dst}} when (Real_dst =:= Local_address) ->
          case share:get(SM, current_pkg) of
            {nl, send, _, Payload} ->
              nl_mac_hf:analyse(SM, st_data, {Payload, Real_dst, 0, "Failed"}, {Real_src, Real_dst});
            _ ->
              nothing
          end,
          fsm:cast(SM, nl_impl, {send, {nl, failed, 0, Real_dst, Real_src}});
        _ ->
          nothing
      end;
    _ ->
      nothing
  end,
  SM#sm{event = eps}.

handle_swv(_MM, SMP, Term) ->
  nl_mac_hf:update_states_list(SMP),
  [Param_Term, SM] = nl_mac_hf:event_params(SMP, Term, relay_wv),
  ?TRACE(?ID, "handle_swv ~120p~n", [Term]),
  case Param_Term of
    {send, Params = {Flag, [_, ISrc, _]}, Tuple = {nl, send, Idst, _}} ->
      SM1 = nl_mac_hf:send_nl_command(SM, at, Params, Tuple),
      if SM1 =:= error ->
        print_nl_error(SM, ISrc, Flag),
        SM#sm{event=error, event_params = {error, {ISrc, Idst}}};
      true -> process_send_flag(SM, Params, Tuple)
      end;
    {relay_wv, SendTuple} ->
      Rand_timeout = nl_mac_hf:rand_float(SM, wwv_tmo),
      fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout}, {relay_wv, SendTuple});
    _ ->
      SM#sm{event = eps}
  end.

handle_rwv(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  ?TRACE(?ID, "handle_rwv ~120p~n", [Term]),
  case Term of
    {relay_wv, Params, Tuple} ->
      SM#sm{event = relay_wv, event_params = {relay_wv, {send, Params, Tuple}} };
    {dst_reached, Params={Flag, _}, Tuple={nl, recv, ISrc, IDst, Payload}} ->

      if Flag =:= data ->
          {_, NData, _} = nl_mac_hf:parse_path_data(SM, Payload),
          fsm:cast(SM, nl_impl, {send, {nl, recv, ISrc, IDst, NData}});
         true ->
           nothing
      end,
      process_rcv_flag(SM, Params, Tuple)
  end.

handle_sack(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  Protocol    = share:get(SM, protocol_config, share:get(SM, nlp)),
  ?TRACE(?ID, "handle_sack ~120p~n", [Term]),
  case Term of
    {send_ack, _, {nl, recv, ISrc, IDst, Payload}} ->
      [SM1,_] =
      if (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) ->
           {_, Add, Path} = nl_mac_hf:parse_path_data(SM, Payload),
           nl_mac_hf:parse_path(SM, {Add, Path}, {ISrc, IDst});
         true ->
           {_, Add, Path} = nl_mac_hf:parse_path_data(SM, Payload),
           nl_mac_hf:parse_path(SM, {Add, Path}, {ISrc, IDst})
      end,
      SM2 = nl_mac_hf:send_ack(SM1, Term, 0),
      if SM2 =:= error ->
           print_nl_error(SM, ISrc, ack),
           SM#sm{event = error, event_params={error,{ISrc,IDst}}};
         true ->
           SM2#sm{event = ack_data_sent}
      end
  end.

handle_spath(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  ?TRACE(?ID, "handle_spath ~120p~n", [Term]),
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)),
  case Term of
    {send_path, Params={Flag, [Packet_id, ISrc,_]},{nl, send, IDst, Data}} ->
      NTerm = {nl, recv, ISrc, IDst, Data},
      SM1 = nl_mac_hf:send_path(SM, {send_path, Params, NTerm}),
      Local_address = share:get(SM, local_address),
      WTP = if Local_address =:= IDst -> {Packet_id, IDst, ISrc}; true -> {Packet_id, ISrc, IDst} end,
      if SM1 =:= error->
        print_nl_error(SM, ISrc, Flag),
        SM#sm{event = error, event_params={error, {ISrc, IDst}}};
      true -> fsm:set_timeout(SM1#sm{event=wait_pf}, {s, share:get(SM, wpath_tmo)}, {wpath_timeout,WTP})
      end;
    {send_path,_,{nl,recv,_,_,_}} ->
      %% choose path with best integrity and rssii
      NTerm =
      case Protocol#pr_conf.evo of
        true ->
          List_current_wvp = share:get(SM, list_current_wvp),
          Sorted_list = lists:sort(fun({IntA,RssiA,ValA}, {IntB,RssiB,ValB}) -> {IntA,RssiA,ValA} =< {IntB,RssiB,ValB} end, List_current_wvp),
          {_,_, {Params, Tuple} } = lists:nth(length(Sorted_list), Sorted_list),
          share:put(SM, list_current_wvp, []),
          {send_path, Params, Tuple};
        false ->
          Term
      end,
      {send_path,_, {nl,recv,ISrc,IDst,_}} = NTerm,
      SM1 = nl_mac_hf:send_path(SM, NTerm),
      if SM1 =:= error ->
           print_nl_error(SM, ISrc, path),
           SM#sm{event = error, event_params={error,{ISrc,IDst}}};
         true ->
           SM1#sm{event = path_data_sent}
      end
  end.

handle_wack(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  ?TRACE(?ID, "handle_wack ~120p~n", [Term]),
  Local_address = share:get(SM, local_address),
  case Term of
    {relay_wv, Params={Flag, [Packet_id, Real_src, _PAdditional]}, Tuple={nl,send,Real_dst,_}} ->
      SM1 = fsm:clear_timeout(SM, {wack_timeout, {Packet_id, Real_dst, Real_src}}),
      if (Flag =:= ack) ->
           nl_mac_hf:smooth_RTT(SM, direct, {rtt, Local_address, Real_src});
         true ->
           nothing
      end,
      SM1#sm{event = relay_wv, event_params = {relay_wv, {send, Params, Tuple}}};
    {dst_reached, {ack, [Packet_id,_, PAdditional]} ,{nl, recv, Real_dst, Real_src, Payl}} ->
      case share:get(SM, current_pkg) of
        {nl, send, TIDst, Payload} ->
          Count_hops = nl_mac_hf:extract_ack(SM, Payl),
          nl_mac_hf:analyse(SM, st_data, {Payload, TIDst, Count_hops + 1, "Delivered"}, {Real_src, Real_dst});
        _ ->
          nothing
      end,
      Ack_last_nl_sent = share:get(SM, ack_last_nl_sent),
      if {Packet_id, Real_src, Real_dst} == Ack_last_nl_sent  ->
        SM1 = nl_mac_hf:send_nl_command(SM, at, {dst_reached, [Packet_id, Real_dst, PAdditional]}, {nl,send,Real_src,<<"">>}),
        SM2 = fsm:clear_timeout(SM1, {wack_timeout, {Packet_id, Real_src, Real_dst}}),
        fsm:cast(SM2, nl_impl, {send, {nl, delivered, 0, Real_src, Real_dst}}),
        nl_mac_hf:smooth_RTT(SM, direct, {rtt, Local_address, Real_dst}),
        SM2#sm{event = dst_rcv_ack};
      true ->
        SM#sm{event = eps}
      end;
    % TEST!!!
    {dst_reached, Params = {data, _} , Tuple} ->
        {nl, recv, ISrc, IDst, Payload} = Tuple,
        {_, NData, _} = nl_mac_hf:parse_path_data(SM, Payload),
        fsm:cast(SM, nl_impl, {send, {nl, recv, ISrc, IDst, NData}}),
        Rand_timeout_wack = nl_mac_hf:rand_float(SM, wack_tmo),
        fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout_wack}, {send_ack, Params, Tuple});
    _ ->
      SM#sm{event = eps}
  end.

handle_wpath(_MM, SM, Term) ->
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)),
  nl_mac_hf:update_states_list(SM),
  case Term of
    {relay_wv, Params = {data, [Packet_id, Real_src, _]}, {nl, send, Real_dst, Payload}} ->
      CheckedTuple = nl_mac_hf:parse_path_data(SM, Payload),
      {_, Add, Path} = CheckedTuple,

      {SM1, NewPayload} =
      case CheckedTuple of
        {D, Add, nothing} ->
          {SM, nl_mac_hf:fill_msg(data, {D, Add})};
        {_, Add, Path} ->
          PP = nl_mac_hf:fill_msg(path_data, CheckedTuple),
          [SMN1, _]  = nl_mac_hf:parse_path(SM, {Add, Path}, {Real_src, Real_dst}),
          {SMN1, PP}
      end,

      SM2 = fsm:clear_timeout(SM1, {wpath_timeout, {Packet_id, Real_dst, Real_src}}),
      SM2#sm{event = relay_wv, event_params = {relay_wv, {send, Params, {nl, send, Real_dst, NewPayload}}}};
    {relay_wv, Params = {_, [Packet_id, Real_src, _]}, Tuple = {nl, send, Real_dst, Payload}} ->
      [ListNeighbours, ListPath] = nl_mac_hf:extract_neighbours_path(SM, Payload),
      NPathTuple = {ListNeighbours, ListPath},
      [_, BPath] = nl_mac_hf:parse_path(SM, NPathTuple, {Real_src, Real_dst}),
      SM1 = fsm:clear_timeout(SM, {wpath_timeout, {Packet_id, Real_dst, Real_src}}),
      case nl_mac_hf:get_routing_addr(SM, path, Real_dst) of
        ?ADDRESS_MAX when not Protocol#pr_conf.brp ->
          SM1#sm{event=error, event_params={error, {Real_dst, Real_src}}};
        _ ->
          nl_mac_hf:analyse(SM1, paths, BPath, {Real_src, Real_dst}),
          SM1#sm{event = relay_wv, event_params = {relay_wv, {send, Params, Tuple}}}
      end;
    {dst_reached, {path, Params = [Packet_id, _, _]}, Tuple = {nl,recv, Real_dst, Real_src, Data}} ->
      ?TRACE(?ID, "Path tuple on src ~120p~n", [Data]),
      Res = nl_mac_hf:prepare_send_path(SM, Params, Tuple),
      case Res of
        nothing ->
          SM#sm{event = eps};
        [SM1, SDParams, SDTuple]  ->
          SM2 = fsm:clear_timeout(SM1, {wpath_timeout, {Packet_id, Real_src, Real_dst}}),
          case nl_mac_hf:get_routing_addr(SM2, path, Real_dst) of
            ?ADDRESS_MAX when not Protocol#pr_conf.brp ->
              %% path can not have broadcast addrs, because these addrs have bidirectional links
              SM2#sm{event=error, event_params={error, {Real_dst, Real_src}}};
            _ ->
              SM2#sm{event = dst_rcv_path, event_params = {relay_wv, {send, SDParams, SDTuple}} }
          end;
        [SM1, path_not_completed] ->
          SM1#sm{event = eps}
      end;
    % TEST!!!
    {dst_reached, Params = {data, _} , Tuple} ->
        Rand_timeout_wack = nl_mac_hf:rand_float(SM, wack_tmo),
        fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout_wack}, {send_ack, Params, Tuple});
    _ ->
      SM#sm{event = eps}
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
    exit({alarm, SM#sm.module}).

handle_final(_MM, SM, _Term) ->
  ?INFO(?ID, "FINAL~n", []),
  nl_mac_hf:dump_sm(SM, nl, share:get(SM, debug)),
  fsm:clear_timeouts(SM#sm{event = eps}).

%%------------------------------------------ process helper functions -----------------------------------------------------
process_send(SM, Tuple) ->
  Local_address = share:get(SM, local_address),
  {nl, send, Dst, Data} = Tuple,
  PkgID = nl_mac_hf:increase_pkgid(SM, Local_address, Dst),

  if Dst =:= Local_address ->
    error;
  true ->
    share:put(SM, path_exists, true),
    Payl = nl_mac_hf:fill_msg(data, {byte_size(Data), Data}),
    NTuple = {nl, send, Dst, Payl},
    {send, {data, [PkgID, Local_address, []]}, NTuple}
  end.

process_sendim(SM, Tuple) ->
  NP = share:get(SM, nlp),
  Protocol    = share:get(SM, protocol_config, NP),
  Local_address = share:get(SM, local_address),
  {nl, send, Dst, Data} = Tuple,
  TransmitLen = byte_size(Data),
  PkgID = nl_mac_hf:increase_pkgid(SM, Local_address, Dst),

  if Dst =:= Local_address ->
    error;
   true ->
     MAC_addr  = nl_mac_hf:addr_nl2mac(SM, Local_address),
     share:put(SM, current_pkg, Tuple),
     nl_mac_hf:save_stat_time(SM, {MAC_addr, Dst}, source),
     case (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) of
       true ->
         NTuple = {nl, send, Dst, nl_mac_hf:fill_msg(path_data, {TransmitLen, Data, [MAC_addr]})},
         {send, {data, [PkgID, Local_address, []]}, NTuple};
       false when Protocol#pr_conf.ry_only ->
         Payl = nl_mac_hf:fill_msg(data, {TransmitLen, Data}),
         NTuple = {nl, send, Dst, Payl},
         {send, {data, [PkgID, Local_address, []]}, NTuple};
       false when Protocol#pr_conf.pf ->
         Path_exists = nl_mac_hf:get_routing_addr(SM, data, Dst),
         if (Path_exists =/= ?ADDRESS_MAX) ->
              share:put(SM, path_exists, true),
              Payl = nl_mac_hf:fill_msg(data, {TransmitLen, Data}),
              NTuple = {nl, send, Dst, Payl},
              {send, {data, [PkgID, Local_address, []]}, NTuple};
            true ->
              [Flag, PAdditional, NTuple] =
              case Protocol#pr_conf.lo of
                true when Protocol#pr_conf.evo ->
                  Payl = nl_mac_hf:fill_msg(path_addit, {[MAC_addr], [0, 0]}),
                  [path_addit, [0,0], {nl, send, Dst, Payl}];
                true ->
                  Payl = nl_mac_hf:fill_msg(path_addit, {[MAC_addr], 0}),
                  [path_addit, [0,0], {nl, send, Dst, Payl}];
                false ->
                  Payl = nl_mac_hf:fill_msg(neighbours, []),
                  [neighbours, [] , {nl, send, Dst, Payl}]
              end,
              {send, {Flag, [PkgID, Local_address, PAdditional]}, NTuple}
         end;
       false ->
         error
     end
  end.

parse_ll_msg(SM, Tuple) ->
  case Tuple of
    {sync, _, Msg} ->
      [SM, process_sync(Msg)];
    {async, Msg} ->
      process_async(SM, Msg);
    _ ->
      [SM, nothing]
  end.

process_sync(Msg) ->
  case Msg of
    {error,_} -> {nl,send,error};
    {busy, _} -> {nl,send,busy};
    "OK"      -> {nl,send,0};
    %{ok}    -> {nl,send,ok};
    _     -> nothing
  end.

process_async(SM, Msg) ->
  Local_address = share:get(SM, local_address),
  case Msg of
    {recv,_,ISrc,IDst,_,_,IRssi,IIntegrity,_,PayloadTail} ->
      process_recv(SM, [ISrc, IDst, IRssi, IIntegrity, PayloadTail]);
    {recvim,_,ISrc,IDst,_,_,IRssi,IIntegrity,_,PayloadTail} ->
      process_recv(SM, [ISrc, IDst, IRssi, IIntegrity, PayloadTail]);
    {deliveredim, BDst} ->
      [SM, {nl, delivered, 0, Local_address, BDst}];
    {failedim, BDst} ->
      [SM, {nl, failed, 0, Local_address, BDst}];
    _ ->
      [SM, nothing]
  end.

process_recv(SM, L) ->
  Local_address = share:get(SM, local_address),
  ?TRACE(?ID, "Recv AT command ~p~n", [L]),
  [ISrc, IDst, IRssi, IIntegrity, PayloadTail] = L,
  Blacklist = share:get(SM, blacklist),
  ?INFO(?ID, "Blacklist : ~w ~n", [Blacklist]),
  NLSrcAT  = nl_mac_hf:addr_mac2nl(SM, ISrc),
  NLDstAT  = nl_mac_hf:addr_mac2nl(SM, IDst),
  if NLSrcAT =:= error ->
    [SM, nothing];
     true ->
       %%----------- black list----------
       case lists:member(NLSrcAT, Blacklist) of
         false ->
           %!!!!!!
           %fsm:cast(SM, nl_impl, {send, {recvim, ISrc, IDst, IRssi, IIntegrity, PayloadTail} }),
           case IDst of
              255 ->
                Params = [NLSrcAT, NLDstAT, IRssi, IIntegrity],
                [SMN, RTuple] = parse_rcv(SM, Params, PayloadTail),
                form_rcv_tuple(SMN, RTuple);
              IDst when IDst =:= Local_address ->
                Params = [NLSrcAT, NLDstAT, IRssi, IIntegrity],
                [SMN, RTuple] = parse_rcv(SM, Params, PayloadTail),
                form_rcv_tuple(SMN, RTuple);
              _ ->
                [SM, nothing]
           end;
         true ->
           ?INFO(?ID, "Source is in the blacklist : ~w ~n", [Blacklist]),
           [SM, nothing]
       end
  end.

parse_rcv(SM, RcvParams, PayloadTail) ->
  try
    DataParams = nl_mac_hf:extract_payload_nl_flag(PayloadTail),
    [BPid, _,  _,  _,  _,  _,  _] = DataParams,
    CurrentPid = ?PROTOCOL_NL_PID(share:get(SM, nlp)),

    if CurrentPid == BPid ->
      process_rcv_wv(SM, RcvParams, DataParams);
    true ->
      ?TRACE(?ID, "Message is not applicable with current protocol ~p ~p~n", [RcvParams, PayloadTail]),
      [SM, nothing]
    end
  catch error: Reason ->
    % Got a message not for NL layer
    ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
    [SM, nothing]
  end.

process_rcv_wv(SMT, RcvParams, DataParams) ->
  Local_address = share:get(SMT, local_address),
  Protocol    = share:get(SMT, protocol_config, share:get(SMT, nlp)),

  [NLSrcAT, NLDstAT, IRssi, IIntegrity] = RcvParams,
  [_, BFlag, Pkg_id, TTL, Real_src, Real_dst, Tail] = DataParams,

  Flag = nl_mac_hf:num2flag(BFlag, nl),
  RemotePkgID = Pkg_id,

  RecvNLSrc = nl_mac_hf:addr_mac2nl(SMT, Real_src),
  RecvNLDst = nl_mac_hf:addr_mac2nl(SMT, Real_dst),

  PTail =
  case Flag of
    data when Protocol#pr_conf.lo; Protocol#pr_conf.pf ->
      case nl_mac_hf:parse_path_data(SMT, Tail) of
        {_, Data, _P} -> Data;
        _ -> Tail
      end;
    data -> Tail;
    _ -> <<"">>
  end,

  [SM, PPkg_id]   = nl_mac_hf:process_pkg_id(SMT, TTL, {Flag, TTL, RemotePkgID, RecvNLSrc, RecvNLDst, PTail}),
  ?TRACE(?ID, "process_pkg_id ~p~n",[PPkg_id]),

  LocalPkgID = share:get(SM, {packet_id, RecvNLSrc, RecvNLDst}),
  ?TRACE(?ID, " ~p : la ~p   :  ~p -> ~p     flag ~p  localID ~p remoteID ~p~n", [PPkg_id, Local_address, RecvNLSrc, RecvNLDst, Flag, LocalPkgID, RemotePkgID]),

  RParams   = {Flag, [RemotePkgID, RecvNLSrc, [IRssi, IIntegrity] ]},
  RAsyncTuple = {nl, recv, RecvNLSrc, RecvNLDst, Tail},
  RSendTuple  = {nl, send, RecvNLDst, Tail},

  RProcTuple  = {rcv_processed, RParams, RAsyncTuple},
  RRelayTuple = {relay, RParams, RSendTuple},
  RDstTuple   = {dst_reached, RParams, RAsyncTuple},

  ResN = nl_mac_hf:add_neighbours(SM, Flag, NLSrcAT, {RecvNLSrc, RecvNLDst}, {IRssi, IIntegrity}),
  SMN = case ResN of
    neighbours_other_format -> SM;
    _ -> ResN
  end,

  case PPkg_id of
    _ when Flag =:= dst_reached ->
      [SMN, nothing];
    %old_id-> [SMN, nothing];
    processed ->
      [SMN, [rcv_processed, RecvNLDst, RProcTuple, RDstTuple]];
    not_processed ->
      if  (RecvNLSrc =/= error) and (RecvNLSrc =/= Local_address) and (NLDstAT =:= Local_address);
          (RecvNLSrc =/= error) and (RecvNLSrc =/= Local_address) and (NLDstAT =:= ?ADDRESS_MAX) ->
            %% check probability, for probabilistic protocols
            if Protocol#pr_conf.prob ->
             case check_probability(SMN) of
               false when Flag =/= ack ->
                 [SMN, [rcv_processed, RecvNLDst, RProcTuple, RDstTuple]];
               _ ->
                 [SMN, [relay, RecvNLDst, RRelayTuple, RDstTuple]]
             end;
            true ->
                 [SMN, [relay, RecvNLDst, RRelayTuple, RDstTuple]]
            end;
          true ->
            [SMN, nothing]
      end
  end.

form_rcv_tuple(SMN, RTuple) ->
  Local_address = share:get(SMN, local_address),
  io:format("Local_address = ~p, RTuple = ~p~n", [Local_address, RTuple]),
  if RTuple =:= nothing -> [SMN, nothing];
     true ->
       [Type, NLDst, RcvTuple, RDstTuple] = RTuple,
       case Type of
         rcv_processed when NLDst  =:= Local_address ->
           % received processed
           [SMN, RcvTuple];
         relay when NLDst  =:= Local_address ->
           % dst reached
           [SMN, RDstTuple];
         _ when NLDst  =:= 255 ->
           % if dst is broadcast, we have to receive and relay message
           [SMN, {dst_and_relay, RDstTuple, RcvTuple}];
         relay when NLDst  =/= Local_address ->
           % only relay not processed msgs
           [SMN, RcvTuple];
         _ ->
           [SMN, nothing]
       end
  end.

check_probability(SM) ->
  {Pmin, Pmax} = share:get(SM, probability),
  CN = share:get(SM, current_neighbours),
  Snbr =
  case CN of
    nothing -> 0;
    _ -> length(CN)
  end,

  P = multi_array(Snbr, Pmax, 1),

  ?TRACE(?ID, "Snbr ~p probability ~p ~n",[Snbr, P]),
  PNew =
  if P < Pmin ->
    Pmin;
  true -> P
  end,

  %random number between 0 and 1
  RN = rand:uniform(),
  ?TRACE(?ID, "Snbr ~p P ~p PNew ~p > RN ~p :  ~n", [Snbr, P, PNew, RN]),
  PNew > RN.

multi_array(0, _, P) -> P;
multi_array(Snbr, Pmax, P) -> multi_array(Snbr - 1, Pmax, P * Pmax).

process_send_flag(SM, Params, Tuple) ->
  {Flag, [Packet_id, Real_src, _PAdditional]} = Params,
  Protocol    = share:get(SM, protocol_config, share:get(SM, nlp)),
  Local_address = share:get(SM, local_address),
  Real_dst     = nl_mac_hf:get_dst_addr(Tuple),
  nl_mac_hf:save_stat_time(SM, {Real_src, Real_dst}, relay),
  case Flag of
    data when (Protocol#pr_conf.ry_only and Protocol#pr_conf.pf) ->
      Rtt = nl_mac_hf:getRTT(SM, {rtt, Real_src, Real_dst}),
      fsm:set_timeout(SM#sm{event=wait_ack}, {s, Rtt}, {wack_timeout, {Packet_id, Real_src, Real_dst} });
    data when not Protocol#pr_conf.ack ->
      SM#sm{event = noack_data_sent};
    data when Protocol#pr_conf.ack ->
      Rtt = nl_mac_hf:getRTT(SM, {rtt, Real_src, Real_dst}),
      fsm:set_timeout(SM#sm{event=wait_ack}, {s, Rtt}, {wack_timeout, {Packet_id, Real_src, Real_dst} });
    neighbours when  (Protocol#pr_conf.dbl and (Real_src =:= Local_address)) ->
      case fsm:check_timeout(SM, send_wv_dbl_tmo) of
        false ->
          fsm:set_timeout(SM#sm{event = eps}, {s, share:get(SM, send_wv_dbl_tmo)}, {send_wv_dbl, Params, Tuple});
        true ->
          SM#sm{event=eps}
      end;
    neighbours when  Protocol#pr_conf.dbl ->
      SM#sm{event = noack_data_sent};
    Flag when  Protocol#pr_conf.pf and (Flag =:= neighbours);
               Protocol#pr_conf.pf and (Flag =:= path_addit);
               Protocol#pr_conf.dbl and (Flag =:= path) ->
      fsm:set_timeout(SM#sm{event=wait_pf}, {s, share:get(SM, wpath_tmo)}, {wpath_timeout, {Packet_id, Real_src, Real_dst} });
    ack when  Protocol#pr_conf.ack ->
      SM#sm{event = rcv_ack};
    path when  Protocol#pr_conf.pf ->
      SM#sm{event = rcv_path};
    dst_reached ->
      SM#sm{event = noack_data_sent}
  end.

process_rcv_flag(SM, Params={Flag,[Packet_id, _Real_src, PAdditional]}, Tuple={nl,recv,ISrc,IDst,_}) ->
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)),
  Rand_timeout_spath = nl_mac_hf:rand_float(SM, spath_tmo),
  Rand_timeout_wack = nl_mac_hf:rand_float(SM, wack_tmo),
  SDParams = [Packet_id, IDst, PAdditional],
  case Flag of
    data when not Protocol#pr_conf.ack ->
      SM#sm{event  = relay_wv, event_params = {relay_wv, {send, {dst_reached, SDParams}, {nl, send, ISrc, <<"">>}}} };
    data when Protocol#pr_conf.ack ->
      fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout_wack}, {send_ack, Params, Tuple});
    neighbours when Protocol#pr_conf.dbl ->
      Payl = nl_mac_hf:fill_msg(neighbours, []),
      STuple = {nl, send, ISrc, Payl},
      SM#sm{event  = relay_wv, event_params = {relay_wv, {send, {dst_reached, SDParams},  STuple}}};
    Flag when Protocol#pr_conf.pf and (Flag =:= neighbours);
              Protocol#pr_conf.pf and (Flag =:= path_addit);
              Protocol#pr_conf.dbl and (Flag =:= path) ->
      fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout_spath}, {send_path, Params, Tuple});
    ack ->
      SM#sm{event = dst_reached};
    path when Protocol#pr_conf.pf ->
      SM#sm{event = dst_reached}
  end.


if_print_to_nl(SM, Real_src, Flag) ->
  NProtocol = share:get(SM, nlp),
  Protocol  = share:get(SM, {protocol_config, NProtocol}),
  Path_exists   = share:get(SM, path_exists),
  Local_address = share:get(SM, local_address),
  ((Local_address=:=Real_src) and Protocol#pr_conf.pf and Path_exists and (Flag =:= data)) or
  ((Local_address=:=Real_src) and Protocol#pr_conf.ry_only and (Flag =:= data)) or
  ((Local_address=:=Real_src) and Protocol#pr_conf.pf and (Flag =:= neighbours)) or
  ((Local_address=:=Real_src) and Protocol#pr_conf.pf and (Flag =:= path_addit)).

print_nl_error(SM, Real_src, Flag) ->
  Print_to_NL = if_print_to_nl(SM, Real_src, Flag),
  if Print_to_NL ->
    fsm:cast(SM, nl_impl, {send, {nl, error}});
  true -> nothing
  end.
