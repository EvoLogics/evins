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
-export([init/1,handle_event/3,stop/1]).

-export([handle_idle/3, handle_wcts/3, handle_ws_data/3, handle_scts/3, handle_wdata/3, handle_backoff/3, handle_final/3]).

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
%%  rts   - request to sebd
%%  cts   - clear to send
%%  wcts  - wait cts
%%  ws_data   - wait send data

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {send_rts, wcts},
                  {rcv_rts_fm, scts},
                  {rcv_cts_fm, idle},
                  {rcv_data, idle},
                  {rcv_rts_nfm, backoff},
                  {rcv_cts_nfm, backoff}
                 ]},

                {wcts,
                 [{rcv_cts_fm, ws_data},
                  {rcv_rts_nfm, backoff},
                  {rcv_cts_nfm, backoff},
                  {error, idle},
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
                  {rcv_rts_fm, scts},
                  {cts_sent, wdata}
                 ]},

                {wdata,
                 [{error, idle},
                  {send_warn, backoff},
                  {send_cts, scts},
                  {rcv_data, idle},
                  {rcv_rts_fm, scts},
                  {rcv_rts_nfm, wdata},
                  {rcv_cts_nfm, wdata},
                  {no_data, idle}
                 ]},

                {backoff,
                 [{backoff_end, idle},
                  {rcv_rts_fm, scts},
                  {rcv_rts_nfm, backoff},
                  {rcv_cts_nfm, backoff},
                  {rcv_cts_fm, backoff},
                  {rcv_data, idle},
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
    {timeout, Event} ->
      ?INFO(?ID, "timeout ~140p~n", [Event]),
      case Event of
        answer_timeout -> SM;
        wcts_end ->
          fsm:run_event(MM, SM#sm{event=wcts_end}, wcts_end);
        send_data ->
          fsm:run_event(MM, SM#sm{event=send_data}, send_data);
        tmo_send_warn -> SM;
        tmo_defer_trans -> SM;
        _ -> fsm:run_event(MM, SM#sm{event=Event}, {})
      end;
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {rcv_ul, {other, Msg}} ->
      fsm:send_at_command(SM, {at, binary_to_list(Msg), ""});
    {rcv_ul, {command, C}} ->
      fsm:send_at_command(SM, {at, binary_to_list(C), ""});
    {rcv_ul, {at,_,_,_,_}} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } }),
      SM;
    {rcv_ul, T={at,_PID,_,IDst,_,_}} ->
      case State of
        idle -> nl_mac_hf:insertETS(SM, rts_cts_time_total, {0,0}),
                if IDst =:= 255 ->  fsm:cast(SM, at, {send, T});
                   true -> nl_mac_hf:insertETS(SM, current_pkg, T),
                           fsm:run_event(MM, SM#sm{event=send_rts}, {send_rts, IDst, T})
                end;
        _ -> fsm:cast(SM, alh,  {send, {sync, "OK"} }), SM
      end;
    T={async, PID, Tuple} ->
      %% recv, recvim
      [H |_] = tuple_to_list(Tuple),
      BPid=
      case PID of
        {pid, NPid} -> <<"p", (integer_to_binary(NPid))/binary>>
      end,
      [SMN, {Flag, RTuple}] = parse_ll_msg(SM, T),
      {_,Src,_,TFlag,_,_,_,_,Data} = RTuple,
      case Tuple of
        {recvim,_,_,_,_,_,_,_,_,_} ->
          fsm:cast(SMN, alh, {send, {async, list_to_tuple([H | [BPid| tuple_to_list(RTuple) ]] )} });
        {recvims,_,_,_,_,_,_,_,_,_} -> nothing
      end,
      Tmo_defer_trans = fsm:check_timeout(SM, tmo_defer_trans),
      case Flag of
        raw ->  SM;
        data ->
          SM1 = fsm:clear_timeout(SM, no_data),
          fsm:run_event(MM, SM1#sm{event=rcv_data}, {});
        rts_fm when State =:= wdata ->
          SM1 = fsm:send_at_command(SM, {at, "?CLOCK", ""}),
          STuple = {at, PID, "*SENDIM", Src, TFlag, Data},
          nl_mac_hf:send_helpers(SM, at, nl_mac_hf:readETS(SM, wait_data), warn),
          fsm:run_event(MM, SM1#sm{event = rcv_rts_fm, event_params = {rcv_rts_fm, STuple}}, {});
        rts_fm ->
          SM1 = fsm:send_at_command(SM, {at, "?CLOCK", ""}),
          STuple = {at, PID, "*SENDIM", Src, TFlag, Data},
          fsm:run_event(MM, SM1#sm{event = rcv_rts_fm, event_params = {rcv_rts_fm, STuple}}, {});
        cts_fm ->
          fsm:run_event(MM, SM#sm{event=rcv_cts_fm}, {rcv_cts_fm, binary_to_integer(Data), Src});
        rts_nfm ->
          SM1 = fsm:set_timeout(SM, {ms, nl_mac_hf:rand_float(SM, tmo_backoff)}, backoff_end),
          fsm:run_event(MM, SM1#sm{event=rcv_rts_nfm}, {});
        cts_nfm when ((State =:= wcts) and Tmo_defer_trans) ->
          fsm:run_event(MM, SM#sm{event=eps}, {});
        cts_nfm ->
          SM1 = fsm:set_timeout(SM, {ms, nl_mac_hf:rand_float(SM, tmo_backoff)}, backoff_end),
          fsm:run_event(MM, SM1#sm{event=rcv_cts_nfm}, {});
        warn ->
          fsm:run_event(MM, SM#sm{event=rcv_warn}, {rcv_warn})
      end;
    {async, Tuple} ->
      fsm:cast(SM, alh, {send, {async, Tuple} }),
      case Tuple of
        {sendend,_,_,Timestemp1,TDur} when State =:= wcts ->
          nl_mac_hf:insertETS(SM, rts_cts_time_total, {Timestemp1 - TDur, 0}), SM;
        {recvend,Timestemp2,_TDur,_,_}when (State =:= wcts) ->
          case nl_mac_hf:readETS(SM, rts_cts_time_total) of
            {Timestemp1, 0} ->
              nl_mac_hf:insertETS(SM, rts_cts_time_total, {Timestemp1, Timestemp2});
            _ ->
              nl_mac_hf:insertETS(SM, rts_cts_time_total, {0,0})
          end,
          SM;
        {recvend,Timestemp1,TDur,_,_} ->
          nl_mac_hf:insertETS(SM, cts_rts_time_total, {Timestemp1- TDur, 0}), SM;
        _ -> SM
      end;
    {sync, Req, Answer} ->
      fsm:cast(SM, alh, {send, {sync, Answer} }),
      [Param_Term, SM1] = nl_mac_hf:event_params(SM, Term, rcv_rts_fm),
      case Param_Term of
        {rcv_rts_fm, STuple} when Req =:="?CLOCK" ->
          Timestemp2 = list_to_integer(Answer),
          case nl_mac_hf:readETS(SM1, cts_rts_time_total) of
            {Timestemp1, 0} ->
              SM2 = nl_mac_hf:send_cts(SM, at, STuple, Timestemp2, 1000000, Timestemp2 - Timestemp1),
              {at,_,_,IDst,_,_} = STuple,
              C = nl_mac_hf:readETS(SM, sound_speed),
              U = get_distance(SM, IDst),
              T = U/C,
              Tmin = T,
              SM3 = fsm:set_timeout(SM2, {s, 2 * T - Tmin}, tmo_send_warn),
              nl_mac_hf:insertETS(SM3, cts_rts_time_total, {Timestemp1, Timestemp2}),
              fsm:run_event(MM, SM3#sm{event=rcv_rts_fm}, {rcv_rts_fm, SM2, STuple});
            _ ->
              nl_mac_hf:insertETS(SM1, cts_rts_time_total, {0,0}),
              SM1
          end;
        _ ->
          SM1
      end;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

init_mac(SM) ->
  nl_mac_hf:insertETS(SM, rts_cts_time_total, {0,0}),
  nl_mac_hf:insertETS(SM, cts_rts_time_total, {0,0}),
  random:seed(erlang:now()).

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
  case Term of
    {send_rts, IDst, Msg} ->
      SM1 = nl_mac_hf:send_helpers(SM, at, Msg, rts),
      if SM1 =:= error -> SM#sm{event = error};
         true ->
           Tmin = get_distance(SM, IDst) / nl_mac_hf:readETS(SM, sound_speed),
           SM2 = fsm:set_timeout(SM1, {s, Tmin}, tmo_defer_trans),
           RTT = get_current_rtt(SM2, IDst),
           nl_mac_hf:insertETS(SM2, time_srts, erlang:now()),
           fsm:set_timeout(SM1#sm{event = eps}, {s, RTT}, wcts_end) end;
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
  case Term of
    {rcv_rts_fm, SM2, STuple}->
      if SM2 =:= error -> SM1#sm{event = error};
         true ->
           nl_mac_hf:insertETS(SM2, wait_data, STuple),
           C = nl_mac_hf:readETS(SM2, sound_speed),
           U =
           case Val = nl_mac_hf:readETS(SM2, {u, nl_mac_hf:get_dst_addr(STuple)}) of
             not_inside -> nl_mac_hf:readETS(SM2, u);
             _ -> Val
           end,
           fsm:set_timeout(SM2#sm{event = cts_sent}, {s, 2 * U/C}, no_data)
      end;
    _ -> SM1#sm{event = eps}
  end.

handle_ws_data(_MM, SMP, Term) ->
  [Param_Term, SM] = nl_mac_hf:event_params(SMP, Term, rcv_cts_fm),
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 = fsm:clear_timeout(SM, wcts_end),
  case Param_Term of
    {rcv_cts_fm, RTmo, Src} ->
      update_wcts(SM1, RTmo, Src),
      Wcts_time = calc_wcts(SM, Src),
      io:format("Wcts_time ~p ~n", [Wcts_time]),
      fsm:set_timeout(SM1#sm{event = eps}, {s, Wcts_time}, send_data);
    send_data ->
      SM2 = nl_mac_hf:send_mac(SM1, at, data, nl_mac_hf:readETS(SM, current_pkg)),
      nl_mac_hf:cleanETS(SM2, current_pkg),
      if SM2 =:= error -> SM#sm{event = error};
         true -> SM2#sm{event = data_sent}
      end;
    {rcv_warn} ->
      fsm:clear_timeout(SM1#sm{event = rcv_warn}, send_data);
    _ -> SM1#sm{event = eps}
  end.

handle_backoff(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case Term of
    wcts_end ->
      fsm:set_timeout(SM#sm{event = eps}, {ms, nl_mac_hf:rand_float(SM, tmo_backoff)}, backoff_end);
    _ -> SM#sm{event = eps}
  end.

handle_wdata(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  Tmo_send_warn = fsm:check_timeout(SM, tmo_send_warn),
  case SM#sm.event of
    rcv_rts_nfm when Tmo_send_warn =:= true ->
      STuple = nl_mac_hf:readETS(SM, wait_data),
      SM1 = nl_mac_hf:send_helpers(SM, at, STuple, warn),
      if SM1 =:= error -> SM#sm{event = error};
         true ->
           SM2 = fsm:set_timeout(SM1, {ms, nl_mac_hf:rand_float(SM, tmo_backoff)}, backoff_end),
           SM2#sm{event = send_warn}
      end;
    _ -> SM#sm{event = eps}
  end.

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%------------------------------------------ process helper functions -----------------------------------------------------
get_distance(SM, IDst) ->
  case Val = nl_mac_hf:readETS(SM, {u, IDst}) of
    not_inside ->
      nl_mac_hf:readETS(SM, u);% max distance between nodes in the network, in m
    _ ->
      Val
  end.

calc_wcts(SM, IDst) ->
  C = nl_mac_hf:readETS(SM, sound_speed),
  U = get_distance(SM, IDst),
  T = U/C,    % propagation delay
  T_min = T,    % min handshake length, in s
  Delta_d = T/4 * C,  % min distance to an interferring node for which correct
  %% reception is still possible in m
  %% when some links are shorter it can be reduced, in s
  T_data = nl_mac_hf:readETS(SM, t_data), % duration of the data packet to be transmitted, in s
  T1 = (T_min - lists:min([Delta_d/C , T_data,  2 * T - T_min])) / 2,
  Tw =
  if U/C < T1 -> T_min - 2 * U/C;
     true -> 2 * (U + Delta_d) / C - T_min
  end,
  %% Tw > 2 * Delta_d / C, restriction satisfied, described in article
  Tw.

update_wcts(SM, RTmo, IDst) ->
  C = nl_mac_hf:readETS(SM, sound_speed),
  {T1, T2} = nl_mac_hf:readETS(SM, rts_cts_time_total),
  Tot = T2 - T1,
  RTT = nl_mac_hf:convert_t((Tot - RTmo), {us, s}),
  T = RTT / 2,
  U = T * C,
  ?TRACE(?ID, "Distance between ~p and ~p is U = ~p ~n", [nl_mac_hf:readETS(SM,local_address),IDst, U]),
  nl_mac_hf:insertETS(SM, {u, IDst}, U),
  Delta_d = T/4 * C,
  nl_mac_hf:insertETS(SM, {rtt, IDst},  nl_mac_hf:convert_t(Tot, {us, s}) + 2 * Delta_d / C),
  U.

get_current_rtt(SM, IDst) ->
  C = nl_mac_hf:readETS(SM, sound_speed),
  case RTT = nl_mac_hf:readETS(SM, {rtt, IDst}) of
    not_inside ->
      2 * nl_mac_hf:readETS(SM, u) / C;
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
    T={recvim,_,_,_,_,_,_,_,_,_} ->
      process_recv(SM, T);
    T={recvims,_,_,_,_,_,_,_,_,_} ->
      process_recv(SM, T);
    _ -> [SM, nothing]
  end.

process_recv(SM, T) ->
  Local_addr = nl_mac_hf:readETS(SM, local_address),
  {_, Len, Src, Dst, P1, P2, P3, P4, P5, Payl} = T,
  if Dst =:= 255 ->
       [SM, {raw, {Len, Src, Dst, P1, P2, P3, P4, P5, Payl}}];
     true ->
       case re:run(Payl,"([^,]*),(.*)",[dotall,{capture,[1,2],binary}]) of
         {match, [BFlag,Data]} ->
           Flag = nl_mac_hf:num2flag(BFlag, mac),
           ShortTuple = {Len-2, Src, Dst, P1, P2, P3, P4, P5, Data},
           case Flag of
             rts ->
               if Dst =:= Local_addr ->
                    [SM, {rts_fm, ShortTuple}];
                  true ->
                    [SM, {rts_nfm, ShortTuple}]
               end;
             cts ->
               if Dst =:= Local_addr ->
                    [SM, {cts_fm, ShortTuple}];
                  true ->
                    [SM, {cts_nfm, ShortTuple}]
               end;
             warn ->
               [SM, {warn, ShortTuple}];
             data ->
               [SM, {data, ShortTuple}]
           end;
         nomatch -> [SM, nothing]
       end
  end.
