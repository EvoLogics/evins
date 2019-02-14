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

%% SNC Opportunistic flooding
%% 1. Every node at every time can be source, intermediate (relay) and
%%    destination node.
%% 2. Messages from  source, intermediate (relay) and destination node
%%    are queued on network layer, each with different priority:
%%     -  source – as FILO, on the tail of the queue, as the last message
%%     -  relay and  destination – as FIFO, on the head of the queue, as the
%%        first message
%% 3. Every node can get generated data from user level for transmission
%% 4. Received packet which is not addressed current node has to be relayed
%% 5. Packet is relayed / transmitted through the network till:
%%     -  destination node receives the packet
%%     -  other intermediate node could relay the packet (after the transmission,
%%        the channel should be sensed, if the neighbor nodes received this packet
%%        and could relay it; in case of collision data should be retransmitted)
%%     -  time to live is 0 (TTL); TTL decreases, if data could not be transmitted,
%%        collision or busy channel. Every node in the queue in this case should
%%        decrease TTL
%% 6. Packet are controlled using Packet ID; nodes relay only new packets, old
%%    packets are dropped
%% 7. Routing can be configured. If it is not configured, packets are relayed
%%    in broadcast mode
%% 8. Packet life is calculated as max configured TTL multiplied with max random
%%    transmit timeout



-module(fsm_opportunistic_flooding).
-behaviour(fsm).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_transmit/3, handle_sensing/3, handle_collision/3]).

