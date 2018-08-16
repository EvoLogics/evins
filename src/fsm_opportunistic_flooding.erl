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
                 {send, transmit}
                 ]},

                {transmit,
                 [{transmitted, sensing}
                 ]},

                {sensing,
                 [{relay, sensing},
                  {send, sensing},
                  {sensing_timeout, collision},
                  {pick, transmit},
                  {idle, idle}
                 ]},

                {collision,
                 [{relay, collision},
                  {send, collision},
                  {pick, transmit},
                  {idle, idle}
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
      {timeout,{sensing_timeout, _Send_Tuple}} ->
        ?INFO(?ID, "St ~p Ev ~p ~n", [SM#sm.event, SM#sm.state]),
        fsm:run_event(MM, SM#sm{event = sensing_timeout}, {});
      {async, {pid, Pid}, Recv_Tuple} ->
        ?INFO(?ID, "My message: ~p~n", [Recv_Tuple]),
        [process_received_packet(__, Recv_Tuple),
        fsm:run_event(MM, __, {})](SM);
      {async, {pid, _Pid}, _Recv_Tuple} ->
        % TODO: add neighbours
        SM;
      {nl, send, Local_Address, _Payload} ->
        fsm:cast(SM, nl_impl, {send, {nl, send, error}});
      {nl, send, _IDst, _Payload} ->
        [process_nl_send(__, Term),
        fsm:run_event(MM, __, {})](SM);
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
                 {last_states, queue:new()},
                 {pr_states, queue:new()},
                 {paths, queue:new()},
                 {st_neighbours, queue:new()},
                 {st_data, queue:new()},
                 {received_queue, queue:new()},
                 {transmission_queue, queue:new()}]),
  nl_hf:init_dets(SM).
%%------------------------------------------ Handle functions -----------------------------------------------------
handle_idle(_MM, SM, Term) ->
  ?INFO(?ID, "idle state ~120p~n", [Term]),
  fsm:set_event(SM, eps).

handle_transmit(_MM, SM, Term) ->
  ?INFO(?ID, "transmit state ~120p~n", [Term]),
  try_send_message(SM).

handle_sensing(_MM, SM, _Term) ->
  ?INFO(?ID, "sensing state ~120p~n", [SM#sm.event]),
  case SM#sm.event of
    transmitted ->
      check_front_transmission_queue(SM);
    relay ->
      handle_transmission_queue(SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_collision(_MM, SM, _Term) ->
  ?INFO(?ID, "collision state ~p~n", [SM#sm.event]),
  case SM#sm.event of
    sensing_timeout ->
      % 1. decreace TTL for every packet in the queue
      % 2. delete packets withh TTL 0 or < 0
      % 3. check, if queue is empty -> idle
      % 4. check, if queue is not empty -> pick -> transmit the head of queue
      nl_hf:decrease_TTL_transmission_queue(SM),
      handle_transmission_queue(SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).
%%------------------------------------------ Helper functions -----------------------------------------------------
process_nl_send(SM, NL_Send_Tuple) ->
  NL_Info = nl_hf:code_send_tuple(SM, NL_Send_Tuple),
  % Save message in the queue
  nl_hf:fill_transmission_queue(SM, filo, NL_Info),
  Fill_Transmiision_Queue = nl_hf:get_event_params(SM, fill_tq),
  case Fill_Transmiision_Queue of
    {fill_tq, error} ->
      [fsm:cast(SM, nl_impl, {send, {nl, send, error}}),
      nl_hf:crear_event_params(__, fill_tq),
      fsm:set_event(__, eps)](SM);
    _ ->
      [fsm:cast(__, nl_impl, {send, {nl, send, 0}}),
      nl_hf:crear_event_params(__, fill_tq),
      fsm:set_event(__, send)
      ] (SM)
  end.

try_send_message(SM) ->
  % take first meesage from the queue to transmit
  {value, Front_Item} = nl_hf:get_front_transmission_queue(SM),
  ?INFO(?ID, "Try send message: front item ~p~n", [Front_Item]),
  AT_Command = nl_hf:create_nl_at_command(SM, Front_Item),
  Handle_cache =
  fun(LSM, nothing) -> LSM;
     (LSM, Next) ->
      % TODO: should be processed?
      ?INFO(?ID, "Handle_cache next ~p~n", [Next]),
      LSM
      %fsm:send_at_command(LSM, Next)
  end,
  Rand_timeout = nl_mac_hf:rand_float(SM, tmo_sensing),
  [fsm:maybe_send_at_command(__, AT_Command, Handle_cache),
   fsm:set_timeout(__, {ms, Rand_timeout}, {sensing_timeout, Front_Item}),
   fsm:set_event(__, transmitted)
  ](SM).

check_front_transmission_queue(SM) ->
  Result = nl_hf:get_front_transmission_queue(SM),
  check_front_transmission_queue(SM, Result).

check_front_transmission_queue(SM, empty) ->
  fsm:set_event(SM, idle);
check_front_transmission_queue(SM, {value, Front_item = {dst_reached,_,_,_,_,_}}) ->
  [nl_hf:delete_from_transmission_queue(SM, Front_item),
   handle_transmission_queue(__)](SM);
check_front_transmission_queue(SM, {value, _Front_Item}) ->
  fsm:set_event(SM, eps).

process_received_packet(SM, Recv_Tuple) ->
  Blacklist = share:get(SM, blacklist),
  case Recv_Tuple of
  {recv, _, Src, Dst, _, _, Rssi, Integrity, _, Payload} ->
    NL_Src  = nl_hf:mac2nl_address(Src),
    Is_In_Blacklist = lists:member(NL_Src, Blacklist),
    process_received_packet(SM, Is_In_Blacklist, {Src, Dst, Rssi, Integrity, Payload});
  {recvim, _, Src, Dst, _, _, Rssi, Integrity, _, Payload} ->
    NL_Src  = nl_hf:mac2nl_address(Src),
    Is_In_Blacklist = lists:member(NL_Src, Blacklist),
    process_received_packet(SM, Is_In_Blacklist, {Src, Dst, Rssi, Integrity, Payload});
  _ ->
    fsm:set_event(SM, eps)
end.

process_received_packet(SM, true, {Src, _Dst, _Rssi, _Integrity, _Payload}) ->
  Blacklist = share:get(SM, blacklist),
  ?INFO(?ID, "Source ~p is in the blacklist : ~w ~n", [Src, Blacklist]),
  fsm:set_event(SM, eps);
process_received_packet(SM, false, AT_Command) ->
  ?TRACE(?ID, "Recv AT command parameters ~p~n", [AT_Command]),
  {_Src, Dst, _Rssi, _Integrity, _Payload} = AT_Command,
  Local_address = share:get(SM, local_address),
  NL_Dst  = nl_hf:mac2nl_address(Dst),
  Adressed_To_Me = (Dst  =:= 255) or (NL_Dst =:= Local_address),
  process_received_packet_to_me(SM, Adressed_To_Me, AT_Command).

process_received_packet_to_me(SM, false, _AT_Command) ->
  fsm:set_event(SM, eps);
process_received_packet_to_me(SM, true, AT_Command) ->
  Current_Pid = ?PROTOCOL_NL_PID(share:get(SM, protocol_name)),
  {_Src, _Dst, _Rssi, _Integrity, Payload} = AT_Command,
  try
      {Pid, _,  _,  _,  _,  _,  _} = nl_hf:extract_payload_nl_header(SM, Payload),
      Adressed_To_Protocol = (Current_Pid =:= Pid),
      process_received_packet_to_protocol(SM, Adressed_To_Protocol, AT_Command)
  catch error: Reason ->
  % Got a message not for NL layer
  ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
  fsm:set_event(SM, eps)
  end.

process_received_packet_to_protocol(SM, false, AT_Command) ->
  ?TRACE(?ID, "Message is not applicable with current protocol ~p ~n", [AT_Command]),
  fsm:set_event(SM, eps);
process_received_packet_to_protocol(SM, true, AT_Command) ->
  ?INFO(?ID, "process_received_packet_to_protocol ~p ~n", [AT_Command]),
  Protocol_Name = share:get(SM, protocol_name),
  _Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  {Src, Dst, _Rssi, _Integrity, Payload} = AT_Command,

  _NL_AT_Src  = nl_hf:mac2nl_address(Src),
  _NL_AT_Dst  = nl_hf:mac2nl_address(Dst),

  {_Pid, Flag_Num, Pkg_ID, TTL, NL_Src, NL_Dst, Tail} =
      nl_hf:extract_payload_nl(SM, Payload),

  Flag = nl_hf:num2flag(Flag_Num, nl),
  NL_Recv_Tuple = {Flag, Pkg_ID, TTL, NL_Src, NL_Dst, Tail},

  [process_package(__, Flag, NL_Recv_Tuple),
   check_if_processed(__, NL_Recv_Tuple),
   nl_hf:crear_event_params(__, if_processed)
  ](SM).

check_if_processed(SM, NL_Recv_Tuple) ->
  Local_Address = share:get(SM, local_address),
  {Flag, Pkg_ID, _TTL, NL_Src, NL_Dst, Tail} = NL_Recv_Tuple,
  If_Processed = nl_hf:get_event_params(SM, if_processed),
  ?INFO(?ID, "Ret process_package ~p - ~p~n",[If_Processed, NL_Recv_Tuple]),
  case If_Processed of
      nothing -> fsm:set_event(SM, eps);
      _ when Flag =:= dst_reached ->
        fsm:set_event(SM, relay);
      {if_processed, not_processed} when NL_Dst =:= Local_Address ->
        % add dst_reached message to the queue
        Dst_Reached_Tuple = {dst_reached, Pkg_ID, 0, NL_Dst, NL_Src, <<"d">>},
        Cast_Tuple = {nl, recv, NL_Src, NL_Dst, Tail},
        [nl_hf:fill_transmission_queue(__, fifo, Dst_Reached_Tuple),
        fsm:cast(__, nl_impl, {send, Cast_Tuple}),
        fsm:set_event(__, relay)](SM);
      {if_processed, not_processed} ->
        [nl_hf:fill_transmission_queue(__, fifo, NL_Recv_Tuple),
        fsm:set_event(__, relay)](SM);
      _ ->
        fsm:set_event(SM, relay)
  end.

% check if same package was received from other src
% delete message, if received dst_reached wiht same pkgID and reverse src, dst
process_package(SM, dst_reached, NL_Recv_Tuple) ->
  [nl_hf:delete_from_transmission_queue(__, NL_Recv_Tuple),
   nl_hf:set_event_params(__, {if_processed, nothing})](SM);
process_package(SM, _Flag, NL_Recv_Tuple) ->
  {_Flag_Num, _Pkg_ID, TTL, _NL_Src, _NL_Dst, _Payload} = NL_Recv_Tuple,
  {Exist, Stored_TTL} = nl_hf:check_received_queue(SM, NL_Recv_Tuple),
  ?TRACE(?ID, "process_package : Exist ~p  TTL ~p Stored_TTL ~p Recv Tuple ~p~n",
              [Exist, TTL, Stored_TTL, NL_Recv_Tuple]),
  case Exist of
      false ->
        [nl_hf:queue_limited_push(__, received_queue, NL_Recv_Tuple, 30),
         nl_hf:set_event_params(__, {if_processed, not_processed})](SM);
      true when TTL < Stored_TTL ->
        [nl_hf:delete_from_transmission_queue(__, NL_Recv_Tuple),
         nl_hf:change_TTL_received_queue(__, NL_Recv_Tuple),
         nl_hf:set_event_params(__, {if_processed, not_processed})](SM);
      _ ->
        [nl_hf:delete_from_transmission_queue(__, NL_Recv_Tuple),
        nl_hf:set_event_params(__, {if_processed, processed})](SM)
  end.

% 1. decreace TTL for every packet in the queue
% 2. drop packets withh TTL 0 or < 0
% 3. check, if queue is empty -> idle
% 4. check, if queue is not empty -> pick -> transmit the head of queue
handle_transmission_queue(SM) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),
  case queue:is_empty(Q) of
    true -> fsm:set_event(SM, idle);
    false -> fsm:set_event(SM, pick)
  end.
