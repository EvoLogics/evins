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
%% -compile({parse_transform, pipeline,[{pipeline_verbose, true}]}).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

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
%%  Pmax    – the worst case one way propagation-time
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
                  {rcv_ct, backoff_state}, %???
                  {end_of_frame, backoff_state},
                  {rcv_data, backoff_state}
                 ]},

                {cr,
                 [{error, idle},
                  {rcv_data, idle},
                  {send_tone, cr},
                  {rcv_ct, cr},
                  {end_of_frame, cr},
                  {dp_ends, cr},
                  {no_ct, transmit_data},
                  {ct_exist, backoff_state},
                  {error, idle},
                  {busy, backoff_state}
                 ]},

                {transmit_data,
                 [{transmit_ct, cr},
                  {dp_ends, idle},
                  {end_of_frame, transmit_data},
                  {rcv_ct, transmit_data},
                  {rcv_data, transmit_data},
                  {send_tone, cr},
                  {error, idle},
                  {busy, transmit_data},
                  {busy_handle, transmit_data}
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
    {timeout, answer_timeout} ->
      fsm:cast(SM, at_impl, {send, {sync, "", {error, <<"ANSWER TIMEOUT">>} } }),
      fsm:run_event(MM, SM, {});
    {timeout, {backoff_timeout, Msg}} when State =:= backoff_state ->
      init_ct(SM),
      fsm:run_event(MM, SM#sm{event = backoff_end}, {send_tone, Msg});
    {timeout, {backoff_timeout, _}} -> SM;
    {timeout, {send_tone, Msg}} when Answer_timeout ->
      fsm:set_timeout(SM, {ms, 500}, {send_tone, Msg});
    {timeout, {send_tone, Msg}} ->
      fsm:run_event(MM, SM#sm{event = send_tone}, {send_tone, Msg});
    {timeout, {cr_end, Msg}} when State =:= cr ->
      ?TRACE(?ID, "CT ~p~n", [get_ct(SM)]),
      [
       fsm:clear_timeout(__, {send_tone, Msg}),
       process_cr(__, Msg),
       fsm:run_event(MM, __, {})
      ] (SM);
    {timeout, {cr_end, Msg}} ->
      fsm:clear_timeout(SM, {send_tone, Msg});
    {timeout, {retransmit, Msg}} when State =:= blocking_state;
                                      State =:= backoff_state ->
      share:put(SM, current_msg, Msg),
      Tmo_retransmit = nl_mac_hf:rand_float(SM, tmo_retransmit),
      ?TRACE(?ID, "Tmo_retransmit = ~p~n", [Tmo_retransmit]),
      [
       fsm:clear_timeout(__, dp_ends),
       fsm:set_timeout(__, {ms, Tmo_retransmit}, {retransmit, Msg})
      ] (SM);
    {timeout, {retransmit, Msg}} ->
      ?TRACE(?ID, "Retransmit Tuple ~p ~n ", [Msg]),
      share:put(SM, current_msg, Msg),
      [SMN, P] = nl_mac_hf:process_retransmit(SM, Msg, send_tone),
      [
       fsm:clear_timeout(__, dp_ends),
       fsm:run_event(MM, __, P)
      ] (SMN);
    {timeout, end_of_frame} ->
      ?INFO(?ID, "end_of_frame timeout State = ~p, Term = ~p~n", [State, Term]),
      fsm:run_event(MM, SM#sm{event = end_of_frame}, {});
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {allowed} ->
      Conf_pid = share:get(SM, {pid, MM}),
      share:put(SM, pid, Conf_pid),
      env:put(SM, connection, allowed);
    {denied} ->
      share:put(SM, pid, nothing),
      if Answer_timeout ->
          fsm:cast(SM, at_impl,  {send, {sync, "", {error, "DISCONNECTED"}}});
         true ->
          SM
      end,
      env:put(SM, connection, denied);
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {at, "Z", "1"} ->
      fsm:send_at_command(SM, {send, {at, "Z", "1"}}),
      fsm:clear_timeouts(SM#sm{state = idle});
    {at, Cmd, Param} ->
      fsm:send_at_command(SM, {at, Cmd, Param});
    %% {rcv_ul, {at, _, _, _, _}} ->
    %%   fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } });
    {at,{pid,_},"*SENDIM",_,_,_} when Answer_timeout ->
      fsm:cast(SM, at_impl,  {send, {sync, "", {busy, "SEQUENCE ERROR"}}});
    {at,{pid,_},"*SENDIM",_,_,_} ->
      case env:get(SM, connection) of
        allowed ->
          share:put(SM, current_msg, Term),
          fsm:cast(SM, at,  {send, {at, "?S", ""}});
        _ ->
          fsm:cast(SM, at_impl,  {send, {sync, "", {error, "DISCONNECTED"}}})
      end;
    {sync, "?S", Status} ->
      case string:str(Status, "INITIATION LISTEN") of
        false ->
          [
           fsm:clear_timeout(__, answer_timeout),
           fsm:cast(__, at_impl,  {send, {sync, "", {busy, "BACKOFF"}}})
          ] (SM);
        _ ->
          Msg = share:get(SM, current_msg),
          Conditional_run_event =
            fun(SMM) ->
                if (State == idle) or (State == transmit_data) ->
                    fsm:run_event(MM, SMM#sm{event = transmit_ct}, {send_tone, Msg});
                   true ->
                    SMM
                end
            end,
          [
           fsm:clear_timeout(__, answer_timeout),
           fsm:cast(__, at_impl,  {send, {sync, "", "OK"}}),
           nl_mac_hf:clear_spec_timeout(__, retransmit),
           [__, _] = nl_mac_hf:process_retransmit(__, Msg, eps),
           Conditional_run_event(__)
          ] (SM)
      end;
    {async, {recvims, _, _, _, _, _, _, _, _, _}} ->
      fsm:run_event(MM, SM, {});
    {async, {pid, NPid}, Tuple = {recvim, _, _, _, _, _, _, _, _, _}} ->
      ?TRACE(?ID, "MAC_AT_RECV ~p~n", [Tuple]),
      [H |_] = tuple_to_list(Tuple),
      %% BPid = <<"p", (integer_to_binary(NPid))/binary>>,
      [SMN, ParsedRecv] = parse_ll_msg(SM, Term),
      case ParsedRecv of
        {_BPid, Flag, STuple} ->
          %% SMsg = list_to_tuple([H | [BPid | tuple_to_list(STuple) ]]),
          SMsg = list_to_tuple([H | tuple_to_list(STuple) ]),
          fsm:cast(SMN, at_impl, {send, {async, {pid, NPid}, SMsg} }),
          SMN1 = process_rcv_flag(SMN, Flag),
          fsm:run_event(MM, SMN1, {});
        _ ->
          ?ERROR(?ID, "Error: payload cannot be parsed in: ~p~n", [Term]),
          fsm:cast(SM, at_impl, {send, Term})
      end;
    {async, _, _} ->
      fsm:cast(SM, at_impl, {send, Term});
    {async, Tuple} ->
      [
       fsm:cast(__, at_impl, {send, {async, Tuple} }),
       process_ct(__, Tuple),
       fsm:run_event(MM, __, {})
      ] (SM);
    {sync, "*SENDIM", "OK"} ->
      %% SENDIM report substituded and regenerated by fsm_t_lohi
      [
       fsm:clear_timeout(__, answer_timeout),
       fsm:run_event(MM, __, {})
      ] (SM);
    {sync, _, {error, _}} ->
      [
       fsm:clear_timeout(__, answer_timeout),
       fsm:set_event(__, error),
       fsm:run_event(MM, __, {})
      ] (SM);
    {sync, _, {busy, _}} ->
      Current_msg = share:get(SM, current_msg),
      [
       fsm:clear_timeout(__, answer_timeout),
       fsm:set_event(__, busy),
       fsm:run_event(MM, __, Current_msg)
      ] (SM);
    {sync, _Req, _Answer} ->
      [
       fsm:clear_timeout(__, answer_timeout),
       fsm:cast(__, at_impl, {send, Term})
      ] (SM);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

init_mac(SM) ->
  rand:seed(exsplus, erlang:timestamp()),
  init_ct(SM).

handle_idle(_MM, SM, _Term) when SM#sm.event =:= internal ->
  init_mac(SM),
  SM#sm{event = eps};
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  init_ct(SM),
  SM#sm{event = eps}.

handle_blocking_state(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_backoff_state(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_cr(_MM, SMP, Term) ->
  [Param_Term, SM] = nl_mac_hf:event_params(SMP, Term, send_tone),
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 = fsm:clear_timeout(SM, dp_ends),
  case Param_Term of
    {send_tone, Msg} ->
      SM2 = nl_mac_hf:send_helpers(SM1, at, Msg, tone),
      Cr_time = share:get(SM2, cr_time),
      fsm:set_timeout(SM2#sm{event = eps}, {ms, Cr_time}, {cr_end, Msg});
    _ ->
      SM1#sm{event = eps}
  end.

handle_transmit_data(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case share:get(SM, current_msg) of
    nothing ->
      SM#sm{event = eps};
    _ when SM#sm.event == busy->
      fsm:set_timeout(SM#sm{event = eps}, {ms, 50}, busy_handle);
    SendT ->
      ?TRACE(?ID, "MAC_AT_SEND ~p~n", [SendT]),
      share:clean(SM, current_msg),
      SMS = nl_mac_hf:send_mac(SM, at, data, SendT),
      CR_Time = share:get(SMS, cr_time),
      R = CR_Time * rand:uniform(),
      SM1 = fsm:set_timeout(SMS#sm{event = eps}, {ms, CR_Time + R}, dp_ends),
      nl_mac_hf:process_send_payload(SM1, SendT)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%------------------------------------------ process helper functions -----------------------------------------------------
init_ct(SM) ->
  share:put(SM, ctc, 0).
get_ct(SM) ->
  share:get(SM, ctc).
increase_ct(SM) ->
  share:put(SM, ctc, get_ct(SM) + 1).

process_cr(SM, Msg) ->
  CR_Time = share:get(SM, cr_time),
  Ct = get_ct(SM),
  if Ct =:= 0 ->
    SM#sm{event = no_ct};
  true ->
    R = CR_Time * rand:uniform(),
    %SM1 = fsm:set_timeout(SM#sm{event = eps}, {ms, 2 * R}, {backoff_timeout, Msg}),
    SM1 = fsm:set_timeout(SM#sm{event = eps}, {ms, R}, {backoff_timeout, Msg}),
    SM1#sm{event = ct_exist}
  end.

process_ct(SM, Tuple) ->
  case Tuple of
    {recvstart} ->
      %CR_Time = share:get(SM, cr_time),
      %SM1 = fsm:set_timeout(SM, {ms, CR_Time}, end_of_frame),
      %SM1#sm{event = rcv_ct};
      SM;
    {recvend, _, _, _, _} ->
      SM;
      %SM#sm{event = end_of_frame};
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
    _ ->
      [SM, nothing]
  end.

process_recv(SM, T) ->
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

process_rcv_flag(SM, Flag) ->
  CR_Time = share:get(SM, cr_time),
  State = SM#sm.state,

  case Flag of
    nothing -> SM;
    tone ->
      % if tone received and got no data
      SM1 = fsm:set_timeout(SM#sm{event = eps}, {ms, CR_Time}, end_of_frame),
      ?TRACE(?ID, "+++++++++++++++++++++++++ State ~p ~p tmo end_of_frame ~p ~n", [State, get_ct(SM),  CR_Time]),
      if State =:= cr -> increase_ct(SM1);
      true -> nothing
      end,
      SM1#sm{event = rcv_ct};
    data when State =:= blocking_state ->
      R = CR_Time * rand:uniform(),
      fsm:set_timeout(SM#sm{event = eps}, {ms, CR_Time + R}, end_of_frame);
    data ->
      SM#sm{event = rcv_data}
  end.
