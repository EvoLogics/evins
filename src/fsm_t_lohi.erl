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
-module(fsm_t_lohi).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_blocking_state/3, handle_backoff_state/3, handle_cr/3, handle_transmit_data/3, handle_final/3]).

%%  http://www.eecs.harvard.edu/~mdw/course/cs263/papers/t-lohi-infocom08.pdf
%%  Comparison - http://www.isi.edu/~johnh/PAPERS/Syed08b.pdf
%%
%%  Nodes contend to reserve the channel to send data
%%
%%  Process:
%%  - each frame consists of reservation period (RP), followed by data transfer
%%  - each RP consists of a series of contention rounds (CR)
%%  - if a nodes receives no tones by the end of CR, it wins the contention and ends RP → start sending data
%%  - if multiple nodes compete in CR, each of them will hear the tones of each other and thus will backoff and try again in a later CR
%%  - the CR is long enough to allow nodes to detect (CTD) and count (CTC) contenders
%%  - frame length is provided in the data header → to compute end-of-frame
%%  - backoff_time = one single CR
%%
%%  Abbreviation:
%%  cr  - contention round
%%  rp  - reservation period
%%  ct  - contention tone
%%  ctd - contention detect
%%  ctc - contention counting
%%  Pmax 	  – the worst case one way propagation-time
%%  Tdetect – tone detection time

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {end_of_frame, idle},
                  {rcv_ct, blocking_state},
                  {transmit_ct, cr},
                  {rcv_data, idle},
                  {send_tone, cr}
                 ]},

                {blocking_state,
                 [{end_of_frame, idle},
                  {rcv_ct, blocking_state},
                  {rcv_data, blocking_state},
                  {backoff_end, blocking_state}
                 ]},

                {backoff_state,
                 [{backoff_end, cr},
                  {rcv_ct, blocking_state},
                  {end_of_frame, backoff_state},
                  {rcv_data, backoff_state}
                 ]},

                {cr,
                 [{error, idle},
                  {rcv_data, idle},
                  {send_tone,	cr},
                  {rcv_ct, cr},
                  {dp_ends, cr},
                  {end_of_frame, cr},
                  {no_ct,	transmit_data},
                  {ct_exist, backoff_state}
                 ]},

                {transmit_data,
                 [{transmit_ct, cr},
                  {dp_ends, idle},
                  {end_of_frame, transmit_data},
                  {rcv_ct, transmit_data},
                  {rcv_data, transmit_data},
                  {send_tone, cr}
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
  ?INFO(?ID, "HANDLE EVENT~n", []),
  State = SM#sm.state,
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  ?TRACE(?ID, "State = ~p, Term = ~p~n", [State, Term]),
  case Term of
    {timeout, answer_timeout} -> SM;
    {timeout, {backoff_timeout, Msg}} when State =:= backoff_state ->
      init_ct(SM),
      fsm:run_event(MM, SM#sm{event = backoff_end}, {send_tone, Msg});
    {timeout, {backoff_timeout, _}} -> SM;
    {timeout, {send_tone, Msg}} when Answer_timeout ->
      fsm:set_timeout(SM, {ms, 50}, {send_tone, Msg});
    {timeout, {send_tone, Msg}} ->
      fsm:run_event(MM, SM#sm{event = send_tone}, {send_tone, Msg});
    {timeout, {cr_end, Msg}} ->
      ?TRACE(?ID, "CT ~p~n", [get_ct(SM)]),
      SM1 = fsm:clear_timeout(SM, {send_tone, Msg}),
      SM2 = process_cr(SM1, Msg),
      fsm:run_event(MM, SM2, {});
    {timeout, {retransmit, {not_delivered, Msg}}} when State =:= blocking_state;
                                                       State =:= backoff_state ->
      Tmo_retransmit = nl_mac_hf:readETS(SM, tmo_retransmit),
      fsm:set_timeout(SM, {s, Tmo_retransmit}, {retransmit, {not_delivered, Msg}});
    {timeout, {retransmit, {not_delivered, Msg}}} ->
      ?TRACE(?ID, "Retransmit Tuple ~p ~n ", [Msg]),
      [SM1, P] = nl_mac_hf:process_retransmit(SM, Msg, send_tone),
      nl_mac_hf:insertETS(SM, data_to_sent, {not_delivered, Msg}),
      fsm:run_event(MM, SM1, P);
    {timeout, {retransmit, _Tuple}} ->
      %nothing, the message has delivered state
      SM;
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {rcv_ul, {other, Msg}} ->
      fsm:send_at_command(SM, {at, binary_to_list(Msg), ""});
    {rcv_ul, {command, C}} ->
      fsm:send_at_command(SM, {at, binary_to_list(C), ""});
    {rcv_ul, {at, _, _, _, _}} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } }),
      SM;
    {rcv_ul, Msg={at, _PID, _, _, _, _}} when State =:= idle; State =:= transmit_data ->
      nl_mac_hf:insertETS(SM, data_to_sent, {not_delivered, Msg}),
      nl_mac_hf:insertETS(SM, current_msg, {not_delivered, Msg}),
      SM1 = nl_mac_hf:clear_spec_timeout(SM, retransmit),
      fsm:run_event(MM, SM1#sm{event = transmit_ct}, {send_tone, Msg});
    {rcv_ul, Msg={at, _PID, _, _, _, _}} ->
      nl_mac_hf:insertETS(SM, data_to_sent, {not_delivered, Msg}),
      nl_mac_hf:insertETS(SM, current_msg, {not_delivered, Msg}),
      SM1 = nl_mac_hf:clear_spec_timeout(SM, retransmit),
      fsm:cast(SM1, alh,  {send, {sync, "OK"} }),
      SM;
    {async, _, {recvims, _, _, _, _, _, _, _, _, _}} ->
      SM;
    T =
    {async, {pid, NPid}, Tuple = {recvim, _, _, _, _, _, _, _, _, _}} ->
      [H |_] = tuple_to_list(Tuple),
      BPid = <<"p", (integer_to_binary(NPid))/binary>>,
      [SMN, {Flag, STuple}] = parse_ll_msg(SM, T),
      SMsg = list_to_tuple([H | [BPid | tuple_to_list(STuple) ]]),
      fsm:cast(SMN, alh, {send, {async, SMsg} }),
      SMN1 = process_rcv_flag(SMN, Flag),
      fsm:run_event(MM, SMN1, {});
    {async, Tuple} ->
      CR_Time = nl_mac_hf:readETS(SM, cr_time),
      fsm:cast(SM, alh, {send, {async, Tuple} }),
      SMN = fsm:set_timeout(SM#sm{event = eps}, {ms, CR_Time}, end_of_frame),
      SMN1 = process_ct(SM, SMN, Tuple),
      fsm:run_event(MM, SMN1, {});
    {sync, _Req, Answer} ->
      SMAT = fsm:clear_timeout(SM, answer_timeout),
      fsm:cast(SMAT, alh, {send, {sync, Answer} }),
      SMAT;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

init_mac(SM) ->
  random:seed(erlang:now()),
  nl_mac_hf:insertETS(SM, retransmit_count, 0),
  init_ct(SM).

handle_idle(_MM, SM, _Term) when SM#sm.event =:= internal ->
  init_mac(SM), SM#sm{event = eps};
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  init_ct(SM),
  T = nl_mac_hf:readETS(SM, current_msg),
  if T =:= not_inside -> SM#sm{event = eps};
     true ->
     SM#sm{event = transmit_ct, event_params = {send_tone, T}}
  end.

handle_blocking_state(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_backoff_state(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_cr(_MM, SMP, Term) ->
  [Param_Term, SM] = nl_mac_hf:event_params(SMP, Term, send_tone),
  ?TRACE(?ID, "~120p~n", [Term]),
  case Param_Term of
    {send_tone, {_St, Msg}} ->
      SM1 = nl_mac_hf:send_helpers(SM, at, Msg, tone),
      Cr_time = nl_mac_hf:readETS(SM, cr_time),
      fsm:set_timeout(SM1#sm{event = eps}, {ms, Cr_time}, {cr_end, Msg});
    {send_tone, Msg} ->
      SM1 = nl_mac_hf:send_helpers(SM, at, Msg, tone),
      Cr_time = nl_mac_hf:readETS(SM, cr_time),
      fsm:set_timeout(SM1#sm{event = eps}, {ms, Cr_time}, {cr_end, Msg});
    _ ->
      SM#sm{event = eps}
  end.

handle_transmit_data(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case nl_mac_hf:readETS(SM, data_to_sent) of
    {_St, SendT} ->
      nl_mac_hf:cleanETS(SM, data_to_sent),
      nl_mac_hf:send_mac(SM, at, data, SendT),
      CR_Time = nl_mac_hf:readETS(SM, cr_time),
      R = CR_Time * random:uniform(),
      nl_mac_hf:insertETS(SM, retransmit_count, 0),
      SM1 = fsm:set_timeout(SM#sm{event = eps}, {ms, CR_Time + R}, dp_ends),
      nl_mac_hf:process_send_payload(SM1, SendT);
    _ -> SM#sm{event = eps}
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  init:stop(),
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%------------------------------------------ process helper functions -----------------------------------------------------
init_ct(SM) ->
  nl_mac_hf:insertETS(SM, ctc, 0).
get_ct(SM) ->
  nl_mac_hf:readETS(SM, ctc).
increase_ct(SM) ->
  nl_mac_hf:insertETS(SM, ctc, get_ct(SM) + 1).

process_cr(SM, Msg) ->
  CR_Time = nl_mac_hf:readETS(SM, cr_time),
  Ct = get_ct(SM),
  if Ct =:= 0 ->
    SM#sm{event = no_ct};
  true ->
    R = CR_Time * random:uniform(),
    SM1 = fsm:set_timeout(SM#sm{event = eps}, {ms, 2 * R}, {backoff_timeout, Msg}),
    SM1#sm{event = ct_exist}
  end.

process_ct(SM, SMN, Tuple) ->
  case Tuple of
    {sendstart, _, _, _, _} ->
      SMN#sm{event = rcv_ct};
    {sendend, _, _, _, _} ->
      SM#sm{event = end_of_frame};
    {recvstart} ->
      SMN#sm{event = rcv_ct};
    {recvend, _, _, _, _} ->
      SM#sm{event = end_of_frame};
    _ -> SM
  end.

parse_ll_msg(SM, Tuple) ->
  case Tuple of
    {async, _PID, Msg} ->
      process_async(SM, Msg);
    _ -> [SM, nothing]
  end.

process_async(SM, Msg) ->
  case Msg of
    T={recvim, _, _, _, _, _, _, _, _, _} ->
      process_recv(SM, T);
    _ -> [SM, nothing]
  end.

process_recv(SM, T) ->
  {recvim, Len, P1, P2, P3, P4, P5, P6, P7, Payl} = T,
  case re:run(Payl,"([^,]*),(.*)",[dotall, {capture, [1, 2], binary}]) of
    {match, [BFlag, Data]} ->
      Flag = nl_mac_hf:num2flag(BFlag, mac),
      ShortTuple = {Len - 2, P1, P2, P3, P4, P5, P6, P7, Data},
      Current_msg = nl_mac_hf:readETS(SM, current_msg),
      SM1 = nl_mac_hf:process_rcv_payload(SM, Current_msg, Data),
      [SM1, {Flag, ShortTuple}];
    nomatch -> [SM, nothing]
  end.

process_rcv_flag(SM, Flag) ->
  CR_Time = nl_mac_hf:readETS(SM, cr_time),
  State = SM#sm.state,
  case Flag of
    nothing -> SM;
    tone ->
      % if tone received and got no data
      SM1 = fsm:set_timeout(SM#sm{event = eps}, {ms, 3 * CR_Time}, end_of_frame),
      if State =:= cr -> increase_ct(SM1);
      true -> nothing
      end,
      SM1#sm{event = rcv_ct};
    data when State =:= blocking_state ->
      R = CR_Time * random:uniform(),
      fsm:set_timeout(SM#sm{event = eps}, {ms, CR_Time + R}, end_of_frame);
    data ->
      SM#sm{event = rcv_data}
  end.