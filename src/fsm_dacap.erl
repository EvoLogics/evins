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
-module(fsm_dacap).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_backoff/3, handle_final/3]).
-export([handle_wcts/3, handle_ws_data/3, handle_scts/3, handle_wdata/3]).

%% B. Peleato, M. Stojanovic, Distance Aware Collision Avoidance Protocol for Ad Hoc Underwater
%% Acoustic Sensor Networks, IEEE Comm. Letters., 11 (12), pp. 1025-1027, 2007.
%% and https://telecom.dei.unipd.it/media/download/313/
%%
%% Distance-Aware Collision Avoidance Protocol (DACAP) is a non-synchronized handshake-based
%% access scheme that aims at minimizing the average handshake duration by allowing
%% a node to use different handshake lengths for different receivers.
%%
%% Upon receiving a request-to-send (RTS), a node (receiver) immediately replies with a clear-to-send
%% (CTS), then waits for the data packet.
%% If, after sending the CTS, it overhears a packet threatening its pending reception, the receiver sends
%% a very short warning packet to its partner (the node to whom it had sent the CTS).
%% Upon receiving a CTS, a node (sender) waits some time before transmitting the data packet.
%% If it overhears a packet meant for some other node or receives a warning from its partner, the node defers
%% its transmission.
%% The length of the idle period will depend upon the distance between the nodes U, which the sender can learn
%% by measuring the RTS/CTS round-trip time 2U/c.
%% The waiting period is chosen such as to guarantee absence of harmful collisions.
%% To achieve a trade-off that maximizes the throughput of a given network, a minimum hand-shake length tmin
%% is predefined for all the nodes.
%% For a network in which most links are close to the transmission range, tmin needs to be nearly 2T, twice
%% the maximum propagation delay
%% Two versions of the protocol have been designed: with acknowledgments sent right after receiving the data
%% packet, and without acknowledgments.
%% implemented without acknowledgments
%% The receiver only sends a warning if it overhears an RTS within 2T − tmin seconds after sending a CTS,
%% and the sender only defers the transmission if it receives a warning from its partner, or
%% overhears a CTS within the next tmin seconds after sending an RTS.
%%
%%  Abbreviation:
%%  rts   - request to send
%%  cts   - clear to send
%%  wcts  - wait cts
%%  ws_data   - wait send data

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {wcts_end, idle},
                  {send_rts, wcts},
                  {rcv_data, idle},
                  {rcv_warn, backoff},
                  {backoff_end, idle},
                  {rcv_rts_fm, scts},
                  {rcv_cts_fm, idle},
                  {rcv_rts_nfm, backoff},
                  {rcv_cts_nfm, backoff}
                 ]},

                {wcts,
                 [{send_rts, wcts},  % test!!!!
                  {rcv_cts_fm, ws_data},
                  {rcv_rts_nfm, backoff},
                  {rcv_cts_nfm, backoff},
                  {rcv_rts_fm, scts},
                  {rcv_data, idle},
                  {error, idle},
                  {rcv_warn, idle},
                  {wcts_end, backoff}
                 ]},

                {ws_data,
                 [{data_sent, idle},
                  {error, idle},
                  {rcv_warn, idle},
                  {rcv_data, idle},
                  {send_data, ws_data},
                  {rcv_rts_nfm, ws_data},
                  {rcv_cts_nfm, backoff}
                 ]},

                {scts,
                 [{error, idle},
                  {backoff_end, idle}, % test!!!!
                  {rcv_rts_fm, scts},
                  {rcv_cts_fm, scts},
                  {wcts_end, scts},
                  {cts_sent, wdata},
                  {req_clock, scts}
                 ]},

                {wdata,
                 [{error, idle},
                  {send_warn, backoff},
                  {send_cts, scts},
                  {rcv_data, idle},
                  {rcv_warn, wdata},
                  {rcv_rts_fm, scts},
                  {rcv_rts_nfm, wdata},
                  {rcv_cts_nfm, wdata},
                  {no_data, idle}
                 ]},

                {backoff,
                 [{rcv_rts_fm, scts},
                  {wcts_end, backoff},
                  {rcv_rts_nfm, backoff},
                  {rcv_cts_nfm, backoff},
                  {rcv_cts_fm, backoff},
                  {rcv_warn, idle},
                  {rcv_data, idle},
                  {no_data, idle},
                  {backoff_end, idle}
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
  case Term of
    {timeout, {send_rts, IDst, Msg}} when State =:= wcts ->
      fsm:run_event(MM, SM#sm{event = send_rts}, {send_rts, IDst, Msg});
    {timeout, {send_rts, _, _}} -> SM;
    {timeout, wcts_end} ->
      fsm:run_event(MM, SM#sm{event = wcts_end}, wcts_end);
    {timeout, send_data} when State =:= ws_data->
      fsm:run_event(MM, SM#sm{event = send_data}, send_data);
    {timeout, send_data} -> SM;
    {timeout, send_warn} when State =:= backoff ->
      fsm:run_event(MM, SM#sm{state = backoff}, send_warn);
    {timeout, send_warn} -> SM;
    {timeout, req_clock} when State =:= scts ->
      fsm:run_event(MM, SM#sm{event = req_clock}, req_clock);
    {timeout, req_clock} -> SM;
    {timeout, tmo_send_warn} ->
      SM;
    {timeout, tmo_defer_trans} -> SM;
    {timeout, answer_timeout} ->
      ?ERROR(?ID, "~s: Modem not answered with sync message more than:~p~n", [?MODULE, ?ANSWER_TIMEOUT]),
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
    {rcv_ul, T = {at, _PID, _, IDst, _, _}} when State =:= idle ->
      share:put(SM, rts_cts_time_total, {0, 0}),
      if IDst =:= 255 ->
        fsm:send_at_command(SM, T);
      true ->
        share:put(SM, current_pkg, T),
        fsm:run_event(MM, SM#sm{event = send_rts}, {send_rts, IDst, T})
      end;
    {rcv_ul, _} ->
      fsm:cast(SM, alh,  {send, {sync, "OK"} }),
      SM;
    {async, PID, Tuple} ->
      %% recv, recvim
      [SM1, Param] = process_rcv_flag(SM, PID, Tuple),
      fsm:run_event(MM, SM1, Param);
    {async, Tuple} ->
      fsm:cast(SM, alh, {send, {async, Tuple} }),
      process_tmstmp(SM, Tuple);
    {sync, Req, Answer} ->
      SMAT = fsm:clear_timeout(SM, answer_timeout),
      fsm:cast(SMAT, alh, {send, {sync, Answer} }),
      [Param_Term, SM1] = nl_mac_hf:event_params(SMAT, Term, rcv_rts_fm),
      [SM2, Param] = process_sync(SM1, Req, Answer, Param_Term),
      fsm:run_event(MM, SM2, Param);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

init_mac(SM) ->
  share:put(SM, rts_cts_time_total, {0, 0}),
  share:put(SM, cts_rts_time_total, {0, 0}),
  rand:seed(erlang:timestamp()).

handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case E=SM#sm.event of
    internal ->
      init_mac(SM), SM#sm{event = eps};
    _ when E =:= rcv_rts_fm; E =:= rcv_data ->
      fsm:clear_timeout(SM#sm{event = eps}, backoff_end);
    _ ->
      SM#sm{event = eps}
  end.

handle_wcts(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    {send_rts, IDst, Msg} when Answer_timeout =:= true->
      fsm:set_timeout(SM, {ms, 50}, {send_rts, IDst, Msg});
    {send_rts, IDst, Msg} ->
      SM1 = nl_mac_hf:send_helpers(SM, at, Msg, rts),
      Tmin = get_distance(SM, IDst) / share:get(SM, sound_speed),
      SM2 = fsm:set_timeout(SM1, {s, Tmin}, tmo_defer_trans),
      RTT = get_current_rtt(SM2, IDst),
      share:put(SM2, time_srts, erlang:timestamp()),
      fsm:set_timeout(SM1#sm{event = eps}, {s, RTT}, wcts_end);
    {rcv_cts_fm, RTmo, Src} ->
      SM#sm{event = rcv_cts_fm, event_params = {rcv_cts_fm, RTmo, Src}};
    _ -> SM#sm{event = eps}
  end.

handle_scts(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 =
  case SM#sm.event of
    rcv_rts_fm -> fsm:clear_timeout(SM, backoff_end);
    _ -> SM
  end,
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    req_clock when Answer_timeout =:= true ->
      fsm:set_timeout(SM1, {ms, 50}, req_clock);
    req_clock ->
      fsm:send_at_command(SM1, {at, "?CLOCK", ""});
    {rcv_rts_fm, error, _} ->
      SM1#sm{event = error};
    {rcv_rts_fm, SM2, STuple}->
      share:put(SM2, wait_data, STuple),
      C = share:get(SM2, sound_speed),
      Dst_addr = nl_mac_hf:get_dst_addr(STuple),
      U =
      case Val = share:get(SM2, u, Dst_addr) of
       nothing -> share:get(SM2, u);
       _ -> Val
      end,
      fsm:set_timeout(SM2#sm{event = cts_sent}, {s, 2 * U / C}, no_data);
    _ -> SM1#sm{event = eps}
  end.

handle_ws_data(_MM, SMP, Term) ->
  [Param_Term, SM] = nl_mac_hf:event_params(SMP, Term, rcv_cts_fm),
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 = fsm:clear_timeout(SM, wcts_end),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Param_Term of
    {rcv_cts_fm, RTmo, Src} ->
      update_wcts(SM1, RTmo, Src),
      Wcts_time = calc_wcts(SM, Src),
      fsm:set_timeout(SM1#sm{event = eps}, {s, Wcts_time}, send_data);
    send_data when Answer_timeout =:= true->
      % if answer_timeout exists, it means, that channel is busy
      % try to send data once more in 50 ms
      fsm:set_timeout(SM1#sm{event = eps}, {ms, 50}, send_data);
    send_data ->
      Current_pkg = share:get(SM, current_pkg),
      SM2 = nl_mac_hf:send_mac(SM1, at, data, Current_pkg),
      share:clean(SM2, current_pkg),
      SM2#sm{event = data_sent};
    {rcv_warn} ->
      fsm:clear_timeout(SM1#sm{event = rcv_warn}, send_data);
    _ -> SM1#sm{event = eps}
  end.

handle_backoff(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    send_warn when Answer_timeout =:= true->
      fsm:set_timeout(SM#sm{event = eps}, {ms, 50}, send_warn);
    send_warn ->
      Tmo_backoff = nl_mac_hf:rand_float(SM, tmo_backoff),
      STuple = share:get(SM, wait_data),
      SM1 = nl_mac_hf:send_helpers(SM, at, STuple, warn),
      SM2 = fsm:set_timeout(SM1, {ms, Tmo_backoff}, backoff_end),
      SM2#sm{event = send_warn};
    wcts_end ->
      Tmo_backoff = nl_mac_hf:rand_float(SM, tmo_backoff),
      fsm:set_timeout(SM#sm{event = eps}, {ms, Tmo_backoff}, backoff_end);
    _ -> SM#sm{event = eps}
  end.

handle_wdata(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%-----------------------------process helper functions ------------------------
get_distance(SM, IDst) ->
  share:get(SM, u, IDst, share:get(SM, u)).

calc_wcts(SM, IDst) ->
  C = share:get(SM, sound_speed),
  U = get_distance(SM, IDst),
  T = U / C,    % propagation delay
  T_min = T,    % min handshake length, in s
  % min distance to an interferring node for which correct
  Delta_d = T / 4 * C,
  %% reception is still possible in m
  %% when some links are shorter it can be reduced, in s

  % duration of the data packet to be transmitted, in s
  T_data = share:get(SM, t_data),
  T1 = (T_min - lists:min([Delta_d / C , T_data,  2 * T - T_min])) / 2,
  Tw =
  if U / C < T1 -> T_min - 2 * U / C;
     true -> 2 * (U + Delta_d) / C - T_min
  end,
  %% Tw > 2 * Delta_d / C, restriction satisfied, described in article
  Tw.

update_wcts(SM, RTmo, IDst) ->
  C = share:get(SM, sound_speed),
  LA = share:get(SM,local_address),
  case share:get(SM, rts_cts_time_total) of
    {0, 0} -> nothing;
    {T1, T2} ->
      Tot = T2 - T1,
      RTT = nl_mac_hf:convert_t((Tot - RTmo), {us, s}),
      T = RTT / 2,
      U = T * C,
      ?TRACE(?ID, "T1 ~p T2 ~p Tot ~p RTmo ~p RTT ~p T ~p ~n", [T1, T2, Tot, RTmo, RTT, T]),
      ?TRACE(?ID, "Distance between ~p and ~p is U = ~p ~n", [LA, IDst, U]),
      share:put(SM, u, IDst, U),
      Delta_d = T/4 * C,
      CTot = nl_mac_hf:convert_t(Tot, {us, s}),
      share:put(SM, rtt, IDst, CTot + 2 * Delta_d / C)
  end.

get_current_rtt(SM, IDst) ->
  C = share:get(SM, sound_speed),
  case RTT = share:get(SM, rtt, IDst) of
    nothing ->
      2 * share:get(SM, u) / C;
    _ -> RTT
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
    T={recvims, _, _, _, _, _, _, _, _, _} ->
      process_recv(SM, T);
    _ -> [SM, nothing]
  end.

process_recv(SM, T) ->
  {_, Len, Src, Dst, P1, P2, P3, P4, P5, Payl} = T,
  process_recv_helper(SM, Len, Src, Dst, P1, P2, P3, P4, P5, Payl).

process_recv_helper(SM, Len, Src, 255, P1, P2, P3, P4, P5, Payl) ->
  [SM, {raw, {Len, Src, 255, P1, P2, P3, P4, P5, Payl}}];
process_recv_helper(SM, Len, Src, Dst, P1, P2, P3, P4, P5, Payl) ->
  [BFlag, Data, LenAdd] = nl_mac_hf:extract_payload_mac_flag(Payl),
  Flag = nl_mac_hf:num2flag(BFlag, mac),
  ShortTuple = {Len - LenAdd, Src, Dst, P1, P2, P3, P4, P5, Data},
  process_recv_helper(SM, Flag, ShortTuple, Dst).

process_recv_helper(SM, Flag, ShortTuple, Dst) ->
  Local_addr = share:get(SM, local_address),
  case Flag of
    rts when Dst =:= Local_addr ->
      [SM, {rts_fm, ShortTuple}];
    cts when Dst =:= Local_addr ->
      [SM, {cts_fm, ShortTuple}];
    rts  ->
      [SM, {rts_nfm, ShortTuple}];
    cts  ->
      [SM, {cts_nfm, ShortTuple}];
    warn ->
      [SM, {warn, ShortTuple}];
    data ->
      [SM, {data, ShortTuple}]
  end.

process_sync(SM1, Req, Answer, {rcv_rts_fm, STuple}) when Req =:= "?CLOCK" ->
  Timestemp2 = list_to_integer(Answer),
  Cts_rts_time_total = share:get(SM1, cts_rts_time_total),
  case Cts_rts_time_total of
    {Timestemp1, 0} ->
      TDiff  = Timestemp2 - Timestemp1,
      SM2 = nl_mac_hf:send_cts(SM1, at, STuple, Timestemp2, 1000000, TDiff),
      {at, _, _, IDst, _, _} = STuple,
      C = share:get(SM2, sound_speed),
      U = get_distance(SM2, IDst),
      T = U/C,
      Tmin = T,
      SM3 = fsm:set_timeout(SM2, {s, 2 * T - Tmin}, tmo_send_warn),
      share:get(SM3, cts_rts_time_total, {Timestemp1, Timestemp2}),
      SM4 = SM3#sm{event = rcv_rts_fm},
      [SM4, {rcv_rts_fm, SM2, STuple}];
    _ ->
      share:get(SM1, cts_rts_time_total, {0, 0}),
      [SM1, {}]
  end;
process_sync(SM1, _, _, _)  ->
  [SM1, {}].

process_rcv_flag(SM, PID, Tuple) ->
   State = SM#sm.state,
  T = {async, PID, Tuple},
  [H |_] = tuple_to_list(Tuple),
  BPid=
  case PID of
    {pid, NPid} -> <<"p", (integer_to_binary(NPid))/binary>>
  end,
  [SMN, {Flag, RTuple}] = parse_ll_msg(SM, T),
  {_, Src, _, TFlag, _, _, _, _, Data} = RTuple,
  case Tuple of
    {recvim, _, _, _, _, _, _, _, _, _} ->
      RcvPid = [BPid | tuple_to_list(RTuple) ],
      fsm:cast(SMN, alh, {send, {async, list_to_tuple([H | RcvPid] )} });
    {recvims, _, _, _, _, _, _, _, _, _} -> nothing
  end,
  Tmo_defer_trans = fsm:check_timeout(SM, tmo_defer_trans),
  Tmo_send_warn = fsm:check_timeout(SM, tmo_send_warn),
  case Flag of
    raw ->
      [SM, {}];
    data ->
      SM1 = fsm:clear_timeout(SM, no_data),
      SM2 = SM1#sm{event = rcv_data},
      [SM2, {}];
    rts_fm when Tmo_send_warn ->
      SM1 = SM#sm{state = backoff},
      [SM1, send_warn];
    rts_fm ->
      STuple = {at, PID, "*SENDIM", Src, TFlag, Data},
      SM1 = SM#sm{event = rcv_rts_fm, event_params = {rcv_rts_fm, STuple}},
      [SM1, req_clock];
    cts_fm ->
      SM1 = SM#sm{event = rcv_cts_fm},
      [SM1, {rcv_cts_fm, binary_to_integer(Data), Src}];
    rts_nfm ->
      Tmo_backoff = nl_mac_hf:rand_float(SM, tmo_backoff),
      SM1 = fsm:set_timeout(SM, {ms, Tmo_backoff}, backoff_end),
      SM2 = SM1#sm{event = rcv_rts_nfm},
      [SM2, {}];
    cts_nfm when ((State =:= wcts) and Tmo_defer_trans) ->
      [SM, {}];
    cts_nfm ->
      Tmo_backoff = nl_mac_hf:rand_float(SM, tmo_backoff),
      SM1 = fsm:set_timeout(SM, {ms, Tmo_backoff}, backoff_end),
      SM2 = SM1#sm{event = rcv_cts_nfm},
      [SM2, {}];
    warn ->
      SM1 = SM#sm{event = rcv_warn},
      [SM1, {rcv_warn}]
  end.

% process_tmstmp(SM, {sendend, _, _, TmpStmp1, _TDur}) when SM#sm.state =:= wcts ->
%   share:get(SM, rts_cts_time_total, {TmpStmp1, 0}),
%   SM;
% process_tmstmp(SM, {recvend, TmpStmp2, TDur, _, _}) when (SM#sm.state =:= wcts) ->
%   case share:get(SM, rts_cts_time_total) of
%     {TmpStmp1, 0} ->
%       share:put(SM, rts_cts_time_total, {TmpStmp1 - TDur, TmpStmp2});
%     _ ->
%       share:put(SM, rts_cts_time_total, {0, 0})
%   end,
%   SM;
% process_tmstmp(SM, {recvend, TmpStmp1, TDur, _, _}) ->
%   share:put(SM, cts_rts_time_total, {TmpStmp1 - TDur, 0}),
%   SM;
% process_tmstmp(SM, _) ->
%   SM.

process_tmstmp(SM, {sendend, _, _, TmpStmp1, TDur}) when SM#sm.state =:= wcts ->
  share:put(SM, rts_cts_time_total, {TmpStmp1 - TDur, 0}),
  SM;
process_tmstmp(SM, {recvend, TmpStmp2, TDur, _, _}) when (SM#sm.state =:= wcts) ->
  case share:get(SM, rts_cts_time_total) of
    {TmpStmp1, 0} ->
      share:put(SM, rts_cts_time_total, {TmpStmp1, TmpStmp2 + TDur});
    _ ->
      share:put(SM, rts_cts_time_total, {0, 0})
  end,
  SM;
process_tmstmp(SM, {recvend, TmpStmp1, TDur, _, _}) ->
  share:put(SM, cts_rts_time_total, {TmpStmp1 - TDur, 0}),
  SM;
process_tmstmp(SM, _) ->
  SM.
