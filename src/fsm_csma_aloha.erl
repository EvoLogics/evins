%% Copyright (c) 2018, Veronika Kebkal <veronika.kebkal@evologics.de>
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
-module(fsm_csma_aloha).
-behaviour(fsm).

-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_sensing/3, handle_backoff/3, handle_transmit/3, handle_wait_transmittion/3]).

%%  CSMA-Aloha [1] (Carrier-Sense Multiple Access-Aloha) is an Aloha
%%  enhancement whereby short random channel sensing periods precede
%%  packet transmissions.
%%  Namely, before sending a packet, a node checks if the channel
%%  is free for a random amount of time, much shorter than the
%%  typical packet transmission and signal propagation time. If the
%%  channel is sensed busy, a subsequent channel sensing phase
%%  is scheduled (again of random duration), until the channel
%%  remains free for a whole sensing period. At this point the node
%%  can transmit the packet. This policy makes it possible to avoid
%%  most of the collisions induced by the lack of coordination
%%  in Aloha, while keeping channel access latencies low, and
%%  is hence a good representative of the class of uncoordinated
%%  random access protocols.
%%
%% 1. http://telecom.dei.unipd.it/media/download/382/
%% 2. http://telecom.dei.unipd.it/media/download/314/
%%
%%  [1] F. Guerra, P. Casari, and M. Zorzi, World Ocean Simulation System
%%  (WOSS): a simulation tool for underwater networks with realistic
%%  propagation modeling in Proc. of ACM WUWNet 2009, Berkeley, CA,
%%  2009.
%%
%%  CSMA-ALOHA is a form of ALOHA with a very short
%%  channel sensing phase before a packet is actually transmitted.
%%  Given that the typical balance between the packet transmission
%%  time and the propagation delay in underwater networks makes
%%  CSMA inefficient, the short sensing introduced here serves the
%%  only purpose to avoid a trivial collision scenario (i.e., where
%%  the current node starts its own transmission while a different
%%  signal is propagating in the same area where the node is
%%  located, resulting in likely collision at the intended receiver
%%  of such signal). The sensing time is randomized to avoid
%%  the synchronization of channel access attempts and repeated
%%  collisions. In case the channel is found busy, the transmitter
%%  employs a standard "binary exponential backoff scheme". This
%%  protocols is a mixed form of both ALOHA and CSMA, hence
%%  the name.
%%
%% 3. http://ieeexplore.ieee.org/xpls/abs_all.jsp?arnumber=6003490&tag=1
%%
%% Evologics specification:
%%
%% 1. Allowed are only instant messages (“*SENDIM”, DMACE protocol)
%% 2. There are 4 states: idle, sensing, backoff and transmit
%%  - If a node has data to transmit and it is in idle state, it switches for
%%    a short moment of time to sensing phase
%%  - If sensing phase passed without sendstart/recvstart, it is switched to
%%    transmit phase, otherwise it switches to backoff
%%  - After backoff timeout it returns to idle
%% 3. Sensing phase is a state, where a node senses the channel  if there are
%%   some activities:
%%   “BUSY” time between:
%%  - “SENDSTART”  and “SENDEND”,
%%  - “RECVSTART” and “RECVEND”
%% 4. If a node sends a package (didn't determined the channel as busy) and the
%%   modem is in “BUSY BACKOFF STATE”,
%%   the mac layer doesn't do anything, just reports the application layer, that
%%   the modem is in backoff state.

-define(TRANS, [
                {idle,
                 [{sendend, idle},
                  {recvend, idle},
                  {transmit, sensing},
                  {sendstart, idle},
                  {recvstart, idle},
                  {backoff_timeout, idle}
                 ]},

                {sensing,
                 [
                  {transmit, sensing},
                  {backoff_timeout, transmit},
                  {backoff, backoff},
                  {sendstart, backoff},
                  {recvstart, backoff}
                 ]},

                {backoff,
                 [{backoff_timeout, transmit},
                  {transmit, backoff},
                  {sendstart, backoff},
                  {recvstart, backoff}
                 ]},

                {transmit,
                 [{data_sent, idle},
                  {transmit, sensing}
                 ]},

                {wait_transmittion,
                 [
                  {sendstart, idle},
                  {recvstart, backoff},
                  {transmit, wait_transmittion}
                 ]},

                {alarm, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  init_backoff(SM),
  env:put(SM, channel_state, idle).
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> eps.
stop(_SM)      -> ok.

%% FIXME: use configuramtion parameter for max backoff

%%--------------------------------------Helper functions------------------------
init_backoff(SM)->
  share:put(SM, backoff_factor, 0). % 2 ^ 0

check_limit(SM, Current_Backoff, Backoff_Factor) ->
  case Current_Backoff of
    Current_Backoff when ((Current_Backoff =< 200) and (Current_Backoff >= 1)) ->
      Backoff_Factor;
    Current_Backoff when (Current_Backoff > 200) ->
      Backoff_Factor - 1;
    Current_Backoff when (Current_Backoff < 1) ->
      init_backoff(SM)
  end.

change_backoff(SM, Type) ->
  Exp = share:get(SM, backoff_factor),
  Backoff_Factor =
    case Type of
      keep -> Exp;
      increment -> Exp + 1;
      decrement -> case ( Exp - 1 > 0 ) of true -> Exp - 1; false -> 0 end
    end,
  Current_Backoff = math:pow(2, Backoff_Factor),
  NewStep = check_limit(SM, Current_Backoff, Backoff_Factor),
  share:put(SM, backoff_factor, NewStep),
  Val = math:pow(2, share:get(SM, backoff_factor)),
  ?TRACE(?ID, "Backoff after ~p : ~p~n", [Type, Val]),
  Val.

process_async({status, Status, Reason}) ->
  case Status of
    'INITIATION' when Reason == 'LISTEN'-> initiation_listen;
    'INITIATION' -> busy_online;
    'ONLINE'-> busy_online;
    'BACKOFF' -> busy_online;
    'BUSY' when Reason == 'BACKOFF' -> busy_backoff;
    'BUSY' -> busy
  end;
process_async({sendstart, _, _, _, _}) -> sendstart;
process_async({sendend, _, _, _, _}) -> sendend;
process_async({recvstart}) -> recvstart;
process_async({recvend, _, _, _, _}) -> recvend;
process_async(_) -> eps.

run_hook_handler(MM, SM, {sync, Cmd, _} = Term, Event) ->
  Handle_cache =
    fun(LSM, nothing) -> LSM;
       (LSM, Next) ->
        [
         share:put(__, cached_command, nothing),
         fsm:send_at_command(__, Next)
        ] (LSM)
    end,
  Handle_cast =
    fun(LSM) when Cmd == "*SENDIM" ->
        LSM;
       (LSM) ->
        fsm:cast(LSM, at_impl, {send, Term})
    end,
  [
   Handle_cast(__),
   fsm:clear_timeout(__, answer_timeout),
   Handle_cache(__, share:get(SM, cached_command)),
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ] (SM);
run_hook_handler(MM, SM, Term, Event) ->
  [
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ] (SM).

handle_specific_command(MM, SM, "Z", "1") ->
  [
   fsm:clear_timeouts(__),
   run_hook_handler(MM, __, nothing, idle)
  ] (SM);
handle_specific_command(_, SM, _, _) -> SM.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT  ~150p~n~150p~n", [MM, SM]),
  ?TRACE(?ID, "~p~n", [Term]),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, at_impl, {send, {async, {error, <<"ANSWER TIMEOUT">>}}});
    {timeout, Event} ->
      run_hook_handler(MM, SM, Term, Event);
    {allowed} ->
      Conf_pid = share:get(SM, {pid, MM}),
      fsm:broadcast(SM, at_impl, {ctrl, {pid, Conf_pid}}),
      share:put(SM, pid, Conf_pid),
      env:put(SM, connection, allowed);
    {denied} ->
      share:put(SM, pid, nothing),
      if Answer_timeout ->
          fsm:cast(SM, at_impl,  {send, {async, {error, "DISCONNECTED"}}});
         true ->
          SM
      end,
      env:put(SM, connection, denied);
    {connected} when MM#mm.role == at_impl ->
      case share:get(SM, pid) of
        nothing -> SM;
        Conf_pid ->
          fsm:cast(SM, at_impl, {ctrl, {pid, Conf_pid}})
      end;
    {at, Cmd, Param} ->
      Handle_cache =
        fun(LSM,blocked) ->
            case share:get(LSM, cached_command) of
              nothing -> share:put(LSM, cached_command, Term);
              _ -> fsm:cast(LSM, at_impl,  {send, {async, {error, "SEQUENCE_ERROR"}}})
            end;
           (LSM, ok) -> LSM
        end,
      [
       handle_specific_command(MM, __, Cmd, Param),
       fsm:maybe_send_at_command(__, Term, Handle_cache)
      ] (SM);
    {at,{pid,P},"*SENDIM",Dst,noack,Bin} ->
      case env:get(SM, connection) of
        allowed ->
          Hdr = <<0:5,(?FLAG2NUM(data)):3>>, %% TODO: move to mac_hf?
          Tx = {at,{pid,P},"*SENDIM",Dst,noack,<<Hdr/binary,Bin/binary>>},
          share:put(SM, tx, Tx),
          fsm:cast(SM, at_impl,  {send, {sync, "*SENDIM", "OK"}}),
          run_hook_handler(MM, SM, Term, transmit);

        _ ->
          fsm:cast(SM, at_impl,  {send, {sync, "*SENDIM", {error, "DISCONNECTED"}}})
      end;
    {at,{pid,_},Cmd,_,_} ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {at,{pid,_},Cmd,_,_,_} ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {sync, _Req, _Answer} ->
      run_hook_handler(MM, SM, Term, eps);
    {async, {pid, Pid}, {recvim, Len, P1, P2, P3, P4, P5, P6, P7, Bin} = Tuple} ->
      ?TRACE(?ID, "MAC_AT_RECV ~p~n", [Tuple]),
      [_, Flag_code, Data, HLen] = mac_hf:extract_payload_mac_flag(Bin),
      Flag = mac_hf:num2flag(Flag_code, mac),
      Extracted = {recvim, Len - HLen, P1, P2, P3, P4, P5, P6, P7, Data},
      case Flag of
        data ->
          fsm:cast(SM, at_impl, {send, {async, {pid, Pid}, Extracted}});
        _ -> ?ERROR(?ID, "Unsupported flag: ~p~n", [Flag]), SM
      end;
    {async, _, _} ->
      fsm:cast(SM, at_impl, {send, Term});
    {async, Tuple} ->
      fsm:cast(SM, at_impl, {send, Term}),
      NSM =
        case process_async(Tuple) of
          E when E == sendstart; E == recvstart; E == busy_backoff ->
            [
             fsm:set_event(__, E),
             env:put(__, channel_state, busy)
            ] (SM);
          E when E == sendend; E == recvend ->
            env:put(SM, channel_state, idle);
          _ ->
            SM
        end,
      run_hook_handler(MM, NSM, Term, SM#sm.event);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _) ->
  fsm:set_event(SM, eps).

handle_sensing(_MM, #sm{env = #{channel_state := busy}} = SM, _) ->
  init_backoff(SM),
  fsm:set_event(SM, backoff);
handle_sensing(_MM, #sm{env = #{channel_state := idle}} = SM, _) ->
  init_backoff(SM),
  [
   fsm:set_event(__, eps),
   fsm:maybe_set_timeout(__, {ms, rand:uniform(50)}, backoff_timeout)
  ] (SM).

handle_backoff(_MM, #sm{event = backoff} = SM, _) ->
  Backoff = change_backoff(SM, increment),
  %% Slot time to be function of packet duration?
  Timeout = rand:uniform(round(2000 * Backoff)),
  io:format("Set timeout ~p~n", [Timeout]),
  [
   fsm:clear_timeout(__, backoff_timeout),
   fsm:set_timeout(__, {ms, Timeout}, backoff_timeout),
   fsm:set_event(__, eps)
  ] (SM);
handle_backoff(_MM, SM, _) ->
  fsm:set_event(SM, eps).

handle_transmit(_MM, SM, _) ->
  case share:get(SM, tx) of
    nothing ->
      fsm:set_event(SM, data_sent);
    TX ->
      ?TRACE(?ID, "MAC_AT_SEND ~p~n", [TX]),
      Transmittion_handler =
        fun(LSM, blocked) ->
            fsm:set_event(LSM, transmit); %% to trigger second attempt
           (LSM, ok) ->
            share:clean(LSM, tx),
            fsm:set_event(LSM, data_sent)
        end,
      fsm:maybe_send_at_command(SM, TX, Transmittion_handler)
  end.

handle_wait_transmittion(_MM, SM, _) ->
  fsm:set_event(SM, eps).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).
