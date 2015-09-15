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
                 {rcv_wv, wack}
                 ]},

                {wpath,
                 [{error, idle},
                  {timeout_path,idle},
                  {send_data, idle},
                  {relay_wv, swv},
                  {rcv_wv, wpath},
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
  Local_address = nl_mac_hf:readETS(SM, local_address),
  Protocol    = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  case Term of
    {timeout, Event} ->
      ?INFO(?ID, "timeout ~140p~n", [Event]),
      case Event of
        {path_life, Tuple} ->
          nl_mac_hf:process_path_life(SM, Tuple);
        {neighbour_life, Addr} ->
          %% TODO: if neighbour does not exist any more, delete from routing table
          nl_mac_hf:insertETS(SM, current_neighbours, nl_mac_hf:readETS(SM, current_neighbours) -- [Addr]);
        {relay_wv, Tuple={send, {Flag,_},_}} ->
          [SMN, PTuple] = nl_mac_hf:proccess_relay(SM, Tuple),
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
          case nl_mac_hf:readETS(SM, current_pkg) of
            {nl, send,_, Payload} ->
              nl_mac_hf:analyse(SM, st_data, {Payload, Real_dst, 0, "Failed"}, {Real_src, Real_dst});
            _ ->
              nothing
          end,
          nl_mac_hf:smooth_RTT(SM, reverse, {rtt, Local_address, Real_dst}),
          if (Real_src =:= Local_address) ->
               fsm:cast(SM, nl, {send, {sync, {nl, failed, Real_src, Real_dst}}});
             true ->
               nothing
          end,
          fsm:run_event(MM, SM#sm{event=timeout_ack,  state=wack}, {});
        {wpath_timeout, {_Packet_id, Real_src, Real_dst}} ->
          case nl_mac_hf:readETS(SM, current_pkg) of
            {nl, send,_, Payload} ->
              nl_mac_hf:analyse(SM, st_data, {Payload, Real_dst, 0, "Failed"}, {Real_src, Real_dst});
            _ ->
              nothing
          end,
          if ((Real_src =:= Local_address) and Protocol#pr_conf.ack) ->
               fsm:cast(SM, nl, {send, {sync, {nl, failed, Real_src, Real_dst}}});
             true -> nothing
          end,
          fsm:run_event(MM, SM#sm{event=timeout_path,  state=wpath}, {});
        {send_wv_dbl, {Flag,[_,Real_src, PAdditional]}, {nl, send, Real_dst, Data}} ->
          Params = {Flag,[nl_mac_hf:increase_pkgid(SM), Real_dst, PAdditional]},
          fsm:run_event(MM, SM#sm{state = idle, event=send_path}, {send_path, Params, {nl, send, Real_src, Data}});
        _ ->
          fsm:run_event(MM, SM#sm{event=Event}, {})
      end;
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    T={sync,_} ->
      case nl_mac_hf:readETS(SM, last_nl_sent) of
        %% rcv sync message for NL
        {Flag, Real_src,_} ->
          nl_mac_hf:cleanETS(SM, last_nl_sent),
          Path_exists = nl_mac_hf:readETS(SM, path_exists),
          nl_mac_hf:insertETS(SM, path_exists, false),
          case parse_ll_msg(SM, T) of
            nothing -> SM;
            [SMN, NT] when  (Local_address=:=Real_src) and Protocol#pr_conf.pf and Path_exists and (Flag =:= data);
                            (Local_address=:=Real_src) and Protocol#pr_conf.ry_only and (Flag =:= data);
                            (Local_address=:=Real_src) and Protocol#pr_conf.pf and (Flag =:= neighbours);
                            (Local_address=:=Real_src) and Protocol#pr_conf.pf and (Flag =:= path_addit) ->
              fsm:cast(SMN, nl, {send, NT}), SMN;
            _ ->
              SM
          end;
        _ -> % rcv sync message not for NL
          SM
      end;

    T={async, {pid, PID}, Tuple} ->
      case nl_mac_hf:readETS(SM, pid) =:= PID of
        true ->
          [SMN, NT] = parse_ll_msg(SM, T),
          case NT of
            nothing ->
              SMN;
            {relay, Params, RTuple={nl,send,Real_dst, Count_hops}} ->
              NTuple=
              case Params of
                {ack,_} ->
                  {nl,send,Real_dst,integer_to_binary(binary_to_integer(Count_hops) + 1)};
                _ ->
                  RTuple
              end,
              fsm:run_event(MM, SMN#sm{event=rcv_wv}, {relay_wv, Params, NTuple});
            {rcv_processed, {data, _}, DTuple} ->
              {async,{nl,recv,ISrc,IDst,Payload}} = DTuple,
              case re:run(Payload,?PATH_DATA,[dotall,{capture,[1,2],binary}]) of
                {match, [_, NData]} -> fsm:cast(SM, nl, {send, {async,{nl,recv,ISrc,IDst,NData}}});
                nomatch -> SMN
              end;
            {dst_reached, Params, DTuple} ->
              SMN1 = nl_mac_hf:save_path(SMN, Params, DTuple),
              fsm:run_event(MM, SMN1#sm{event=rcv_wv}, {dst_reached, Params, DTuple});
            {dst_and_relay, DstTuple, RyTuple} ->
              {dst_reached, {Flag,_}, Send_tuple} = DstTuple,
              if Flag =:= data -> fsm:cast(SMN, nl, {send, Send_tuple}); true -> nothing end,
              case RyTuple of
                {rcv_processed,_,_} ->
                  SMN;
                {relay, Params, RDTuple} ->
                  fsm:run_event(MM, SMN#sm{event=rcv_wv}, {relay_wv, Params, RDTuple })
              end;
            _ ->
              SMN
          end;
        false ->
          ?TRACE(?ID, "Message is not applicable with current protocol ~p~n", [Tuple]), SM
      end;
    {async, _Tuple} ->
      SM;
    {nl,error} ->
      fsm:cast(SM, nl, {send, {nl,error}}),
      SM;
    {rcv_ul, get, Command} ->
      nl_mac_hf:process_command(SM, Command),
      SM;
    {rcv_ul, PID, Tuple} ->
      case nl_mac_hf:readETS(SM, np) =:= PID of
        true ->
          if SM#sm.state =:= idle ->
               case proccess_send(SM, Tuple) of
                 error  -> fsm:cast(SM, nl, {send, {nl,error}});
                 Params -> fsm:run_event(MM, SM#sm{event=send_wv}, Params)
               end;
             true ->
               fsm:cast(SM, nl, {send, {sync, {nl, busy} } }),SM end;
        false ->
          ?TRACE(?ID, "Message is not applicable with current protocol ~p~n", [Tuple]), SM
      end;
    {ignore,_} -> SM;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

%%------------------------------------------ init -----------------------------------------------------
init_flood(SM) ->
  {H, M, Ms} = erlang:now(),
  random:seed({H * nl_mac_hf:readETS(SM, local_address), M * nl_mac_hf:readETS(SM, local_address), Ms}),
  nl_mac_hf:insertETS(SM, packet_id, 0),
  nl_mac_hf:insertETS(SM, path_exists, false),
  nl_mac_hf:insertETS(SM, list_current_wvp, []),
  nl_mac_hf:insertETS(SM, s_total_sent, 0),
  nl_mac_hf:insertETS(SM, r_total_sent, 0),
  nl_mac_hf:insertETS(SM, queue_ids, queue:new()),
  nl_mac_hf:insertETS(SM, last_states, queue:new()),
  nl_mac_hf:insertETS(SM, pr_states, queue:new()),
  nl_mac_hf:insertETS(SM, paths, queue:new()),
  nl_mac_hf:insertETS(SM, st_neighbours, queue:new()),
  nl_mac_hf:insertETS(SM, st_data, queue:new()),
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
  Protocol    = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  Local_address = nl_mac_hf:readETS(SM, local_address),
  case SM#sm.event of
    error when Protocol#pr_conf.ack ->
      case Param_Term of
        {error, {Real_src, Real_dst}} when (Real_dst =:= Local_address) ->
          case nl_mac_hf:readETS(SM, current_pkg) of
            {nl, send,_, Payload} ->
              nl_mac_hf:analyse(SM, st_data, {Payload, Real_dst, 0, "Failed"}, {Real_src, Real_dst});
            _ ->
              nothing
          end,
          fsm:cast(SM, nl, {send, {sync, {nl, failed, Real_dst, Real_src}}});
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
    {send, Params={_,[_,ISrc,_]}, Tuple={nl,send,Idst,_}} ->
      SM1 = nl_mac_hf:send_nl_command(SM, alh, Params, Tuple),
      if SM1 =:= error -> fsm:cast(SM, nl, {send, {nl, error}}), SM#sm{event=error, event_params = {error, {ISrc, Idst}}};
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
    {dst_reached, Params={Flag, _}, Tuple={async, {nl, recv, ISrc, IDst, Payload}}} ->
      if Flag =:= data ->
           case re:run(Payload,?PATH_DATA, [dotall, {capture, [1, 2], binary}]) of
             {match, [_, NData]} ->
               fsm:cast(SM, nl, {send, {async, {nl, recv, ISrc, IDst, NData}}});
             nomatch ->
               fsm:cast(SM, nl, {send, Tuple})
           end;
         true ->
           nothing
      end,
      process_rcv_flag(SM, Params, Tuple)
  end.

handle_sack(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  Protocol    = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  ?TRACE(?ID, "handle_sack ~120p~n", [Term]),
  case Term of
    {send_ack,{Flag,_},{async,{nl,recv,ISrc,IDst,Payload}}} ->
      [SM1,_] =
      if (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) ->
           BMAC_addr = nl_mac_hf:convert_la(SM, bin, mac),
           {match, [BPath, BData]} = re:run(Payload,?PATH_DATA,[dotall, {capture, [1, 2], binary}]),
           NPayload = nl_mac_hf:fill_msg(?PATH_DATA, {nl_mac_hf:check_dubl_in_path(BPath, BMAC_addr), BData}),
           nl_mac_hf:parse_path(SM, Flag, ?PATH_DATA, {ISrc, IDst, NPayload});
         true ->
           nl_mac_hf:parse_path(SM, Flag, ?PATH_DATA, {ISrc, IDst, Payload})
      end,
      SM2 = nl_mac_hf:send_ack(SM1, Term, 0),
      if SM2 =:= error ->
           fsm:cast(SM, nl, {send, {nl,error}}), SM#sm{event = error, event_params={error,{ISrc,IDst}}};
         true ->
           SM2#sm{event = ack_data_sent}
      end
  end.

handle_spath(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  ?TRACE(?ID, "handle_spath ~120p~n", [Term]),
  Protocol = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  case Term of
    {send_path, Params={_,[Packet_id, ISrc,_]},{nl, send, IDst, Data}} ->
      NTerm = {async, {nl, recv, ISrc, IDst, Data}},
      SM1 = nl_mac_hf:send_path(SM, {send_path, Params, NTerm}),
      Local_address = nl_mac_hf:readETS(SM, local_address),
      WTP = if Local_address =:= IDst -> {Packet_id, IDst, ISrc}; true -> {Packet_id, ISrc, IDst} end,
      if SM1 =:= error-> fsm:cast(SM, nl, {send, {nl,error}}), SM#sm{event = error, event_params={error,{ISrc,IDst}}};
         true -> fsm:set_timeout(SM1#sm{event=wait_pf}, {s, nl_mac_hf:readETS(SM, wpath_tmo)}, {wpath_timeout,WTP})
      end;
    {send_path,_,{async,{nl,recv,_,_,_}}} ->
      %% choose path with best integrity and rssii
      NTerm =
      case Protocol#pr_conf.evo of
        true ->
          List_current_wvp = nl_mac_hf:readETS(SM, list_current_wvp),
          Sorted_list = lists:sort(fun({IntA,RssiA,ValA}, {IntB,RssiB,ValB}) -> {IntA,RssiA,ValA} =< {IntB,RssiB,ValB} end, List_current_wvp),
          {_,_, {Params, Tuple} } = lists:nth(length(Sorted_list), Sorted_list),
          nl_mac_hf:insertETS(SM, list_current_wvp, []),
          {send_path, Params, Tuple};
        false ->
          Term
      end,
      {send_path,_, {async,{nl,recv,ISrc,IDst,_}}} = NTerm,
      SM1 = nl_mac_hf:send_path(SM, NTerm),
      if SM1 =:= error ->
           fsm:cast(SM, nl, {send, {nl,error}}),
           SM#sm{event = error, event_params={error,{ISrc,IDst}}};
         true ->
           SM1#sm{event = path_data_sent}
      end
  end.

handle_wack(_MM, SM, Term) ->
  nl_mac_hf:update_states_list(SM),
  ?TRACE(?ID, "handle_wack ~120p~n", [Term]),
  Local_address = nl_mac_hf:readETS(SM, local_address),
  case Term of
    {relay_wv, Params={Flag, [Packet_id, Real_src, _PAdditional]}, Tuple={nl,send,Real_dst,_}} ->
      SM1 = fsm:clear_timeout(SM, {wack_timeout, {Packet_id, Real_dst, Real_src}}),
      if (Flag =:= ack) ->
           nl_mac_hf:smooth_RTT(SM, direct, {rtt, Local_address, Real_src});
         true ->
           nothing
      end,
      SM1#sm{event = relay_wv, event_params = {relay_wv, {send, Params, Tuple}}};
    {dst_reached,{ack, [Packet_id,_, PAdditional]} ,{async,{nl,recv,Real_dst,Real_src,BCount_hops}}} ->
      Count_hops = binary_to_integer(BCount_hops),
      case nl_mac_hf:readETS(SM, current_pkg) of
        {nl, send,TIDst, Payload} ->
          nl_mac_hf:analyse(SM, st_data, {Payload, TIDst, Count_hops + 1, "Delivered"}, {Real_src, Real_dst});
        _ ->
          nothing
      end,
      SM1 = nl_mac_hf:send_nl_command(SM, alh, {dst_reached, [Packet_id, Real_dst, PAdditional]}, {nl,send,Real_src,<<"">>}),
      SM2 = fsm:clear_timeout(SM1, {wack_timeout, {Packet_id, Real_src, Real_dst}}),
      fsm:cast(SM2, nl, {send, {sync, {nl, delivered, Real_src, Real_dst}}}),
      nl_mac_hf:smooth_RTT(SM, direct, {rtt, Local_address, Real_dst}),
      SM2#sm{event = dst_rcv_ack};
    _ ->
      SM#sm{event = eps}
  end.

handle_wpath(_MM, SM, Term) ->
  Protocol = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  nl_mac_hf:update_states_list(SM),
  case Term of
    {relay_wv, Params={_, [Packet_id, Real_src,_PAdditional]}, Tuple={nl,send,Real_dst,Payload}} ->
      [_, BPath] = nl_mac_hf:parse_path(SM, path, ?NEIGHBOUR_PATH, {Real_src, Real_dst, Payload}),
      SM1 = fsm:clear_timeout(SM, {wpath_timeout, {Packet_id, Real_dst, Real_src}}),
      case nl_mac_hf:get_routing_addr(SM, path, Real_dst) of
        255 when not Protocol#pr_conf.brp ->
          SM1#sm{event=error, event_params={error, {Real_dst, Real_src}}};
        _ ->
          nl_mac_hf:analyse(SM1, paths, BPath, {Real_src, Real_dst}),
          SM1#sm{event = relay_wv, event_params = {relay_wv, {send, Params, Tuple}}}
      end;
    {dst_reached,{path, Params=[Packet_id,_,_PAdditional]} ,Tuple={async,{nl,recv, Real_dst, Real_src, Data}}} ->
      ?TRACE(?ID, "Path tuple on src ~120p~n", [Data]),
      case nl_mac_hf:prepare_send_path(SM, Params, Tuple) of
        [SM1, SDParams, SDTuple]  ->
          SM2 = fsm:clear_timeout(SM1, {wpath_timeout, {Packet_id, Real_src, Real_dst}}),
          case nl_mac_hf:get_routing_addr(SM2, path, Real_dst) of
            255 when not Protocol#pr_conf.brp ->
              %% path can not have broadcast addrs, because these addrs have bidirectional links
              SM2#sm{event=error, event_params={error, {Real_dst, Real_src}}};
            _ ->
              SM2#sm{event = dst_rcv_path, event_params = {relay_wv, {send, SDParams, SDTuple}} }
          end;
        [SM1, path_not_completed] ->
          SM1#sm{event = eps}
      end;
    _ ->
      SM#sm{event = eps}
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
    exit({alarm, SM#sm.module}).

handle_final(_MM, SM, _Term) ->
  ?INFO(?ID, "FINAL~n", []),
  nl_mac_hf:dump_sm(SM, nl, nl_mac_hf:readETS(SM, debug)),
  fsm:clear_timeouts(SM#sm{event = eps}).

%%------------------------------------------ process helper functions -----------------------------------------------------
proccess_send(SM, Tuple) ->
  Protocol    = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  Local_address = nl_mac_hf:readETS(SM, local_address),
  PkgID = nl_mac_hf:increase_pkgid(SM),
  {nl, send, Dst, Data} = Tuple,
  if Dst =:= Local_address -> error;
     true ->
       MAC_addr  = nl_mac_hf:addr_nl2mac(SM, Local_address),
       BMAC_addr   = integer_to_binary(MAC_addr),

       nl_mac_hf:insertETS(SM, current_pkg, Tuple),
       case (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) of
         true ->
           nl_mac_hf:save_stat(SM, source),
           NTuple = {nl, send, Dst, nl_mac_hf:fill_msg(?PATH_DATA, {BMAC_addr, Data})},
           {send, {data, [PkgID, Local_address, []]}, NTuple};
         false when Protocol#pr_conf.ry_only ->
           nl_mac_hf:save_stat(SM, source),
           {send, {data, [PkgID, Local_address, []]}, Tuple};
         false when Protocol#pr_conf.pf ->
           Path_exists = nl_mac_hf:get_routing_addr(SM, data, Dst),
           if (Path_exists =/= 255) ->
                nl_mac_hf:insertETS(SM, path_exists, true),
                {send, {data, [PkgID, Local_address, []]}, Tuple};
              true ->
                nl_mac_hf:save_stat(SM, source),
                [Flag, PAdditional, NTuple] =
                case Protocol#pr_conf.lo of
                  true when Protocol#pr_conf.evo ->
                    [path_addit, [0,0], {nl, send, Dst, nl_mac_hf:fill_msg(?PATH_ADDIT, {BMAC_addr, "0,0"})}];
                  true ->
                    [path_addit, [0,0], {nl, send, Dst, nl_mac_hf:fill_msg(?PATH_ADDIT, {BMAC_addr, ""})}];
                  false ->
                    [neighbours, [] , {nl, send, Dst, nl_mac_hf:fill_msg(?NEIGHBOURS, "")}]
                end,
                {send, {Flag, [PkgID, Local_address, PAdditional]}, NTuple}
           end;
         false ->
           error
       end
  end.

parse_ll_msg(SM, Tuple) ->
  case Tuple of
    {sync,  Msg} ->
      [SM, process_sync(Msg)];
    {async, Msg} ->
      process_async(SM, Msg);
    {async, _PID, Msg} ->
      process_async(SM, Msg);
    _ ->
      [SM, nothing]
  end.

process_sync(Msg) ->
  case Msg of
    {error,_} -> {sync, {nl,error}};
    {busy, _} -> {sync, {nl,busy}};
    {ok}    -> {sync, {nl,ok}};
    _     -> nothing
  end.

process_async(SM, Msg) ->
  case Msg of
    {recvim,_,ISrc,IDst,_,_,IRssi,IIntegrity,_,PayloadTail} ->
      process_recv(SM, [ISrc, IDst, IRssi, IIntegrity, PayloadTail]);
    {deliveredim,BDst} ->
      [SM, {async, {nl, delivered, BDst}}];
    {failedim,BDst} ->
      [SM, {async, {nl, failed, BDst}}];
    _ ->
      [SM, nothing]
  end.

process_recv(SM, L) ->
  ?TRACE(?ID, "Recv AT command ~p~n", [L]),
  [ISrc, IDst, IRssi, IIntegrity, PayloadTail] = L,
  Blacklist = nl_mac_hf:readETS(SM, blacklist),
  ?INFO(?ID, "Blacklist : ~w ~n", [Blacklist]),
  NLSrcAT  = nl_mac_hf:addr_mac2nl(SM, ISrc),
  NLDstAT  = nl_mac_hf:addr_mac2nl(SM, IDst),
  if NLSrcAT =:= error -> [SM, nothing];
     true ->
       %%----------- black list----------
       case lists:member(NLSrcAT, Blacklist) of
         false ->
           %!!!!!!
           fsm:cast(SM, nl, {send, {recvim, ISrc, IDst, IRssi, IIntegrity, PayloadTail} }),
           Params = [NLSrcAT, NLDstAT, IRssi, IIntegrity],
           [SMN, RTuple] = parse_rcv(SM, Params, PayloadTail),
           form_rcv_tuple(SMN, RTuple);
         true ->
           ?INFO(?ID, "Source is in the blacklist : ~w ~n", [Blacklist]), [SM, nothing]
       end
  end.

parse_rcv(SM, RcvParams, PayloadTail) ->
  case re:run(PayloadTail,"([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5],binary}]) of
    {match, DataParams} ->
      process_rcv_wv(SM, RcvParams, DataParams);
    nomatch ->
      [SM, nothing]
  end.

process_rcv_wv(SM, RcvParams, DataParams) ->
  Local_address = nl_mac_hf:readETS(SM, local_address),
  Protocol    = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  [NLSrcAT, NLDstAT, IRssi, IIntegrity] = RcvParams,
  [BFlag, BPkg_id, BReal_src, BReal_dst, Tail] = DataParams,

  Flag = nl_mac_hf:num2flag(BFlag, nl),
  RemotePkgID = binary_to_integer(BPkg_id),
  RecvNLSrc = nl_mac_hf:addr_mac2nl(SM, binary_to_integer(BReal_src)),
  RecvNLDst = nl_mac_hf:addr_mac2nl(SM, binary_to_integer(BReal_dst)),

  PTail = case Flag of
            data when Protocol#pr_conf.lo; Protocol#pr_conf.pf ->
              case re:run(Tail,?PATH_DATA,[dotall,{capture,[1,2],binary}]) of
                {match, [_, Data]} -> Data;
                nomatch -> Tail
              end;
            data -> Tail;
            _ -> <<"">>
          end,

  PPkg_id   = nl_mac_hf:process_pkg_id(SM, {RemotePkgID, RecvNLSrc, RecvNLDst, PTail}),
  ?TRACE(?ID, "process_pkg_id ~p~n",[PPkg_id]),

  RParams   = {Flag, [RemotePkgID, RecvNLSrc, [IRssi, IIntegrity] ]},
  RAsyncTuple = {async, {nl, recv, RecvNLSrc, RecvNLDst, Tail}},
  RSendTuple  = {nl, send, RecvNLDst, Tail},

  RProcTuple  = {rcv_processed, RParams, RAsyncTuple},
  RRelayTuple = {relay, RParams, RSendTuple},
  RDstTuple   = {dst_reached, RParams, RAsyncTuple},
  SMN     = nl_mac_hf:add_neighbours(SM, Flag, NLSrcAT, {RecvNLSrc, RecvNLDst}),
  case PPkg_id of
    _ when Flag =:= dst_reached ->
      [SMN, nothing];
    old_id-> [SMN, nothing];
    proccessed ->
      [SMN, [rcv_processed, RecvNLDst, RProcTuple, RDstTuple]];
    not_proccessed ->
      if  (RecvNLSrc =/= error) and (RecvNLSrc =/= Local_address) and (NLDstAT =:= Local_address);
    (RecvNLSrc =/= error) and (RecvNLSrc =/= Local_address) and (NLDstAT =:= 255) ->
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
  Local_address = nl_mac_hf:readETS(SMN, local_address),
  if RTuple =:= nothing -> [SMN, nothing];
     true ->
       [Type, NLDst, RcvTuple, RDstTuple] = RTuple,
       case Type of
         rcv_processed when NLDst  =:= Local_address ->
           [SMN, RcvTuple];  % received processed
         relay when NLDst  =:= Local_address ->
           [SMN, RDstTuple]; % dst reached
         _ when NLDst  =:= 255 ->
           [SMN, {dst_and_relay, RDstTuple, RcvTuple}]; % if dst is broadcast, we have to receive and relay message
         relay when NLDst  =/= Local_address ->
           [SMN, RcvTuple];   % only relay not processed msgs
         _ ->
           [SMN, nothing]
       end
  end.

check_probability(SM) ->
  {Pmin, Pmax} = nl_mac_hf:readETS(SM, probability),
  Snbr =
  case CN = nl_mac_hf:readETS(SM, current_neighbours) of
    not_inside -> 0;
    _ -> length(CN)
  end,
  P = multi_array(Snbr, Pmax, 1),
  ?TRACE(?ID, "Snbr ~p probability ~p ~n",[Snbr, P]),
  if P < Pmin -> Pmin;
     true -> P end,
  RN = random:uniform(),
  P > RN.

multi_array(0, _, P) -> P;
multi_array(Snbr, Pmax, P) -> multi_array(Snbr - 1, Pmax, P * Pmax).

process_send_flag(SM, Params={Flag, [Packet_id, Real_src, _PAdditional]}, Tuple) ->
  Protocol    = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  Local_address = nl_mac_hf:readETS(SM, local_address),
  Real_dst     = nl_mac_hf:get_dst_addr(Tuple),

  case Flag of
    data when not Protocol#pr_conf.ack ->
      SM#sm{event = noack_data_sent};
    data when Protocol#pr_conf.ack ->
      Rtt = nl_mac_hf:getRTT(SM, {rtt, Real_src, Real_dst}),
      fsm:set_timeout(SM#sm{event=wait_ack}, {s, Rtt}, {wack_timeout, {Packet_id, Real_src, Real_dst} });
    neighbours when  (Protocol#pr_conf.dbl and (Real_src =:= Local_address)) ->
      case fsm:check_timeout(SM, send_wv_dbl_tmo) of
        false ->
          fsm:set_timeout(SM#sm{event = noack_data_sent}, {s, nl_mac_hf:readETS(SM, send_wv_dbl_tmo)}, {send_wv_dbl, Params, Tuple});
        true ->
          SM#sm{event=eps}
      end;
    neighbours when  Protocol#pr_conf.dbl ->
      nl_mac_hf:save_stat(SM, relay),
      SM#sm{event = noack_data_sent};
    Flag when  Protocol#pr_conf.pf and (Flag =:= neighbours);
               Protocol#pr_conf.pf and (Flag =:= path_addit);
               Protocol#pr_conf.dbl and (Flag =:= path) ->
      nl_mac_hf:save_stat(SM, relay),
      fsm:set_timeout(SM#sm{event=wait_pf}, {s, nl_mac_hf:readETS(SM, wpath_tmo)}, {wpath_timeout, {Packet_id, Real_src, Real_dst} });
    ack when  Protocol#pr_conf.ack ->
      SM#sm{event = rcv_ack};
    path when  Protocol#pr_conf.pf ->
      SM#sm{event = rcv_path};
    dst_reached ->
      SM#sm{event = noack_data_sent}
  end.

process_rcv_flag(SM, Params={Flag,[Packet_id, _Real_src, PAdditional]}, Tuple={async,{nl,recv,ISrc,IDst,_}}) ->
  Protocol = nl_mac_hf:readETS(SM, {protocol_config, nl_mac_hf:readETS(SM, np)}),
  Rand_timeout_spath = nl_mac_hf:rand_float(SM, spath_tmo),
  Rand_timeout_wack = nl_mac_hf:rand_float(SM, wack_tmo),
  SDParams = [Packet_id, IDst, PAdditional],
  case Flag of
    data when not Protocol#pr_conf.ack ->
      SM#sm{event  = relay_wv, event_params = {relay_wv, {send, {dst_reached, SDParams}, {nl,send,ISrc,<<"">>}}} };
      %SM#sm{event = dst_reached};
    data when Protocol#pr_conf.ack ->
      fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout_wack}, {send_ack, Params, Tuple});
    neighbours when Protocol#pr_conf.dbl ->
      SM#sm{event  = relay_wv, event_params = {relay_wv, {send, {dst_reached, SDParams}, {nl,send,ISrc,nl_mac_hf:fill_msg(?NEIGHBOURS,"")}}} };
    Flag when Protocol#pr_conf.pf and (Flag =:= neighbours);
              Protocol#pr_conf.pf and (Flag =:= path_addit);
              Protocol#pr_conf.dbl and (Flag =:= path) ->
      fsm:set_timeout(SM#sm{event = eps}, {ms, Rand_timeout_spath}, {send_path, Params, Tuple});
    ack ->
      SM#sm{event = dst_reached};
    path when Protocol#pr_conf.pf ->
      SM#sm{event = dst_reached}
  end.