-define(TRANS, [
                {idle,
                 [{relay, transmit},
                 {reset, idle}
                 ]},

                {transmit,
                 [{transmitted, sensing},
                 {wait, sensing},
                 {path, sensing},
                 {reset, idle}
                 ]},

                {sensing,
                 [{relay, sensing},
                  {sensing_timeout, collision},
                  {pick, transmit},
                  {idle, idle},
                  {reset, idle}
                 ]},

                {collision,
                 [{relay, collision},
                  {pick, transmit},
                  {idle, idle},
                  {reset, idle}
                 ]},

                {alarm, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> init_flood(SM).
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> eps.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
    ?INFO(?ID, "handle_event ~120p state ~p event ~p~n", [Term, SM#sm.state, SM#sm.event]),
    ?INFO(?ID, "current_local_address ~p~n", [share:get(SM, local_address)]),

    Local_Address = share:get(SM, local_address),
    Protocol_Name = share:get(SM, protocol_name),
    Pid = share:get(SM, pid),
    Debug = share:get(SM, debug),
    Establish_retries = share:get(SM, nothing, path_establish, 0),

    case Term of
      {allowed} when MM#mm.role == at ->
        NPid = share:get(SM, {pid, MM}),
        ?INFO(?ID, ">>>>>> Pid: ~p~n", [NPid]),
        share:put(SM, pid, NPid);
      {connected} ->
        SM;
      {disconnected, _} ->
        ?INFO(?ID, "disconnected ~n", []),
        SM;
      {timeout, {ack_timeout, Ack_tuple = {Pkg_ID, Src, Dst}}} ->
        [nl_hf:fill_statistics(__, ack, failed, 0, Ack_tuple),
         fsm:cast(__, nl_impl, {send, {nl, failed, Pkg_ID, Src, Dst}})
        ](SM);
      {timeout, {neighbour_life, Address}} ->
        nl_hf:delete_neighbour(SM, Address);
      {timeout, {sensing_timeout, _Send_Tuple}} ->
        ?INFO(?ID, "St ~p Ev ~p ~n", [SM#sm.event, SM#sm.state]),
        fsm:run_event(MM, SM#sm{event = sensing_timeout}, {});
      {timeout, {path_establish, Dst}} when Establish_retries > 1 ->
        [nl_hf:drop_postponed(__, Dst),
         share:put(__, path_establish, 0),
         share:put(__, waiting_path, false),
         fsm:set_event(__, relay),
         fsm:run_event(MM, __, {})
        ](SM);
      {timeout, {path_establish, _}} ->
        [share:put(__, waiting_path, false),
         fsm:set_event(__, relay),
         fsm:run_event(MM, __, {})
        ](SM);
      {timeout, {choose_ack_path, Tuple}} ->
        [set_stable_ack_path(__, Tuple),
         fsm:set_event(__, relay),
         fsm:run_event(MM, __, {})
        ](SM);
      {timeout, {choose_path, Tuple}} ->
        [set_stable_path(__, Tuple),
         fsm:set_event(__, relay),
         fsm:run_event(MM, __, {})
        ](SM);
      {timeout, relay} ->
        fsm:run_event(MM, SM#sm{event = relay}, {});
      {async, {pid, Pid}, Recv_Tuple} ->
        ?INFO(?ID, "My message: ~p~n", [Recv_Tuple]),
        [process_received_packet(__, Recv_Tuple),
        fsm:run_event(MM, __, {})](SM);
      {async, {pid, _Pid}, Recv_Tuple} ->
        ?INFO(?ID, "Overheard message: ~p~n", [Recv_Tuple]),
        [process_overheared_packet(__, Recv_Tuple),
        fsm:run_event(MM, __, {})](SM);
      {async, Notification} when Debug == on ->
        process_async(SM, Notification);
      {sync, _, _} ->
        fsm:clear_timeout(SM, answer_timeout);
      {nl, send, Local_Address, _Payload} ->
        fsm:cast(SM, nl_impl, {send, {nl, send, error}});
      {nl, send, error} ->
        fsm:cast(SM, nl_impl, {send, {nl, send, error}});
      {nl, send, _IDst, _Payload} ->
        [process_nl_send(__, Term),
         fsm:run_event(MM, __, {})
        ](SM);
      {nl, error, _} ->
        fsm:cast(SM, nl_impl, {send, {nl, error}});
      {nl, reset, state} ->
        [nl_hf:clear_spec_timeout(__, sensing_timeout),
         nl_hf:clear_spec_timeout(__, relay),
         fsm:cast(__, nl_impl, {send, {nl, state, ok}}),
         fsm:set_event(__, reset),
         fsm:run_event(MM, __, {})
        ](SM);
      {nl, clear, statistics, data} ->
        share:put(SM, statistics_queue, queue:new()),
        share:put(SM, statistics_neighbours, queue:new()),
        fsm:cast(SM, nl_impl, {send, {nl, statistics, data, empty}});
      {nl, set, debug, ON} ->
        share:put(SM, debug, ON),
        fsm:cast(SM, nl_impl, {send, {nl, debug, ok}});
      {nl, set, address, Address} ->
        nl_hf:process_set_command(SM, {address, Address});
      {nl, set, neighbours, Neighbours} ->
        nl_hf:process_set_command(SM, {neighbours, Neighbours});
      {nl, set, routing, Routing} ->
        nl_hf:process_set_command(SM, {routing, Routing});
      {nl, set, protocol, Protocol} ->
        nl_hf:process_set_command(SM, {protocol, Protocol});
      {nl, set, Command} ->
        nl_hf:process_set_command(SM, Command);
      {nl, get, protocol} ->
        fsm:cast(SM, nl_impl, {send, {nl, protocol, Protocol_Name}});
      {nl, get, help} ->
        fsm:cast(SM, nl_impl, {send, {nl, help, ?HELP}});
      {nl, get, version} ->
        %% FIXME: define rules to generate version
        fsm:cast(SM, nl_impl, {send, {nl, version, 0, 1, "emb"}});
      {nl, get, time, monotonic} ->
        Current_time = erlang:monotonic_time(milli_seconds) - share:get(SM, nl_start_time),
        fsm:cast(SM, nl_impl, {send, {nl, time, monotonic, Current_time}});
      {nl, get, statistics, Some_statistics} ->
        nl_hf:process_get_command(SM, {statistics, Some_statistics});
      {nl, get, protocolinfo, Some_protocol} ->
        nl_hf:process_get_command(SM, {protocolinfo, Some_protocol});
      {nl, get, Command} ->
        nl_hf:process_get_command(SM, Command);
      {nl, delete, neighbour, Address} ->
        nl_hf:process_get_command(SM, {delete, neighbour, Address});
      UUg when MM#mm.role == nl_impl ->
      case tuple_to_list(Term) of
        [nl | _] ->
          fsm:cast(SM, nl_impl, {send, {nl, error}});
        _ ->
          ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
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
  share:put(SM, [{current_neighbours, []},
                 {neighbours_channel, []},
                 {last_states, queue:new()},
                 {paths, []},
                 {retriesq, queue:new()},
                 {received, queue:new()},
                 {transmission, queue:new()},
                 {statistics_neighbours, queue:new()},
                 {statistics_queue, queue:new()}]),
  nl_hf:init_dets(SM).
%%------------------------------------------ Handle functions -----------------------------------------------------
handle_idle(_MM, SM, Term) ->
  ?INFO(?ID, "idle state ~120p~n", [Term]),
  nl_hf:update_states(SM),
  fsm:set_event(SM, eps).

% check if pf and path is available
% if not available -> try_transmit path message, and than data
% path messages has priority in transmission queue
% do not decrease TTL if pf is active
handle_transmit(_MM, SM, Term) ->
  ?INFO(?ID, "transmit state ~120p~n", [Term]),
  Waiting_path = share:get(SM, nothing, waiting_path, false),
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  nl_hf:update_states(SM),
  Head = nl_hf:head_transmission(SM),

  Path_exist =
  not Protocol_Config#pr_conf.ry_only and
  Protocol_Config#pr_conf.pf and not nl_hf:routing_exist(SM, Head) and
  not Waiting_path,

  Path_needed =
  if Protocol_Config#pr_conf.brp ->
    % broadcast path
    Path_exist and (nl_hf:getv(flag, Head) == data);
  true ->
    % unicast path
    Path_exist
  end,

  Is_path = nl_hf:if_path_packet(Head),
  ?INFO(?ID, "transmit state Waiting_path ~120p ~p~n", [Waiting_path, Path_needed]),
  case Path_needed of
    true ->
      establish_path(SM, Head);
    false when Waiting_path, not Is_path ->
      fsm:set_event(SM, path);
    false ->
      [fsm:clear_timeout(__, {path_establish, nl_hf:getv(src, Head)}),
       try_transmit(__, Head)
      ] (SM)
  end.

handle_sensing(_MM, SM, _Term) ->
  ?INFO(?ID, "sensing state ~120p~n", [SM#sm.event]),
  nl_hf:update_states(SM),
  case SM#sm.event of
    transmitted ->
      maybe_transmit_next(SM);
    relay ->
      maybe_pick(SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_collision(_MM, SM, _Term) ->
  ?INFO(?ID, "collision state ~p~n", [SM#sm.event]),
  nl_hf:update_states(SM),
  case SM#sm.event of
    sensing_timeout ->
      % 1. decreace TTL for every packet in the queue
      % 2. delete packets withh TTL 0 or < 0
      % 3. check, if queue is empty -> idle
      % 4. check, if queue is not empty -> pick -> transmit the head of queue
      [nl_hf:decrease_TTL(__),
       maybe_pick(__)
      ](SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).
%%------------------------------------------ Helper functions -----------------------------------------------------
process_nl_send(SM, Tuple) ->
  ?INFO(?ID, "process_nl_send state ~p ev ~p ~p ~n", [SM#sm.state, SM#sm.event, Tuple]),
  {PkgID, NL} = nl_hf:code_send_tuple(SM, Tuple),
  Fill_handler =
  fun(LSM) ->
    case nl_hf:get_event_params(LSM, fill_tq) of
       Ev when Ev == {fill_tq, error}; Ev == nothing ->
        [fsm:cast(__, nl_impl, {send, {nl, send, error}}),
         fsm:set_event(__, eps)
        ](LSM);
       _ ->
        [fsm:cast(__, nl_impl, {send, {nl, send, PkgID}}),
         fsm:set_event(__, relay)
        ](LSM)
      end
  end,

 [nl_hf:fill_transmission(__, filo, NL),
  Fill_handler(__),
  nl_hf:clear_event_params(__, fill_tq)
 ](SM).


establish_path(SM, empty) ->
  fsm:set_event(SM, transmitted);
establish_path(SM, NL) ->
  ?INFO(?ID, "Establish path ~n", []),
  Local_address = share:get(SM, local_address),
  Wpath_tmo = share:get(SM, wpath_tmo),
  Retries = share:get(SM, nothing, path_establish, 0),
  [Src, Dst] = nl_hf:getv([src, dst], NL),

  [share:put(__, path_establish, Retries + 1),
   fsm:set_timeout(__, {s, Wpath_tmo}, {path_establish, Dst}),
   establish_path(__, Src == Local_address, Dst, NL)
  ](SM).

%generator
establish_path(SM, true, Dst, _NL) ->
  Local_address = share:get(SM, local_address),
  Protocol_name = share:get(SM, protocol_name),
  Protocol_config = share:get(SM, protocol_config, Protocol_name),

  MType =
  if Protocol_config#pr_conf.evo -> path_addit;
  true -> path_neighbours end,

  ?INFO(?ID, "establish_path ~p ~p~n", [Protocol_config#pr_conf.evo, MType]),

  Tuple = nl_hf:prepare_path(SM, path, MType, Local_address, Dst),
  [share:put(__, waiting_path, true),
   fsm:cast(__, nl_impl, {send, {nl, path, Dst}}),
   nl_hf:fill_transmission(__, filo, Tuple),
   try_transmit(__, Tuple)
  ](SM);
%relay
establish_path(SM, false, _Dst, NL) ->
  [share:put(__, waiting_path, true),
   try_transmit(__, NL)
  ](SM).

% take first message from the queue to transmit
try_transmit(SM, empty) ->
  fsm:set_event(SM, transmitted);
try_transmit(SM, Head) ->
  ?INFO(?ID, "Try send message: head item ~p~n", [Head]),
  [AT, L] = nl_hf:create_nl_at_command(SM, Head),
  try_transmit(SM, AT, L, Head).

try_transmit(SM, error, _, _) ->
  fsm:set_event(SM, transmitted);
try_transmit(SM, AT, L, Head) ->
  Transmission_handler =
  fun(_LSM, blocked) -> fsm:set_event(SM, wait);
     (_LSM, ok) ->
      ?INFO(?ID, "Transmit tuples ~p~n", [L]),
      transmit_combined(SM, AT, Head, lists:reverse(L), 0)
  end,

  [fsm:set_event(__, eps),
   fsm:maybe_send_at_command(__, AT, Transmission_handler)
  ](SM).

transmit_combined(SM, _, Head, [], _) ->
  Sensing = nl_hf:rand_float(SM, tmo_sensing),
  [fsm:set_event(__, transmitted),
   fsm:set_timeout(__, {ms, Sensing}, {sensing_timeout, Head})
  ](SM);
transmit_combined(SM, AT, Tuple, [Head | Tail], Num) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Ack_protocol = Protocol_Config#pr_conf.ack,
  Local_address = share:get(SM, local_address),

  Ack_handler =
  fun (LSM, H) ->
      [Flag, PkgID, Src, Dst] = nl_hf:getv([flag, id, src, dst], H),
      if Flag == data, Src == Local_address, Ack_protocol ->
        Time = share:get(SM, rtt),
        fsm:set_timeout(LSM, {s, Time}, {ack_timeout, {PkgID, Src, Dst}});
      true -> LSM
      end
  end,

  Combined_ack_handler =
  fun (LSM, H) ->
    % decrease retries of packet, only if dst is the same
    % or broadcast
    [Flag, Dst] = nl_hf:getv([flag, dst], H),
    Exist = nl_hf:routing_exist(SM, Dst),
    Route_Addr = nl_hf:get_routing_address(SM, Dst),
    MAC_Route_Addr = nl_hf:nl2mac_address(Route_Addr),
    AT_Dst = nl_hf:get_at_dst(AT),
    ?INFO(?ID, "Transmit combined ~p ~p ~p ~p ~p ~n", [Num, Flag, Exist, AT_Dst, MAC_Route_Addr]),
    Not_decrease =
      (Num =/= 0) and ((Flag == ack) or (Flag == dst_reached))and
      Exist and (AT_Dst =/= MAC_Route_Addr),

    if Not_decrease ->
      LSM;
    true ->
       nl_hf:decrease_retries(LSM, H)
    end
  end,

  [nl_hf:set_processing_time(__, transmitted, Head),
   Combined_ack_handler(__, Head),
   nl_hf:update_received_TTL(__, Head),
   nl_hf:update_received(__, Head),
   Ack_handler(__, Head),
   transmit_combined(__, AT, Tuple, Tail, Num + 1)
  ](SM).

maybe_transmit_next(SM) ->
  Head = nl_hf:head_transmission(SM),

  Dst_handler =
  fun (LSM, dst_reached) ->
        [nl_hf:pop_transmission(__, head, Head),
         maybe_pick(__)
        ](LSM);
      (LSM, _) ->
        fsm:set_event(LSM, eps)
  end,

  Head_handler =
  fun(LSM, empty) ->
      maybe_pick(LSM);
     (LSM, T) ->
      Dst_handler(LSM, nl_hf:getv(flag, T))
  end,

  Head_handler(SM, Head).

process_overheared_packet(SM, Tuple) ->
  {Src, Rssi, Integrity} =
  case Tuple of
    {recvpbm,_,RSrc,_,_,  RRssi,RIntegrity,_,_} ->
      {RSrc, RRssi, RIntegrity};
    {Format,_,RSrc,_,_,_,RRssi,RIntegrity,_,_} when Format == recvim;
                                                    Format == recvims;
                                                    Format == recv ->
      {RSrc, RRssi, RIntegrity}
  end,

  Time = share:get(SM, neighbour_life),
  NL_Src  = nl_hf:mac2nl_address(Src),
  [nl_hf:fill_statistics(__, overheared, NL_Src),
   fsm:set_timeout(__, {s, Time}, {neighbour_life, NL_Src}),
   nl_hf:add_neighbours(__, NL_Src, {Rssi, Integrity})
  ](SM).

process_received_packet(SM, Tuple) ->
  ?INFO(?ID, "process_received_packet : ~w ~n", [Tuple]),
  Blacklist = share:get(SM, blacklist),
  case Tuple of
  {recv, _, Src, Dst, _, _, Rssi, Integrity, _, Payload} ->
    NL_Src  = nl_hf:mac2nl_address(Src),
    In_Blacklist = lists:member(NL_Src, Blacklist),
    [nl_hf:fill_statistics(__, neighbours, NL_Src),
     process_received_packet(__, In_Blacklist, {Src, Dst, Rssi, Integrity, Payload})
    ](SM);
  {recvim, _, Src, Dst, _, _, Rssi, Integrity, _, Payload} ->
    NL_Src  = nl_hf:mac2nl_address(Src),
    In_Blacklist = lists:member(NL_Src, Blacklist),
    [nl_hf:fill_statistics(__, neighbours, NL_Src),
     process_received_packet(__, In_Blacklist, {Src, Dst, Rssi, Integrity, Payload})
    ](SM);
  _ ->
    fsm:set_event(SM, eps)
end.

process_received_packet(SM, true, {Src, _, _, _, _}) ->
  Blacklist = share:get(SM, blacklist),
  ?INFO(?ID, "Source ~p is in the blacklist : ~w ~n", [Src, Blacklist]),
  fsm:set_event(SM, eps);
process_received_packet(SM, false, AT) ->
  ?TRACE(?ID, "Recv AT command ~p~n", [AT]),
  {NL_AT_Src, Dst, AT_Rssi, AT_Integrity, Payload} = AT,
  Local_address = share:get(SM, local_address),
  NL_Dst  = nl_hf:mac2nl_address(Dst),
  Adressed = (Dst  =:= 255) or (NL_Dst =:= Local_address),
  PPid = ?PROTOCOL_NL_PID(share:get(SM, protocol_name)),

  try
    {Pid, _} = nl_hf:extract_payload_nl_header(SM, Payload),
    [nl_hf:add_neighbours(__, NL_AT_Src, {AT_Rssi, AT_Integrity}),
     packet_handler(__, (PPid =:= Pid), Adressed, AT)
    ](SM)
  catch error: Reason ->
    % Got a message not for NL, no NL header
    ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
    fsm:set_event(SM, eps)
  end.

packet_handler(SM, false, _, AT) ->
  ?TRACE(?ID, "Message is not applicable with current protocol ~p ~n", [AT]),
  fsm:set_event(SM, eps);
packet_handler(SM, true, Adressed, {Src, Dst, AT_Rssi, AT_Integrity, Payload}) ->
  NL_AT_Src  = nl_hf:mac2nl_address(Src),
  NL_AT_Dst  = nl_hf:mac2nl_address(Dst),
  {_, Tuples} = nl_hf:extract_payload_nl_header(SM, Payload),
  ?TRACE(?ID, "Extracted messages  ~p ~n", [Tuples]),

  Channel = {NL_AT_Src, NL_AT_Dst, AT_Rssi, AT_Integrity},
  parse_packet_handler(SM, Adressed, Channel, Tuples).

parse_packet_handler(SM, _, _, []) ->
  Sensing = nl_hf:get_params_timeout(SM, sensing_timeout),
  case Sensing of
    [] ->
      [fsm:set_timeout(__, {ms, rand:uniform(1000)}, relay),
       fsm:set_event(__, eps)
      ](SM);
    _ ->
      fsm:set_event(SM, eps)
  end;
parse_packet_handler(SM, Adressed, Channel, [Tuple | Tail]) ->
  ?TRACE(?ID, "Extracted message  ~p ~n", [Tuple]),
  [packet_handler_helper(__, Adressed, Channel, Tuple, false),
   parse_packet_handler(__, Adressed, Channel, Tail)
  ](SM).

packet_handler_helper(SM, false, Channel, Tuple, _) ->
  ?INFO(?ID, "Handle packet, but not relay ~p~n", [Tuple]),
  Local_address = share:get(SM, local_address),
  [Flag, Dst, Mtype] = nl_hf:getv([flag, dst, mtype], Tuple),

  Process_ack =
  ((Flag == ack) or (Flag == dst_reached)) and
  ((Mtype == data) or (Mtype == path_data)) and
  ((Dst == Local_address) or (nl_hf:routing_exist(SM, Dst))),
  ?INFO(?ID, "packet_handler_helper Flag = ~p Mtype = ~p Dst = ~p~n", [Flag, Mtype, Dst]),

  if Process_ack ->
    ?INFO(?ID, "Got ack with other package ~p~n", [Tuple]),
    packet_handler_helper(SM, true, Channel, Tuple, true);
  true ->
    [nl_hf:pop_transmission(__, Tuple),
     fsm:set_event(__, relay)
    ](SM)
  end;
packet_handler_helper(SM, true, Channel, Tuple, Only_combination) ->
  {NL_AT_Src, _, _, _} = Channel,
  Time = share:get(SM, neighbour_life),
  Flag = nl_hf:getv(flag, Tuple),
  [process_package(__, Flag, Tuple),
   check_if_processed(__, Tuple, Channel, Only_combination),
   nl_hf:set_processing_time(__, received, Tuple),
   fsm:set_timeout(__, {s, Time}, {neighbour_life, NL_AT_Src}),
   nl_hf:clear_event_params(__, if_processed)
  ](SM).

cancel_wpath(SM) ->
  TQ = share:get(SM, transmission),
  Has_path_packets = nl_hf:has_path_packets(TQ, false, 0),
  if Has_path_packets == false ->
    share:put(SM, waiting_path, false);
  true -> SM
  end.

check_if_processed(SM, Tuple, Channel, Only_combination) ->
  {NL_AT_Src, NL_AT_Dst, AT_Rssi, AT_Integrity} = Channel,
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_Address = share:get(SM, local_address),
  [Flag, NL_Src, NL_Dst, MType, Path, Rssi, Integrity, Min_integrity, Neighbours, Payload] =
    nl_hf:getv([flag, src, dst, mtype, path, rssi,integrity, min_integrity, neighbours, payload], Tuple),

  Routing_exist =
  not Protocol_Config#pr_conf.ry_only and
  Protocol_Config#pr_conf.pf and nl_hf:routing_exist(SM, NL_Dst),

  Update_routing =
  (NL_AT_Dst == ?ADDRESS_MAX) and (NL_Src == Local_Address)
  and ((Flag == data) or (MType == data)) and Routing_exist,

  Routing_handler =
  fun (LSM) when Update_routing ->
        nl_hf:delete_neighbour(LSM, NL_AT_Src);
      (LSM) -> LSM
  end,

  Transmission_handler =
  fun (LSM, _, T) when Only_combination ->
        nl_hf:fill_transmission(LSM, combination, T);
      (LSM, Type, T) ->
        nl_hf:fill_transmission(LSM, Type, T)
  end,

  Neighbours_handler =
  fun (LSM, true) ->
        New_path = nl_hf:update_path(SM, Path),
        Ack_tuple = nl_hf:recreate_response(LSM, MType, ack, Tuple, Channel),
        ?TRACE(?ID, "relay ack ~p~n", [Ack_tuple]),
        [cancel_wpath(__),
         nl_hf:update_routing(__, Path),
         nl_hf:add_to_paths(__, NL_Src, NL_Dst, New_path, Integrity, Min_integrity, Rssi),
         Transmission_handler(__, fifo, Ack_tuple)
        ](LSM);
      (LSM, false) -> LSM
  end,

  If_Processed = nl_hf:get_event_params(SM, if_processed),
  Recreate_handler =
  fun (LSM) when Flag == path, MType == path_addit->
        Path_tuple = nl_hf:recreate_path_evo(LSM, AT_Rssi, AT_Integrity, Min_integrity, Tuple),
        ?TRACE(?ID, "relay path ~p~n", [Path_tuple]),
        Transmission_handler(LSM, fifo, Path_tuple);
      (LSM) when Flag == path, MType == path_neighbours->
        Path_tuple = nl_hf:recreate_path_neighbours(LSM, Tuple),
        New_path = nl_hf:update_path(SM, Path),
        ?TRACE(?ID, "relay path ~p~n", [Path_tuple]),
        [nl_hf:add_to_paths(__, NL_Src, NL_Dst, New_path, Integrity, Min_integrity, Rssi),
         Transmission_handler(__, fifo, Path_tuple)
        ](LSM);
      (LSM) when Flag == ack, MType == path_addit->
        ?TRACE(?ID, "relay ack ~p~n", [Payload]),
        Ack_tuple = nl_hf:recreate_response(LSM, MType, ack, Tuple, Channel),
        [cancel_wpath(__),
         nl_hf:update_routing(__, Path),
         Transmission_handler(__, fifo, Ack_tuple)
        ](LSM);
      (LSM) when Flag == ack, MType == path_neighbours->
        ?TRACE(?ID, "relay ack ~p ~p~n", [Local_Address, Neighbours]),
        Member = lists:member(Local_Address, Neighbours),
        Neighbours_handler(LSM, Member);
      (LSM) when Flag == ack ->
        ?TRACE(?ID, "relay ack ~p~n", [Payload]),
        Ack_tuple = nl_hf:recreate_response(LSM, MType, ack, Tuple, Channel),
        Transmission_handler(LSM, fifo, Ack_tuple);
      (LSM) when MType == path_data ->
        ?TRACE(?ID, "relay path data ~p~n", [Path]),
        Path_data_tuple = nl_hf:update_path(SM, Tuple),
        New_path = nl_hf:getv(path, Path_data_tuple),
        [nl_hf:update_routing(__, New_path),
         Transmission_handler(__, fifo, Path_data_tuple)
        ](LSM);
      (LSM) when Protocol_Config#pr_conf.brp, Flag == data ->
        [nl_hf:update_stable_path(__, NL_AT_Src, NL_AT_Dst, NL_Src, NL_Dst),
         Transmission_handler(__, fifo, Tuple)
        ](LSM);
      (LSM) ->
        Transmission_handler(LSM, fifo, Tuple)
  end,

  ?INFO(?ID, "Ret process_package ~p - ~p: ~n",[If_Processed, Tuple]),
  ?INFO(?ID, "NL_Dst ~p  Local_Address ~p~n",[NL_Dst, Local_Address]),

  Is_destination = (NL_Dst =:= Local_Address),
  Is_path_packet = (Flag == path) and ((MType == path_addit) or (MType == path_neighbours)),

  Process_packet =
  fun (LSM, {if_processed, not_processed}) when NL_Dst =:= ?ADDRESS_MAX,
                                                not Protocol_Config#pr_conf.br_na ->
        [nl_hf:fill_statistics(__, Tuple),
         Transmission_handler(__, fifo, Tuple),
         fsm:cast(__, nl_impl, {send, {nl, recv, NL_Src, ?ADDRESS_MAX, Payload}})
        ](LSM);
      (LSM, {if_processed, not_processed}) when Is_destination ->
        process_destination(LSM, Channel, Tuple);
      (LSM, {if_processed, processed}) when Is_destination,
                                            Is_path_packet ->
        process_destination(LSM, Channel, Tuple);
      (LSM, {if_processed, not_processed}) ->
        Recreate_handler(LSM);
      (LSM, _) -> LSM
  end,

  [Process_packet(__, If_Processed),
   Routing_handler(__)
  ](SM).

check_path_timeout(#sm{timeouts = Timeouts}, Src, Dst) ->
  length(lists:filter(
    fun({E, {_, S, D, _, _}}) -> ((E == choose_path) and (S == Src) and (D == Dst));
       ({_, _}) -> false
    end, Timeouts)) =:= 1.

choose_stable(SM, Recv_tuple) ->
  [Pkg_ID, NL_Src, NL_Dst, MType, Path, Integrity, Min_integrity, Rssi, Payload] =
    nl_hf:getv([id, src, dst, mtype, path, integrity, min_integrity, rssi, payload], Recv_tuple),
  Timeout_tuple = {Pkg_ID, NL_Src, NL_Dst, MType, Payload},
  Path_timeout = check_path_timeout(SM, NL_Src, NL_Dst),
  Check_path = nl_hf:check_tranmission_path(SM, Timeout_tuple),
  ?INFO(?ID, "choose_stable ~p ~p~n",  [Path_timeout, Check_path]),
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  New_path = nl_hf:update_path(SM, Path),
  Set_path_timeout =
  fun (LSM, false) when not Check_path ->
        [nl_hf:add_to_paths(__, NL_Src, NL_Dst, New_path, Integrity, Min_integrity, Rssi),
         fsm:set_timeout(__, {s, 3}, {choose_path, Timeout_tuple})
        ](LSM);
      (LSM, false) when Protocol_Config#pr_conf.brp ->
        nl_hf:add_to_paths(LSM, NL_Src, NL_Dst, New_path, Integrity, Min_integrity, Rssi);
      (LSM, false) -> LSM;
      (LSM, true) ->
        nl_hf:add_to_paths(LSM, NL_Src, NL_Dst, New_path, Integrity, Min_integrity, Rssi)
  end,
  Set_path_timeout(SM, Path_timeout).

set_stable_path(SM, Tuple) ->
  {_, NL_Src, NL_Dst, MType, _} = Tuple,
  Stable_path = nl_hf:get_stable_path(SM, MType, NL_Src, NL_Dst),
  set_stable_path(SM, MType, Tuple, Stable_path).

set_stable_path(SM, _, _, nothing) -> SM;
set_stable_path(SM, path_neighbours, Tuple, Stable_path) ->
  {Pkg_ID, NL_Src, NL_Dst, MType, Payload} = Tuple,
  Send_tuple = nl_hf:create_ack_path(SM, ack, MType, Pkg_ID, NL_Src, NL_Dst, 0, Payload, Stable_path),
  ?TRACE(?ID, " ~p Stable Path ~p~n", [Send_tuple, Stable_path]),
  nl_hf:fill_transmission(SM, fifo, Send_tuple);

set_stable_path(SM, path_addit, Tuple, Stable_path) ->
  {Pkg_ID, NL_Src, NL_Dst, MType, Payload} = Tuple,
  New_path = nl_hf:update_path(SM, Stable_path),
  Send_tuple = nl_hf:create_ack_path(SM, ack, MType, Pkg_ID, NL_Src, NL_Dst, 0, Payload, New_path),
  ?TRACE(?ID, " ~p Stable Path ~p~n", [Send_tuple, New_path]),
  [nl_hf:remove_old_paths(__, NL_Src, NL_Dst),
   nl_hf:update_routing(__, New_path),
   nl_hf:fill_transmission(__, fifo, Send_tuple)
  ](SM).


set_stable_ack_path(SM, {NL_Src, NL_Dst}) ->
  Stable_path = nl_hf:get_stable_path(SM, NL_Src, NL_Dst),
  New_path = nl_hf:update_path(SM, Stable_path),
  
  Cast_handler =
  fun(LSM) ->
    Routing = nl_hf:routing_to_list(LSM),
    fsm:cast(LSM, nl_impl, {send, {nl, routing, Routing}})
  end,
  
  ?TRACE(?ID, "Stable Path ~p~n", [Stable_path]),
  [nl_hf:update_routing(__, New_path),
   cancel_wpath(__),
   Cast_handler(__),
   fsm:clear_timeout(__, {path_establish, NL_Src}),
   nl_hf:remove_old_paths(__, NL_Src, NL_Dst),
   fsm:set_event(__, relay)
  ](SM).

% check if protocol needs to send ack
% if not, sent dst_reacehd to end flooding
process_destination(SM, Channel, Recv_tuple) ->
  ?INFO(?ID, "process_destination ~p~n", [Recv_tuple]),
  {NL_AT_Src, NL_AT_Dst, _, _} = Channel,
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Ack_protocol = Protocol_Config#pr_conf.ack,
  [Flag, Pkg_ID, NL_Src, NL_Dst, MType, Integrity, Min_integrity, Rssi, Path, Payload] =
    nl_hf:getv([flag, id, src, dst, mtype, integrity, min_integrity, rssi, path, payload], Recv_tuple),

  Ack_handler =
  fun (LSM, true, Ack_Pkg_ID, Hops) ->
        Ack_tuple = {Ack_Pkg_ID, NL_Dst, NL_Src},
        ?TRACE(?ID, "Ack_handler clear ack timeout ~p~n", [Ack_tuple]),
        [fsm:clear_timeout(__, {ack_timeout, Ack_tuple}),
         nl_hf:fill_statistics(__, ack, delivered_on_src, Hops + 1, Ack_tuple),
         fsm:cast(__, nl_impl, {send, {nl, delivered, Ack_Pkg_ID, NL_Dst, NL_Src}})
        ](LSM);
      (LSM, false, _, _) -> LSM
  end,

  Cast_handler =
    fun(LSM) ->
      Routing = nl_hf:routing_to_list(LSM),
      fsm:cast(LSM, nl_impl, {send, {nl, routing, Routing}})
    end,

  Prepare_path =
  fun (LSM, path_addit) ->
        nl_hf:update_path(LSM, lists:reverse(Path));
      (LSM, path_neighbours) ->
        nl_hf:update_path(LSM, Path)
  end,

  Path_handler =
  fun (LSM, path_data) ->
        Path_data_tuple = nl_hf:update_path(SM, Recv_tuple),
        New_path = nl_hf:getv(path, Path_data_tuple),
        nl_hf:update_routing(LSM, New_path);
      (LSM, Type) when Type == path_addit; Type == path_neighbours ->
        New_path = Prepare_path(LSM, Type),
        [nl_hf:update_routing(__, New_path),
         Cast_handler(__)
        ](LSM);
      (LSM, _) -> LSM
  end,

  Ack_path_handler =
  fun (LSM, path_addit) ->
        Send_tuple = nl_hf:create_response(SM, dst_reached, MType, Pkg_ID, NL_Src, NL_Dst, 0, Payload),
        [nl_hf:pop_transmission(__, Recv_tuple),
        nl_hf:fill_transmission(__, fifo, Send_tuple),
        Path_handler(__, MType),
        cancel_wpath(__),
        fsm:clear_timeout(__, {path_establish, NL_Src}),
        fsm:set_event(__, relay)
       ](LSM);
      (LSM, path_neighbours) ->
        New_path = nl_hf:update_path(SM, Path),
        Send_tuple = nl_hf:create_response(SM, dst_reached, MType, Pkg_ID, NL_Src, NL_Dst, 0, Payload),
        [nl_hf:add_to_paths(__, NL_Src, NL_Dst, New_path, Integrity, Min_integrity, Rssi),
         nl_hf:pop_transmission(__, Recv_tuple),
         nl_hf:fill_transmission(__, fifo, Send_tuple),
         fsm:set_timeout(__, {s, 3}, {choose_ack_path, {NL_Src, NL_Dst} })
        ](LSM)
  end,

  Routing_handler =
  fun (LSM) when Protocol_Config#pr_conf.brp, Flag == data ->
      nl_hf:update_stable_path(LSM, NL_AT_Src, NL_AT_Dst, NL_Src, NL_Dst);
      (LSM) -> LSM
  end,

  Destination_handler =
  fun (LSM) when Flag == path ->
        choose_stable(LSM, Recv_tuple);
      (LSM) when Flag == ack, MType == path_addit ->
        ?TRACE(?ID, "extract ack path ~p ~n", [Recv_tuple]),
        Ack_path_handler(LSM, MType);
      (LSM) when Flag == ack, MType == path_neighbours ->
        New_path = nl_hf:update_path(LSM, Path),
        Neighbour = nl_hf:get_prev_neighbour(LSM, New_path),
        Neighbours = share:get(SM, nothing, current_neighbours, []),
        Member = lists:member(Neighbour, Neighbours),
        ?TRACE(?ID, "extract ack path ~p ~p ~p ~p~n", [Recv_tuple, Neighbour, Neighbours, New_path]),
        if Member ->
          Ack_path_handler(LSM, MType);
        true ->
          nl_hf:pop_transmission(LSM, Recv_tuple)
        end;
      (LSM) when Ack_protocol, Flag == ack ->
        [Hops, Ack_Pkg_ID] = nl_hf:extract_response([hops, id], Payload),
        ?TRACE(?ID, "extract ack ~p ~p ~p~n", [Hops, Ack_Pkg_ID, Payload]),
        Send_tuple = nl_hf:create_response(SM, dst_reached, MType, Ack_Pkg_ID, NL_Src, NL_Dst, 0, Payload),
        Wait_ack = fsm:check_timeout(SM, {ack_timeout, {Ack_Pkg_ID, NL_Dst, NL_Src}}),
        ?TRACE(?ID, "wait ack ~p~n", [Wait_ack]),
        [nl_hf:fill_statistics(__, Recv_tuple),
         nl_hf:pop_transmission(__, Recv_tuple),
         nl_hf:fill_transmission(__, fifo, Send_tuple),
         Ack_handler(__, Wait_ack, Ack_Pkg_ID, Hops)
        ](LSM);
      (LSM) when Ack_protocol ->
        Send_tuple = nl_hf:create_response(SM, ack, MType, Pkg_ID, NL_Src, NL_Dst, 0, Payload),
        ?TRACE(?ID, "create ack ~p~n", [Send_tuple]),
        [Routing_handler(__),
         nl_hf:fill_statistics(__, Recv_tuple),
         Path_handler(__, MType),
         nl_hf:fill_transmission(__, fifo, Send_tuple),
         fsm:cast(__, nl_impl, {send, {nl, recv, NL_Src, NL_Dst, Payload}})
        ](LSM);
      (LSM) ->
        Send_tuple = nl_hf:create_response(SM, dst_reached, MType, Pkg_ID, NL_Src, NL_Dst, 0, Payload),
        [Routing_handler(__),
         nl_hf:fill_statistics(__, Recv_tuple),
         nl_hf:fill_transmission(__, fifo, Send_tuple),
         fsm:cast(__, nl_impl, {send, {nl, recv, NL_Src, NL_Dst, Payload}})
        ](LSM)
  end,
  Destination_handler(SM).

process_package(SM, dst_reached, Tuple) ->
  [nl_hf:update_received(__, Tuple),
   nl_hf:pop_transmission(__, Tuple),
   nl_hf:set_event_params(__, {if_processed, nothing})
  ](SM);
process_package(SM, _Flag, Tuple) ->
  Protocol_name = share:get(SM, protocol_name),
  Protocol_config = share:get(SM, protocol_config, Protocol_name),
  Local_Address = share:get(SM, local_address),
  [TTL, Src, Dst] = nl_hf:getv([ttl, src, dst], Tuple),
  {Exist, QTTL} = nl_hf:exists_received(SM, Tuple),

  % TODO check integrity later
  Relay =
  if Protocol_config#pr_conf.prob ->
    check_probability(SM);
  true -> true
  end,

  ?TRACE(?ID, "process_package : Exist ~p  TTL ~p QTTL ~p Recv Tuple ~p Relay ~p~n",
              [Exist, TTL, QTTL, Tuple, Relay]),

  Processed_handler =
  fun (LSM) when QTTL == dst_reached ->
       nl_hf:set_event_params(LSM, {if_processed, not_processed});
      (LSM) when not Exist, not Relay ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when not Exist ->
       nl_hf:set_event_params(LSM, {if_processed, not_processed});
      (LSM) when Src =:= Local_Address; Dst =:= Local_Address ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when TTL < QTTL, not Relay ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when TTL < QTTL ->
       nl_hf:set_event_params(LSM, {if_processed, not_processed});
      (LSM) ->
       nl_hf:set_event_params(LSM, {if_processed, processed})
  end,

  case Exist of
      false when QTTL == dst_reached ->
        [%nl_hf:pop_transmission(__, Tuple),
         nl_hf:update_received(__, Tuple),
         Processed_handler(__)
        ](SM);
      false ->
        [nl_hf:update_received(__, Tuple),
         Processed_handler(__)
        ](SM);
      true when Src =:= Local_Address; Dst =:= Local_Address; TTL < QTTL ->
        [nl_hf:pop_transmission(__, Tuple),
         nl_hf:update_received_TTL(__, Tuple),
         Processed_handler(__)
        ](SM);
      _ ->
        [nl_hf:pop_transmission(__, Tuple),
         Processed_handler(__)
        ](SM)
  end.

% Snbr - size / number of nodes
% RN - random number between 0 and 1
% Relay the packet when (P > RN) and the packet was received first time
check_probability(SM) ->
  {Pmin, Pmax} = share:get(SM, probability),
  Neighbours = share:get(SM, nothing, current_neighbours, []),
  Snbr = length(Neighbours),
  P = multi_array(Snbr, Pmax, 1),
  ?TRACE(?ID, "Snbr ~p probability ~p ~n",[Snbr, P]),
  RN = rand:uniform(),
  Calculated_p =
  if P < Pmin -> Pmin; true -> P end,
  ?TRACE(?ID, "Snbr ~p P ~p Calculated_p ~p > RN ~p :  ~n", [Snbr, P, Calculated_p, RN]),
  Calculated_p > RN.
multi_array(0, _, P) -> P;
multi_array(Snbr, Pmax, P) -> multi_array(Snbr - 1, Pmax, P * Pmax).

maybe_pick(SM) ->
  Q = share:get(SM, transmission),
  Sensing = nl_hf:get_params_timeout(SM, sensing_timeout),

  case queue:is_empty(Q) of
    true when Sensing =:= [] -> fsm:set_event(SM, idle);
    true -> fsm:set_event(SM, eps);
    false -> fsm:set_event(SM, pick)
    %false when Sensing =:= [] -> fsm:set_event(SM, pick);
    %_ -> fsm:set_event(SM, eps)
  end.

process_async(SM, Notification) ->
  Local_Address = share:get(SM, local_address),
  case Notification of
    {sendstart,_,_,_,_} ->
      fsm:cast(SM, nl_impl, {send, {nl, sendstart, Local_Address}});
    {sendend,_,_,_,_} ->
      fsm:cast(SM, nl_impl, {send, {nl, sendend, Local_Address}});
    {recvstart} ->
      fsm:cast(SM, nl_impl, {send, {nl, recvstart, Local_Address}});
    {recvend,_,_,_,_} ->
      fsm:cast(SM, nl_impl, {send, {nl, recvend, Local_Address}});
    {recvfailed,_,_,_} ->
      fsm:cast(SM, nl_impl, {send, {nl, recvfailed, Local_Address}});
    _ -> SM
  end.
