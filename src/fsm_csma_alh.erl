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
-module(fsm_csma_alh).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_sp/3, handle_write_alh/3, handle_final/3]).

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
%%    to upper layer and sets a backoff timeout (tries to sen later)
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
%%
%%  Abbreviation:
%%  sp - sensing phase
%%  ul - upper layer

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {error, idle},
                  {sendend, idle},
                  {recvend, idle},
                  {backoff_timeout, write_alh},
                  {rcv_ul, write_alh},
                  {sendstart, sp},
                  {recvstart, sp}
                 ]},

                {write_alh,
                 [{data_sent, sp},
                  {internal, idle}
                 ]},

                {sp,
                 [{backoff_timeout, sp},
                  {busy,  sp},
                  {rcv_ul,  sp},
                  {sendstart, sp},
                  {recvstart, sp},
                  {sendend, idle},
                  {recvend, idle},
                  {error, idle}
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
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT  ~150p~n~150p~n", [MM, SM]),
  ?TRACE(?ID, "~p~n", [Term]),
  case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"ANSWER TIMEOUT">>} } }),
      SM;
    {timeout, {retransmit, Msg}} ->
      ?TRACE(?ID, "Retransmit Tuple ~p ~n ", [Msg]),
      [SM1, P] = nl_mac_hf:process_retransmit(SM, Msg, rcv_ul),
      fsm:run_event(MM, SM1, P);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {rcv_ul, {command,<<"Z1,">>}} ->
      fsm:send_at_command(SM, {at, "Z1", ""}),
      fsm:clear_timeouts(SM#sm{state = idle});
    {rcv_ul, {at, _, _, _, _}} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } }),
      SM;
    {rcv_ul, Msg = {at, _PID, _, _, _, _}} ->
      share:put(SM, current_msg, Msg),
      SM1 = nl_mac_hf:process_send_payload(SM, Msg),
      fsm:run_event(MM, SM1#sm{event = rcv_ul}, {rcv_ul, Msg});
      %StoredRetransmit = nl_mac_hf:get_params_spec_timeout(SM1, retransmit),
      %if StoredRetransmit == [] ->
      %    SM1;
      %true ->
      %  fsm:run_event(MM, SM1#sm{event = rcv_ul}, {rcv_ul, Msg});
      %end;
    {async, _, {recvims, _, _, _, _, _, _, _, _, _}} ->
      SM;
    {async, {pid, NPid}, Tuple = {recvim, _, _, _, _, _, _, _, _, _}} ->
      ?TRACE(?ID, "MAC_AT_RECV ~p~n", [Tuple]),
      [H |_] = tuple_to_list(Tuple),
      BPid = <<"p", (integer_to_binary(NPid))/binary>>,

      [SMN, ParsedRecv] = process_recv(SM, Tuple),
      case ParsedRecv of
        {_, _, STuple} ->
          SMsg = list_to_tuple([H | [BPid | tuple_to_list(STuple) ]]),
          fsm:cast(SMN, alh, {send, {async, SMsg} }),
          fsm:run_event(MM, SMN, {});
        _ ->
          SMN
      end;
    {async, Tuple} ->
      fsm:cast(SM, alh, {send, {async, Tuple} }),
      Ev = process_async(SM, Tuple),
      fsm:run_event(MM, SM#sm{event = Ev}, {});
    {sync, _, {error, _}} ->
      fsm:run_event(MM, SM#sm{event = error}, {});
    {sync, _, {busy, _}} ->
      Current_msg = share:get(SM, current_msg),
      fsm:run_event(MM, SM#sm{event = busy}, {rcv_ul, Current_msg});
    {sync, _Req, Answer} ->
      SMAT = fsm:clear_timeout(SM, answer_timeout),
      fsm:cast(SMAT, alh, {send, {sync, Answer} });
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case SM#sm.event of
    internal ->
      init_backoff(SM);
    _ -> nothing
  end,
  SM#sm{event = eps}.

handle_sp(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_sp ~120p~n", [Term]),
  Backoff_timeout = fsm:check_timeout(SM, backoff_timeout),
  case Term of
    {rcv_ul, _Msg} when Backoff_timeout =:= false ->
      Backoff_tmp = change_backoff(SM, increment),
      fsm:set_timeout(SM#sm{event = eps}, {s, Backoff_tmp}, backoff_timeout);
    {rcv_ul, _Msg} when Backoff_timeout =:= true ->
      fsm:cast(SM, alh,  {send, {sync, "OK"} }),
      SM#sm{event = eps};
    _ when SM#sm.event =:= backoff_timeout ->
      Backoff_tmp = change_backoff(SM, increment),
      fsm:set_timeout(SM#sm{event = eps}, {s, Backoff_tmp}, backoff_timeout);
    _ -> SM#sm{event = eps}
  end.

handle_write_alh(_MM, #sm{event = backoff_timeout} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 = fsm:clear_timeout(SM, backoff_timeout),
  change_backoff(SM1, decrement),
  case share:get(SM1, current_msg) of
    nothing ->
      SM1#sm{event = internal};
    Msg ->
     ?TRACE(?ID, "MAC_AT_SEND ~p~n", [Msg]),
     share:clean(SM, current_msg),
     fsm:set_event(nl_mac_hf:send_mac(SM, at, data, Msg), data_sent)
   end;
handle_write_alh(_MM, SM, Term = {rcv_ul, Msg}) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 = fsm:clear_timeout(SM, backoff_timeout),
  change_backoff(SM1, decrement),
  ?TRACE(?ID, "MAC_AT_SEND ~p~n", [Msg]),
  share:clean(SM, current_msg),
  fsm:set_event(nl_mac_hf:send_mac(SM, at, data, Msg), data_sent).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

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

process_recv(SM, T) ->
  ?TRACE(?ID, "MAC_AT_RECVIM ~p~n", [T]),
  {recvim, Len, P1, P2, P3, P4, P5, P6, P7, Payl} = T,
  [BPid, BFlag, Data, LenAdd] = nl_mac_hf:extract_payload_mac_flag(Payl),
  CurrentPid = ?PROTOCOL_MAC_PID(share:get(SM, macp)),
  if CurrentPid == BPid ->
    Flag = nl_mac_hf:num2flag(BFlag, mac),
    ShortTuple = {Len - LenAdd, P1, P2, P3, P4, P5, P6, P7, Data},
    SM1 = nl_mac_hf:process_rcv_payload(SM, Data),
    [SM1, {BPid, Flag, ShortTuple}];
  true ->
    [SM, nothing]
  end.

  %[H | T] = tuple_to_list(Tuple),
  %BPid = <<"p", (integer_to_binary(NPid))/binary>>,
  %fsm:cast(SM1, alh, {send, {async, list_to_tuple([H | [BPid|T]])} }),

process_async(_SM, Tuple) ->
  case Tuple of
    {sendstart, _, _, _, _} ->
      sendstart;
    {sendend, _, _, _, _} ->
      sendend;
    {recvstart} ->
      recvstart;
    {recvend, _, _, _, _} ->
      recvend;
    _ ->
      eps
  end.
