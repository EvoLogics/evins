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
                 {send, transmit},
                 {reset, idle}
                 ]},

                {transmit,
                 [{transmitted, sensing},
                 {reset, idle}
                 ]},

                {sensing,
                 [{relay, sensing},
                  {send, sensing},
                  {sensing_timeout, collision},
                  {pick, transmit},
                  {idle, idle},
                  {reset, idle}
                 ]},

                {collision,
                 [{relay, collision},
                  {send, collision},
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
    Local_Address = share:get(SM, local_address),
    Protocol_Name = share:get(SM, protocol_name),
    _Protocol_Config  = share:get(SM, {protocol_config, Protocol_Name}),
    Pid = share:get(SM, pid),
    Debug = share:get(SM, debug),

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
      {timeout, {neighbour_life, Address}} ->
        nl_hf:delete_neighbour(SM, Address);
      {timeout, {sensing_timeout, _Send_Tuple}} ->
        ?INFO(?ID, "St ~p Ev ~p ~n", [SM#sm.event, SM#sm.state]),
        fsm:run_event(MM, SM#sm{event = sensing_timeout}, {});
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
      {nl, send, Local_Address, _Payload} ->
        fsm:cast(SM, nl_impl, {send, {nl, send, error}});
      {nl, send, error} ->
        fsm:cast(SM, nl_impl, {send, {nl, send, error}});
      {nl, send, _IDst, _Payload} ->
        [process_nl_send(__, Term),
        fsm:run_event(MM, __, {})](SM);
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
  share:put(SM, [{path_exists, false},
                 {list_current_wvp, []},
                 {current_neighbours, []},
                 {neighbours_channel, []},
                 {s_total_sent, 1},
                 {r_total_sent, 1},
                 {last_states, queue:new()},
                 {pr_states, queue:new()},
                 {paths, queue:new()},
                 {st_data, queue:new()},
                 {retries_queue, queue:new()},
                 {received_queue, queue:new()},
                 {transmission_queue, queue:new()},
                 {statistics_neighbours, queue:new()},
                 {statistics_queue, queue:new()}]),
  nl_hf:init_dets(SM).
%%------------------------------------------ Handle functions -----------------------------------------------------
handle_idle(_MM, SM, Term) ->
  ?INFO(?ID, "idle state ~120p~n", [Term]),
  nl_hf:update_states(SM),
  fsm:set_event(SM, eps).

handle_transmit(_MM, SM, Term) ->
  ?INFO(?ID, "transmit state ~120p~n", [Term]),
  nl_hf:update_states(SM),
  Head = nl_hf:head_transmission(SM),
  try_transmit(SM, Head).

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
  NL = nl_hf:code_send_tuple(SM, Tuple),
  nl_hf:fill_transmission(SM, filo, NL),
  Fill = nl_hf:get_event_params(SM, fill_tq),

  Fill_handler =
  fun(LSM, {fill_tq, error}) ->
        [fsm:cast(__, nl_impl, {send, {nl, send, error}}),
         fsm:set_event(__, eps)
        ](LSM);
      (LSM, _) ->
        [fsm:cast(__, nl_impl, {send, {nl, send, 0}}),
         fsm:set_event(__, send)
        ](LSM)
  end,

  [nl_hf:clear_event_params(__, fill_tq),
   Fill_handler(__, Fill)
  ](SM).

% take first meesage from the queue to transmit
try_transmit(SM, empty) ->
  fsm:set_event(SM, transmitted);
try_transmit(SM, {value, Head}) ->
  ?INFO(?ID, "Try send message: head item ~p~n", [Head]),
  AT = nl_hf:create_nl_at_command(SM, Head),
  Sensing = nl_hf:rand_float(SM, tmo_sensing),
  Handle_cache =
  fun(LSM, nothing) -> LSM;
     (LSM, Next) ->
      % TODO: should be processed?
      ?INFO(?ID, "Handle_cache next ~p~n", [Next]),
      LSM
  end,

  [nl_hf:set_processing_time(__, transmitted, Head),
   nl_hf:decrease_retries(__, Head),
   nl_hf:update_received_TTL(__, Head),
   nl_hf:queue_push(__, received_queue, Head, 30),
   fsm:maybe_send_at_command(__, AT, Handle_cache),
   fsm:set_timeout(__, {ms, Sensing}, {sensing_timeout, Head}),
   fsm:set_event(__, transmitted)
  ](SM).

maybe_transmit_next(SM) ->
  Head = nl_hf:head_transmission(SM),

  Head_handler =
  fun(LSM, empty) ->
      maybe_pick(LSM);
     (LSM, {value, T = {dst_reached,_,_,_,_,_}}) ->
      [nl_hf:pop_transmission(__, head, T),
      maybe_pick(__)](LSM);
     (LSM, {value, _Head}) ->
      fsm:set_event(LSM, eps)
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
  {_Src, Dst, _Rssi, _Integrity, _Payload} = AT,
  Local_address = share:get(SM, local_address),
  NL_Dst  = nl_hf:mac2nl_address(Dst),
  Adressed = (Dst  =:= 255) or (NL_Dst =:= Local_address),

  Adress_handler =
    fun(LSM, false) ->
        fsm:set_event(LSM, eps);
       (LSM, true) ->
        PPid = ?PROTOCOL_NL_PID(share:get(LSM, protocol_name)),
        {_Src, _Dst, _Rssi, _Integrity, Payload} = AT,
        try
          {Pid, _,  _,  _,  _,  _,  _} = nl_hf:extract_payload_nl_header(LSM, Payload),
          packet_handler(LSM, (PPid =:= Pid), AT)
        catch error: Reason ->
        % Got a message not for NL
        ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
        fsm:set_event(LSM, eps)
        end
   end,

  Adress_handler(SM, Adressed).

packet_handler(SM, false, AT) ->
  ?TRACE(?ID, "Message is not applicable with current protocol ~p ~n", [AT]),
  fsm:set_event(SM, eps);
packet_handler(SM, true, {Src, _Dst, Rssi, Integrity, Payload}) ->
  NL_AT_Src  = nl_hf:mac2nl_address(Src),

  {_Pid, Flag_Num, Pkg_ID, TTL, NL_Src, NL_Dst, Tail} =
      nl_hf:extract_payload_nl(SM, Payload),

  Flag = nl_hf:num2flag(Flag_Num, nl),
  Tuple = {Flag, Pkg_ID, TTL, NL_Src, NL_Dst, Tail},
  Time = share:get(SM, neighbour_life),

  [process_package(__, Flag, Tuple),
   check_if_processed(__, NL_AT_Src, Tuple),
   nl_hf:set_processing_time(__, received, Tuple),
   fsm:set_timeout(__, {s, Time}, {neighbour_life, NL_AT_Src}),
   nl_hf:add_neighbours(__, NL_AT_Src, {Rssi, Integrity}),
   nl_hf:clear_event_params(__, if_processed)
  ](SM).

check_if_processed(SM, _NL_AT_Src, Tuple) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_Address = share:get(SM, local_address),
  {_Flag, Pkg_ID, _TTL, NL_Src, NL_Dst, Tail} = Tuple,

  %Cast_Tuple = {nl, recv, NL_AT_Src, NL_Dst, Tail},
  %fsm:cast(SM, nl_impl, {send, Cast_Tuple}),

  If_Processed = nl_hf:get_event_params(SM, if_processed),
  Sensing = nl_hf:get_params_timeout(SM, sensing_timeout),

  Relay_handler =
    fun(LSM) ->
      case Sensing of
        [] ->
          [fsm:set_timeout(__, {ms, rand:uniform(1000)}, relay),
           fsm:set_event(__, eps)
          ](LSM);
        _ ->
          fsm:set_event(LSM, eps)
      end
    end,

  ?INFO(?ID, "Ret process_package ~p - ~p: Sensing_Timeout ~p~n",[If_Processed, Tuple, Sensing]),
  case If_Processed of
      {if_processed, not_processed} when NL_Dst =:= ?ADDRESS_MAX,
                                         not Protocol_Config#pr_conf.br_na ->
        [nl_hf:fill_statistics(__, Tuple),
         nl_hf:fill_transmission(__, fifo, Tuple),
         fsm:cast(__, nl_impl, {send, {nl, recv, NL_Src, ?ADDRESS_MAX, Tail}}),
         Relay_handler(__)
        ](SM);
      {if_processed, not_processed} when NL_Dst =:= Local_Address ->
        Dst_Tuple = {dst_reached, Pkg_ID, 0, NL_Dst, NL_Src, <<"d">>},
        [nl_hf:fill_statistics(__, Tuple),
         nl_hf:fill_transmission(__, fifo, Dst_Tuple),
         fsm:cast(__, nl_impl, {send, {nl, recv, NL_Src, NL_Dst, Tail}}),
         Relay_handler(__)
        ](SM);
      {if_processed, not_processed} ->
        [Relay_handler(__),
         nl_hf:fill_transmission(__, fifo, Tuple)
        ](SM);
      _  ->
        Relay_handler(SM)
  end.

% check if same package was received from other src
% delete message, if received dst_reached wiht same pkgID and reverse src, dst
process_package(SM, dst_reached, Tuple) ->
  [nl_hf:queue_push(__, received_queue, Tuple, 30),
   nl_hf:pop_transmission(__, Tuple),
   nl_hf:set_event_params(__, {if_processed, nothing})
  ](SM);
process_package(SM, _Flag, Tuple) ->
  Protocol_name = share:get(SM, protocol_name),
  Protocol_config = share:get(SM, protocol_config, Protocol_name),
  Local_Address = share:get(SM, local_address),
  {_, _, TTL, Src, Dst, _Payload} = Tuple,
  {Exist, QTTL} = nl_hf:exists_received(SM, Tuple),

  Probability =
  if Protocol_config#pr_conf.prob ->
    check_probability(SM);
  true -> true
  end,

  ?TRACE(?ID, "process_package : Exist ~p  TTL ~p QTTL ~p Recv Tuple ~p Probability ~p~n",
              [Exist, TTL, QTTL, Tuple, Probability]),

  Processed_handler =
  fun (LSM) when QTTL == dst_reached ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when not Exist, not Probability ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when not Exist ->
       nl_hf:set_event_params(LSM, {if_processed, not_processed});
      (LSM) when Src =:= Local_Address; Dst =:= Local_Address ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when TTL < QTTL, not Probability ->
       nl_hf:set_event_params(LSM, {if_processed, processed});
      (LSM) when TTL < QTTL ->
       nl_hf:set_event_params(LSM, {if_processed, not_processed});
      (LSM) ->
       nl_hf:set_event_params(LSM, {if_processed, processed})
  end,

  case Exist of
      false ->
        [nl_hf:queue_push(__, received_queue, Tuple, 30),
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
  Q = share:get(SM, transmission_queue),
  Sensing = nl_hf:get_params_timeout(SM, sensing_timeout),

  case queue:is_empty(Q) of
    true when Sensing =:= [] -> fsm:set_event(SM, idle);
    true -> fsm:set_event(SM, eps);
    false -> fsm:set_event(SM, pick)
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