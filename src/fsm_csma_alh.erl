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
-module(fsm_csma_alh).
-behaviour(fsm).

-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_sensing/3, handle_transmit/3]).

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
%% 2. There are 3 states: idle, sensing phase and write
%%  - If a node has data to transmit and it is in idle state, it transmits
%%    and returns to idle state
%%  - If a node has data to transmit and it is in sensing state, it answers "OK"
%%    to upper layer and sets a backoff timeout (tries to send later)
%%  - If a node has data to transmit, it is in sensing state and backoff
%%    timeout left, it increases backoff timeout
%%    and sets the backoff timeout again
%%  - If a node sent data, it decreases the backoff timeout
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
                 [{internal, idle},
                  {error, idle},
                  {sendend, idle},
                  {recvend, idle},
                  {backoff_timeout, transmit},
                  {transmit_data, transmit},
                  {sendstart, sensing},
                  {recvstart, sensing}
                 ]},

                {transmit,
                 [{data_sent, sensing},
                  {still_waiting, idle},
                  {internal, idle}
                 ]},

                {sensing,
                 [{backoff_timeout, sensing},
                  {busy,  sensing},
                  {transmit_data,  sensing},
                  {sendstart, sensing},
                  {recvstart, sensing},
                  {sendend, idle},
                  {recvend, idle},
                  {error, idle}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------------Helper functions------------------------
init_backoff(SM)->
  share:put(SM, current_step, 0). % 2 ^ 0

check_limit(SM, Current_Backoff, Current_Step) ->
  case Current_Backoff of
    Current_Backoff when ((Current_Backoff =< 200) and (Current_Backoff >= 1)) ->
      Current_Step;
    Current_Backoff when (Current_Backoff > 200) ->
      Current_Step - 1;
    Current_Backoff when (Current_Backoff < 1) ->
      init_backoff(SM)
  end.

change_backoff(SM, Type) ->
  Exp = share:get(SM, current_step),
  Current_Step =
  case Type of
    increment -> Exp + 1;
    decrement -> case ( Exp - 1 > 0 ) of true -> Exp - 1; false -> 0 end
  end,
  Current_Backoff = math:pow(2, Current_Step),
  NewStep = check_limit(SM, Current_Backoff, Current_Step),
  share:put(SM, current_step, NewStep),
  Val = math:pow(2, share:get(SM, current_step)),
  ?TRACE(?ID, "Backoff after ~p : ~p~n", [Type, Val]),
  Val.

process_async({sendstart, _, _, _, _}) -> sendstart;
process_async({sendend, _, _, _, _}) -> sendend;
process_async({recvstart, _, _, _, _}) -> recvstart;
process_async({recvend, _, _, _, _}) -> recvend;
process_async(_) -> eps.

listen_detector({sync, "?S", Status}) ->
  case string:str(Status, "INITIATION LISTEN") of
    true -> transmit_data;
    _ -> eps
  end;
listen_detector(_) ->
  eps.

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
    fun(LSM) when Cmd == "?S" ->
        case share:get(LSM, cast_status) of
          true ->
            share:put(LSM, cast_status, false),
            fsm:cast(LSM, at_impl, {send, Term});
          _ -> LSM
        end;
       (LSM) when Cmd == "*SENDIM" ->
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

handle_specific_command(_, SM, "?S", _) -> share:put(SM, cast_status, true);
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
          Hdr = <<0:5,(?FLAG2NUM(data)):3>>, %% TODO: move to nl_mac_hf?
          Tx = {at,{pid,P},"*SENDIM",Dst,noack,<<Hdr/binary,Bin/binary>>},
          share:put(SM, tx, Tx), 
          fsm:cast(SM, at_impl,  {send, {sync, "*SENDIM", "OK"}}),

          %% FIXME: actually sense timeout
          case fsm:check_timeout(SM, backoff_timeout) of
            true ->
              SM;
            _ ->
              %% short sensing phase before transmitting
              fsm:set_timeout(SM, {ms, rand:uniform(50)}, backoff_timeout)
          end;
          %% run_hook_handler(MM, SM1, Tx, transmit_data);
        _ ->
          fsm:cast(SM, at_impl,  {send, {sync, "*SENDIM", {error, "DISCONNECTED"}}})
      end;
    {at,{pid,_},Cmd,_,_} ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {at,{pid,_},Cmd,_,_,_} ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {sync, "?S", Status} ->
      run_hook_handler(MM, SM, Term, listen_detector(Status));
    {sync, _, {error, _}} ->
      run_hook_handler(MM, SM, Term, error);
    {sync, _, {busy, _}} ->
      run_hook_handler(MM, SM, Term, busy);
    {sync, _Req, _Answer} ->
      run_hook_handler(MM, SM, Term, transmit_data);
    {async, {pid, Pid}, {recvim, Len, P1, P2, P3, P4, P5, P6, P7, Bin} = Tuple} ->
      ?TRACE(?ID, "MAC_AT_RECV ~p~n", [Tuple]),
      [_, Flag_code, Data, HLen] = nl_mac_hf:extract_payload_mac_flag(Bin),
      Flag = nl_mac_hf:num2flag(Flag_code, mac),
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
      run_hook_handler(MM, SM, Term, process_async(Tuple));
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _) ->
  case SM#sm.event of
    internal -> init_backoff(SM);
    _ -> nothing
  end,
  fsm:set_event(SM, eps).

handle_sensing(_MM, #sm{event = backoff_timeout} = SM, _) ->
  Backoff_tmp = change_backoff(SM, increment),
  fsm:set_timeout(SM#sm{event = eps}, {s, Backoff_tmp}, backoff_timeout);
handle_sensing(_MM, SM, Term = {at,{pid,_},"*SENDIM",_,_,_}) ->
  Backoff_timeout = fsm:check_timeout(SM, backoff_timeout),
  ?INFO(?ID, "handle_sensing ~120p Backoff_timeout ~p ~n", [Term, Backoff_timeout]),
  case Backoff_timeout of
    true ->
      fsm:set_event(SM, eps);
    false ->
      Backoff_tmp = change_backoff(SM, increment),
      [
       fsm:set_event(__, eps),
       fsm:set_timeout(__, {s, Backoff_tmp}, backoff_timeout)
      ] (SM)
  end;
handle_sensing(_MM, SM, _) ->
  fsm:set_event(SM, eps).

handle_transmit(_MM, SM, _) ->
  case {fsm:check_timeout(SM, backoff_timeout), share:get(SM, tx)} of
    {true, _} ->
      fsm:set_event(SM, still_waiting);
    {_, nothing} ->
      fsm:set_event(SM, internal);      
    {_, TX} ->
      ?TRACE(?ID, "MAC_AT_SEND ~p~n", [TX]),
      Transmittion_handler =
        fun(LSM, blocked) ->
            fsm:set_event(LSM, still_waiting); %% TODO: ask ?S
           (LSM, ok) ->
            change_backoff(LSM, decrement),
            share:clean(LSM, tx),
            fsm:set_event(LSM, data_sent)
        end,
      fsm:maybe_send_at_command(SM, TX, Transmittion_handler)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).
