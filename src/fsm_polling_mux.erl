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
-module(fsm_polling_mux).
-behaviour(fsm).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_polling/3, handle_wait_poll_pbm/3, handle_wait_poll_data/3]).
-export([handle_poll_response_pbm/3, handle_poll_response_data/3, handle_send_data/3]).
-export([handle_idle/3, handle_alarm/3, handle_final/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {recv_poll_seq, poll_response_pbm},
                 {recv_poll_data, idle},
                 {recv_poll_pbm, idle},
                 {process_poll_pbm, idle},
                 {send_poll_data, idle},
                 {request_delivered, idle},
                 {poll_next_addr, polling},
                 {retransmit_im, idle}
                 ]},

                {polling,
                 [{poll_next_addr, polling},
                 {send_poll_data, wait_poll_pbm},
                 {send_burst_data, send_data},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {retransmit_im, polling},
                 {recv_poll_data, polling},
                 {recv_poll_pbm, polling},
                 {process_poll_pbm, polling},
                 {request_delivered, polling},
                 {error, idle}
                 ]},

                {send_data,
                [{no_data_to_send, polling},
                {process_poll_pbm, send_data},
                {request_delivered, send_data},
                {send_next_poll_data, send_data},
                {send_data_end, polling},
                {recv_poll_data, send_data},
                {poll_next_addr, polling},
                {retransmit_im, send_data},
                {poll_stop, idle}
                ]},

                {wait_poll_pbm,
                 [{poll_start, polling},
                 {poll_stop, idle},
                 {process_poll_pbm, wait_poll_pbm},
                 {recv_poll_pbm, wait_poll_data},
                 {recv_poll_data, wait_poll_pbm},
                 {recv_poll_seq, wait_poll_pbm},
                 {poll_next_addr, polling},
                 {request_delivered, wait_poll_pbm},
                 {retransmit_im, wait_poll_pbm}
                 ]},

                {wait_poll_data,
                 [
                 {poll_start, polling},
                 {poll_stop, idle},
                 {recv_poll_pbm, wait_poll_data},
                 {recv_poll_data, wait_poll_data},
                 {process_poll_pbm, wait_poll_data},
                 {poll_next_addr, polling},
                 {send_poll_data, wait_poll_data},
                 {request_delivered, wait_poll_data},
                 {retransmit_im, wait_poll_data}
                 ]},

                {poll_response_data,
                [{poll_data_completed, idle},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {send_next_poll_data, poll_response_data},
                 {recv_poll_seq, poll_response_pbm},
                 {send_poll_pbm, poll_response_data},
                 {wait_pc, poll_response_data},
                 {send_poll_data, idle},
                 {request_delivered, poll_response_data}
                ]},

                {poll_response_pbm,
                 [{recv_poll_seq, poll_response_pbm},
                 {recv_poll_pbm, poll_response_pbm},
                 {recv_poll_data, poll_response_pbm},
                 {send_poll_pbm, poll_response_data},
                 {send_next_poll_data, poll_response_pbm},
                 {no_poll_data, idle},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {ignore_recv_poll_seq, idle},
                 {send_poll_data, poll_response_pbm},
                 {request_delivered, poll_response_pbm}
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
  ?INFO(?ID, ">> HANDLE EVENT ~p ~p Term:~p~n", [SM#sm.state, SM#sm.event, Term]),
  %% ?TRACE(?ID, "~p~n", [Term]),
  SeqPollAddrs = share:get(SM, polling_seq),
  Local_address = share:get(SM, local_address),
  Polling_started = share:get(SM, polling_started),
  Pid = share:get(SM, pid),
  State = SM#sm.state,
  Wait_pc = fsm:check_timeout(SM, wait_pc),
  Send_next_poll_data = fsm:check_timeout(SM, send_next_poll_data_tmo),

  BroadcastData = share:get(SM, broadcast),

  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  Check_state = fsm:check_timeout(SM, check_state),
  Current_poll_addr = get_current_poll_addr(SM),

  Check_state_pbm = share:get(SM, check_state_pbm),

  ?INFO(?ID, ">> SeqPollAddrs=~p Local_address=~p Pid=~p State=~p~n", [SeqPollAddrs, Local_address, Pid, State]),
  ?INFO(?ID, ">> Polling_started=~p Wait_pc=~p Send_next_poll_data=~p BroadcastData=~p~n", [Polling_started, Wait_pc, Send_next_poll_data, BroadcastData]),
  ?INFO(?ID, ">> Answer_timeout=~p Check_state=~p Current_poll_addr=~p Check_state_pbm=~p~n", [Answer_timeout, Check_state, Current_poll_addr, Check_state_pbm]),

  case Term of
    {timeout, answer_timeout} ->
      %% TODO: why?
      TupleResponse = {nl, error, <<"ANSWER TIMEOUT">>},
      fsm:cast(SM, nl_impl, {send, TupleResponse});
    {timeout, wait_rest_poll_data} when Check_state == false,
                                        Answer_timeout == false ->
      fsm:send_at_command(SM, {at, "?S", ""});
    {timeout, wait_rest_poll_data} ->
      Time_wait_recv = share:get(SM, time_wait_recv),
      fsm:set_timeout(SM, {s, Time_wait_recv}, wait_rest_poll_data);
      %SM;
    {timeout, check_state} when Answer_timeout == false ->
      fsm:send_at_command(SM, {at, "?S", ""});
    {timeout, check_state} ->
      fsm:set_timeout(SM, ?ANSWER_TIMEOUT, check_state);
    {timeout, send_next_poll_data_tmo} ->
      SM;
    {timeout, {request_delivered, Term}} ->
      fsm:run_event(MM, SM#sm{event = request_delivered}, Term);
    {timeout, {send_burst, SBurstTuple}} ->
      NEvent_params = add_to_event_params(SM, SBurstTuple),
      SM1 = fsm:clear_timeout(SM, retransmit_pbm),
      fsm:run_event(MM, SM1#sm{event = send_poll_pbm, event_params = NEvent_params}, {});
    {timeout, {retransmit_im, STuple}} ->
      fsm:run_event(MM, SM#sm{event = retransmit_im}, {retransmit_im, STuple});
    {timeout, retransmit_pbm} ->
     fsm:run_event(MM, SM#sm{event = recv_poll_seq}, {});
    {timeout, {retransmit, send_next_poll_data}} ->
      Send_params = find_event_params(SM, send_params),
      fsm:run_event(MM, SM#sm{event = send_next_poll_data}, Send_params);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      SM;
    {allowed} ->
      Conf_pid = share:get(SM, {pid, MM}),
      share:put(SM, pid, Conf_pid);
    {denied} ->
      share:put(SM, pid, nothing);
    {disconnected, _} ->
      SM;
    {nl, get, buffer} ->
      Buffer = get_buffer(SM),
      fsm:cast(SM, nl_impl, {send, {nl, buffer, Buffer}});
    {nl, reset, state} ->
      fsm:cast(SM, nl_impl, {send, {nl, state, ok}}),
      fsm:send_at_command(SM, {at, "Z1", ""}),
      fsm:clear_timeouts(SM#sm{state = idle});
    {nl, get, protocol} ->
      ProtocolName = share:get(SM, nl_protocol),
      fsm:cast(SM, nl_impl, {send, {nl, protocol, ProtocolName}});
    {nl, get, address} ->
      fsm:cast(SM, nl_impl, {send, {nl, address, Local_address}});
    {nl, set, address, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, address, error}});
    {nl, flush, buffer} ->
      [
       clear_buffer(__),
       fsm:clear_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, buffer, ok}})
      ] (SM);
    {nl, send, _MsgType, Local_address, _Payload} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, MsgType, 255, _Payload} when MsgType == tolerant;
                                            MsgType == sensitive ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, broadcast, _IDst, Payload} ->
      TransmitLen = byte_size(Payload),
      if TransmitLen < 50 ->
          [
           add_to_CDT_queue(__, Term),
           fsm:cast(__, nl_impl, {send, {nl, send, 0}})
          ] (SM);
         true ->
          fsm:cast(SM, nl_impl, {send, {nl, send, error}})
      end;
    {nl, send, MsgType, _IDst, _Payload} ->
      case lists:member(MsgType, [sensitive, tolerant, alarm, broadcast]) of
        true ->
          [
           add_to_CDT_queue(__, Term),
           fsm:cast(__, nl_impl, {send, {nl, send, 0}})
          ] (SM);
        false ->
          fsm:cast(SM, nl_impl, {send, {nl, send, error}})
      end;
    {nl, send, _IDst, _Payload} ->
      %% Is it neceessary to add the msg type???
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, set, polling, LSeq} when is_list(LSeq) ->
      LA_Seq = lists:member(Local_address, LSeq),
      if LA_Seq ->
          fsm:cast(SM, nl_impl, {send, {nl, polling, error}});
        true ->
        [
         init_poll_index(__),
         share:put(__, polling_seq, LSeq),
         fsm:cast(__, nl_impl, {send, {nl, polling, LSeq}})
        ] (SM)
      end;
    {nl, get, polling} ->
      LSeq = share:get(SM, nothing, polling_seq, empty),
      fsm:cast(SM, nl_impl, {send, {nl, polling, LSeq}});
    {nl, get, polling, status} ->
      Status =
        case share:get(SM, polling_started) of
          true -> share:get(SM, poll_flag_burst);
          _ -> idle
        end,
      fsm:cast(SM, nl_impl, {send, {nl, polling, status, Status}});
    {nl, start, polling, Flag} when (SeqPollAddrs =/= []) ->
      [
       share:put(__, polling_started, true),
       fsm:clear_timeouts(__),
       share:put(__, poll_flag_burst, Flag),
       fsm:cast(__, nl_impl, {send, {nl, polling, ok}}),
       fsm:set_event(__, poll_start),
       fsm:run_event(MM, __, {})
      ] (SM);
    {nl, start, polling, _Flag} ->
      fsm:cast(SM, nl_impl, {send, {nl, polling, error}});
    {nl, stop, polling} ->
      [
       share:put(__, polling_started, false),
       fsm:clear_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, polling, ok}}),
       fsm:set_event(__, poll_stop),
       fsm:run_event(MM, __, {})
      ] (SM);
    {async, {dropcnt, _Val}} ->
      SM;
    {nl, get, routing} ->
      Answer = {nl, routing, nl_mac_hf:routing_to_list(SM)},
      fsm:cast(SM, nl_impl, {send, Answer});
    {async, {pid, Pid}, RTuple = {recv, _Len, Src, Local_address , _,  _,  _,  _,  _, Data}} ->
      [Type, Poll_data] = extract_poll_data(SM, Data),
      case Poll_data of
        ignore ->
          SM;
        _ when Type == <<"CDB">> ->
          fsm:cast(SM, nl_impl, {send, {nl, recv, Src, Local_address, Poll_data}});
        _  ->
          fsm:cast(SM, nl_impl, {send, {nl, recv, Src, Local_address, Poll_data}}),
          ?TRACE(?ID, "<<<<  Poll_data ~p ~p~n", [Src, Poll_data]),
          fsm:run_event(MM, SM#sm{event = recv_poll_data}, {recv_poll_data, RTuple})
      end;
    {async, {pid, Pid}, RTuple = {recvpbm, _Len, Current_poll_addr, Local_address, _, _, _, _, _Data}} ->
      fsm:run_event(MM, SM#sm{event = process_poll_pbm}, {recv_poll_pbm, RTuple});
    {async, {pid, Pid}, {recvpbm, _Len, Src, _Dst, _, _, _, _, Data}} ->
      try
        [P1, _, P3] = extract_VDT_pbm_msg(SM, Data),
        case P1 of
          <<"B">>  when P3 =/= nothing ->
            fsm:cast(SM, nl_impl, {send, {nl, recv, Src, 255, P3}});
          _ -> SM
        end
      catch error:_ -> SM
      end;
    {async, {pid, Pid}, {recvim, Len, Src, Local_address, Flag, _, _, _,_, Data}} ->
      ?INFO(?ID, "HERE~n", []),
      extract_position(SM, Data),
      RecvTuple = {recv, {Pid, Len, Src, Local_address, Flag, Data}},
      NEvent_params = add_to_event_params(SM, RecvTuple),
      SM1 = SM#sm{event_params = NEvent_params},
      SM2 =
      if Check_state == false ->
        fsm:set_timeout(SM1, ?ANSWER_TIMEOUT, check_state);
      true -> SM1
      end,
      [
        share:put(__, check_state_pbm, true),
        fsm:run_event(MM, __, {})
      ] (SM2);
    {async, {pid, _Pid}, {recvim, _Len, Src, _Dst, _Flag, _, _, _, _, Data}} ->
      % Overhearing broadcast messages
      ?INFO(?ID, "HERE~n", []),
      try
        [MsgType, _BurstExist, Poll_data_len, Poll_data, _, _, _] = extract_CDT_msg(SM, Data),
        case MsgType of
          <<"B">>  when Poll_data_len > 0, Poll_data =/= nothing ->
            fsm:cast(SM, nl_impl, {send, {nl, recv, Src, 255, Poll_data}});
          _ -> SM
        end
      catch error:_ -> SM
      end;
    {async, _PosTerm = {usbllong, _FCurrT, _FMeasT, _Src, _X, _Y, _Z,
                       _E, _N, _U, _Roll, _Pitch, _Yaw, _P, _Rssi, _I, _Acc}} ->
      %% TODO: create NMEA string here
      %% fsm:cast(SM, nmea, {send, PosTerm});
      SM;
    {async, {failed, _PC, _Src}} when State == polling ->
      poll_next_addr(SM),
      fsm:run_event(MM, SM#sm{event = poll_next_addr}, {});
    {async, {failed, _PC, _Src}} ->
      SM;
    {async, {delivered, PC, Src}} ->
      delete_delivered_item(SM, tolerant, PC, Src),
      delete_delivered_item(SM, sensitive, PC, Src),
      if State == polling ->
        fsm:run_event(MM, SM#sm{event = poll_next_addr}, {});
      true ->
        SM
      end;
    {async, {deliveredim, Current_poll_addr}} when State == send_data,
                                     Wait_pc == false,
                                     Polling_started == true ->
      share:put(SM, wait_delivery_im_report, false),
      fsm:run_event(MM, SM#sm{event = request_delivered}, {deliveredim, Current_poll_addr});
    {async, {deliveredim, Current_poll_addr}} ->
      Data_to_recv_name = get_share_var(Current_poll_addr, data_to_recv),
      Data_to_recv = find_event_params(SM, Data_to_recv_name),
      share:put(SM, wait_delivery_im_report, false),
      case Data_to_recv of
        {Data_to_recv_name, {Current_poll_addr, 0}} when Polling_started == true ->
          Check_state = fsm:check_timeout(SM, check_state),
          if Check_state == false ->
            fsm:set_timeout(SM, ?ANSWER_TIMEOUT, check_state);
          true -> SM
          end;
        _ ->
          SM
      end;
    {async, {failedim, Current_poll_addr}} ->
      share:put(SM, wait_delivery_im_report, false),
      fsm:send_at_command(SM, {at, "?S", ""});
    {async, {canceledim, Current_poll_addr}} ->
      share:put(SM, wait_delivery_im_report, false),
      fsm:send_at_command(SM, {at, "?S", ""});
    {async, _Tuple} ->
      SM;
    {sync,"?S", Status} when Check_state_pbm == true ->
      InitiatListen = extract_status(SM, Status),
      SM1 = share:put(SM, check_state_pbm, false),
      SM2 =
      case InitiatListen of
        [true] ->
          fsm:run_event(MM, SM1#sm{event = recv_poll_seq}, {});
        _ when Check_state == false ->
          [
            fsm:set_timeout(__, ?ANSWER_TIMEOUT, check_state),
            share:put(__, check_state_pbm, true)
          ] (SM1);
        _ -> SM1
      end,
      fsm:clear_timeout(SM2, answer_timeout);
    {sync,"?S", Status} ->
      InitiatListen = extract_status(SM, Status),
      SM1 =
      case InitiatListen of
        [true] ->
          SM2 = fsm:clear_timeout(SM, check_state),
          Wait_delivery_im_report = share:get(SM, wait_delivery_im_report),
          case  Polling_started of
            true when Wait_delivery_im_report == false ->
              poll_next_addr(SM),
              fsm:run_event(MM, SM2#sm{state = polling, event = poll_next_addr}, {});
            false when Check_state == false ->
              fsm:set_timeout(SM, ?ANSWER_TIMEOUT, check_state);
            _ -> SM
          end;
        _ when Check_state == false ->
          fsm:set_timeout(SM, ?ANSWER_TIMEOUT, check_state);
        _ -> SM
      end,
      fsm:clear_timeout(SM1, answer_timeout);
    {sync,"?PC", PC} when Wait_pc == true ->
      Send_params = find_event_params(SM, send_params),
      {send_params, {_, ITuple, _}} = Send_params,
      [
       fsm:clear_timeout(__, wait_pc),
       fsm:clear_timeout(__, answer_timeout),
       init_packet_counter(__, PC),
       change_status_item(__, list_to_integer(PC), ITuple),
       fsm:set_event(__, send_next_poll_data),
       fsm:run_event(MM, __, Send_params)
      ] (SM);
    {sync,"?PC", PC} ->
      [
       fsm:clear_timeout(__, answer_timeout),
       init_packet_counter(__, PC)
      ] (SM);
    {sync, "*SENDIM", "OK"} when BroadcastData =/= nothing->
      [
       share:clean(__, broadcast),
       fsm:clear_timeout(__, answer_timeout)
      ] (SM);
    {sync, "*SENDPBM", "OK"} when BroadcastData  =/= nothing ->
      [
       share:clean(__, broadcast),
       fsm:clear_timeout(__, answer_timeout)
      ] (SM);

    {sync,"*SEND",{error, _}} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {sync,"*SEND",{busy, _}} when Check_state == false ->
      [
       fsm:clear_timeout(__, answer_timeout),
       fsm:set_timeout(__, ?ANSWER_TIMEOUT, check_state)
      ] (SM);
    {sync, "*SEND", "OK"} when Send_next_poll_data == true ->
      [
       fsm:clear_timeout(__, send_next_poll_data_tmo),
       nl_mac_hf:clear_spec_timeout(__, send_burst),
       fsm:clear_timeout(__, answer_timeout),
       fsm:send_at_command(__, {at, "?PC", ""}),
       fsm:set_timeout(__, ?ANSWER_TIMEOUT, wait_pc)
      ] (SM);
    {sync, "*SEND", "OK"} ->
      [
       fsm:clear_timeout(__, answer_timeout),
       nl_mac_hf:clear_spec_timeout(__, send_burst),
       fsm:run_event(MM, __, {})
      ] (SM);
    {sync, _Req, _Answer} ->
      fsm:clear_timeout(SM, answer_timeout);
    {nl, error} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    _ when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {nmea, {evossb, _UTC, TID, _DID, _S, _Err, geod, _FS, Lat, Lon, _Z, _Acc, _Pr, _Vel}} ->
      ?INFO(?ID, "Term = ~p, Ref = ~p~n", [Term, share:get(SM, reference_position)]),
      case share:get(SM, reference_position) of
        nothing -> SM;
        {LatRef, LonRef}  ->
          LatD = round(((Lat - LatRef) * 1.0e6)),
          LonD = round(((Lon - LonRef) * 1.0e6)),
          share:put(SM, gps_diff, {erlang:monotonic_time(seconds), TID, LatD, LonD})
      end;
    {nmea, {evoctl, busbl, Settings}} ->
      apply_settings(SM, Settings);
    {nmea, _} ->
      SM;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

apply_settings(SM, reference_position, {Lat, Lon}) when Lat /= nothing, Lon /= nothing ->
  env:put(SM, reference_position, {Lat, Lon});
apply_settings(SM, reference_position, _) ->
  SM.

apply_settings(SM, {Lat, Lon, _, _, _, _, _}) ->
  lists:foldl(fun({Key, Value}, SM_acc) ->
                  apply_settings(SM_acc, Key, Value)
              end, SM, [{reference_position, {Lat, Lon}}]).

handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case SM#sm.event of
    internal ->
      init_poll(SM),
      SM#sm{event = eps};
    _ ->
      SM#sm{event = eps}
  end.

handle_polling(_MM, #sm{event = poll_next_addr} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),

  % TODO: PID ?
  % TODO: multiple burst messages, what msg is the request msg?
  % TODO: remove delivered message

  Current_poll_addr = get_current_poll_addr(SM),
  Poll_flag_burst = share:get(SM, poll_flag_burst),
  BroadcastExistMsg = share:get(SM, broadcast),

  [SendType, STuple] = create_CDT_msg(SM, Poll_flag_burst, BroadcastExistMsg),

  case Answer_timeout of
    true ->
      SM#sm{event = eps};
      %% fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {retransmit_im, STuple});
    false when SendType == burst_exist ->
      ?TRACE(?ID, "handle_polling ~p ~p ~p~n", [Poll_flag_burst, Current_poll_addr, BroadcastExistMsg]),
      share:put(SM, wait_delivery_im_report, true),
      [
       fsm:send_at_command(__, STuple),
       fsm:set_event(__, send_burst_data)
      ] (SM);
    false ->
     ?TRACE(?ID, "handle_polling ~p ~p ~p~n", [Poll_flag_burst, Current_poll_addr, BroadcastExistMsg]),
      Data_to_recv_name = get_share_var(Current_poll_addr, data_to_recv),
      Data_to_recv = {Data_to_recv_name, {Current_poll_addr, 0}},
      NEvent_params = add_to_event_params(SM, Data_to_recv),
      share:put(SM, wait_delivery_im_report, true),
      [
       nl_mac_hf:clear_spec_timeout(__, retransmit_im),
       fsm:send_at_command(__, STuple),
       fsm:set_event(__#sm{event_params = NEvent_params}, send_poll_data)
      ] (SM)
  end;
handle_polling(_MM, #sm{event = no_data_to_send} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  SM#sm{event = poll_next_addr};
handle_polling(_MM, #sm{event = send_data_end} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  SM#sm{event = eps};
handle_polling(_MM, #sm{event = retransmit_im} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  SM#sm{event = poll_next_addr};
handle_polling(_MM, #sm{event = poll_start} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  init_poll_index(SM),
  SM#sm{event = poll_next_addr};
handle_polling(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_wait_poll_pbm(_MM, SM, Term = {recv_poll_pbm, Pbm}) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  % if pbm contains burst data flag, wait till recv_poll_data
  % if not, directly to poll next address
  % or timeout, nothing was received
  Current_poll_addr = get_current_poll_addr(SM),
  {recvpbm, _, Src, Dst, _, _, _, _, Payload} = Pbm,
  ?TRACE(?ID, "handle_wait_poll_pbm Src = ~p Waiting for pbm ~p~n", [Src, Current_poll_addr]),
  case Src of
    Current_poll_addr  ->
      [MsgType, ExtrLen, BroadcastData] = extract_VDT_pbm_msg(SM, Payload),
      ?TRACE(?ID, "<<<<  Extr ~p ~120p~n", [Src, ExtrLen]),
      case BroadcastData of
        <<>> ->
          nothing;
        _ when MsgType == <<"B">> ->
          fsm:cast(SM, nl_impl, {send, {nl, recv, Src, 255, BroadcastData}});
        _ ->
          fsm:cast(SM, nl_impl, {send, {nl, recv, Src, Dst, BroadcastData}})
      end,

      Data_to_recv_name = get_share_var(Src, data_to_recv),
      case ExtrLen of
        0 ->
          Data_to_recv =  {Data_to_recv_name, {Src, ExtrLen}},
          NEvent_params = add_to_event_params(SM, Data_to_recv),
          SM#sm{event = eps, event_params = NEvent_params};
          %poll_next_addr(SM),
          %SM#sm{event = poll_next_addr};
        _ ->
          Time_wait_recv = share:get(SM, time_wait_recv),
          %Poll_params = {poll_data_len, ExtrLen},
          Data_to_recv =  {Data_to_recv_name, {Src, ExtrLen}},
          %NEvent_params_len = add_to_event_params(SM, Data_to_recv),
          NEvent_params = add_to_event_params(SM, Data_to_recv),
          [
           fsm:set_timeout(__, {s, Time_wait_recv}, wait_rest_poll_data),
           fsm:set_event(__#sm{event_params = NEvent_params}, recv_poll_pbm)
          ] (SM)
      end;
    _ ->
      % if no conn to VDT, no pbm, wait till timeout and poll next address
      SM#sm{event = eps}
  end;
handle_wait_poll_pbm(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_wait_poll_data(_MM, SMW, Term = {recv_poll_data, RTuple}) ->
  SM = fsm:clear_timeout(SMW, wait_rest_poll_data),
  ?TRACE(?ID, "~120p~n", [Term]),
  Current_poll_addr = get_current_poll_addr(SM),
  {recv, _, Src, _Dst, _, _, _, _, _, Payload} = RTuple,

  Data_to_recv_name = get_share_var(Src, data_to_recv),
  Data_to_recv = find_event_params(SM, Data_to_recv_name),
  Poll_data_len_whole =
  case Data_to_recv of
    {Data_to_recv_name, {Src, ExtrLen}} -> ExtrLen;
    _ -> 0
  end,

  [_, Poll_data] = extract_poll_data(SM, Payload),
  Poll_data_len = byte_size(Poll_data),
  WaitingRestData = Poll_data_len_whole - Poll_data_len,
  Time_wait_recv = share:get(SM, time_wait_recv),

  case Src of
    Current_poll_addr when WaitingRestData =< 0->
      poll_next_addr(SM),
      SM#sm{state = polling, event = poll_next_addr};
      %fsm:run_event(MM, SM2#sm{state = polling, event = poll_next_addr}, {})
    _ ->
      Waiting_params ={Data_to_recv_name, {Src, WaitingRestData}},
      NEvent_params = add_to_event_params(SM, Waiting_params),
      [
       fsm:set_timeout(__, {s, Time_wait_recv}, wait_rest_poll_data),
       fsm:set_event(__#sm{event_params = NEvent_params}, eps)
      ] (SM)
  end;
handle_wait_poll_data(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_send_data(_MM, #sm{event = send_next_poll_data} = SM, Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Answer_timeout of
    true ->
      NEvent_params = add_to_event_params(SM, Term),
      fsm:set_timeout(SM#sm{event_params = NEvent_params}, ?ANSWER_TIMEOUT, {retransmit, send_next_poll_data} );
    false ->
      {send_params, {STupleLen, {_MsgType, _LocalPC, SBurstTuple}, Tail}} = Term,
      {send, {_, Dst}} = STupleLen,
      SM1 = fsm:send_at_command(SM, SBurstTuple),
      [NTail, NType, LocalPC, NPayload] = create_next_poll_data_response(SM, Tail, <<"CDB">>),
      case NPayload of
        nothing ->
          share:put(SM, send_im_no_burst, true),
          SM1#sm{event = send_data_end};
        _ ->
          Pid = share:get(SM, pid),
          NSBurstTuple = {at, {pid, Pid}, "*SEND", Dst, NPayload},
          NT = {send_params,{STupleLen, {NType, LocalPC, NSBurstTuple}, NTail}},
          NEvent_params = add_to_event_params(SM, NT),
          fsm:set_timeout(SM1#sm{event_params = NEvent_params}, ?ANSWER_TIMEOUT, send_next_poll_data_tmo)
      end
  end;
handle_send_data(_MM, #sm{event = request_delivered} = SM, {deliveredim, Dst} = Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  Local_address = share:get(SM, local_address),
  STupleLen = {send, {Local_address, Dst}},
  [Tail, MsgType, LocalPC, Data] = create_poll_data_response(SM, Dst, <<"CDB">>),
  case Data of
    nothing ->
      SM#sm{event = no_data_to_send};
    _ ->
      case Answer_timeout of
        true ->
          fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {request_delivered, Term});
        false ->
          Pid = share:get(SM, pid),
          SBurstTuple = {at, {pid, Pid}, "*SEND", Dst, Data},
          Tuple = {send_params, {STupleLen, {MsgType, LocalPC, SBurstTuple}, Tail}},
          NEvent_params = add_to_event_params(SM, Tuple),
          [
           fsm:send_at_command(__, {at, "?PC", ""}),
           fsm:set_timeout(__#sm{event_params = NEvent_params}, ?ANSWER_TIMEOUT, wait_pc)
          ] (SM)
      end
  end;
handle_send_data(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_poll_response_data(_MM, #sm{event = send_next_poll_data} = SM, Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Answer_timeout of
    true ->
      NEvent_params = add_to_event_params(SM, Term),
      fsm:set_timeout(SM#sm{event_params = NEvent_params}, ?ANSWER_TIMEOUT, {retransmit, send_next_poll_data} );
    false ->
      {send_params, {RecvTuple, {_MsgType, _LocalPC, SBurstTuple}, Tail}} = Term,
      {recv, {Pid, _Len, Src, _Dst, _Flag, _}} = RecvTuple,
      SM1 = fsm:send_at_command(SM, SBurstTuple),
      [NTail, NType, LocalPC, NPayload] = create_next_poll_data_response(SM, Tail, <<"V">>),
      case NPayload of
        nothing ->
          SM1#sm{event = poll_data_completed};
        _ ->
          NSBurstTuple = {at, {pid, Pid}, "*SEND", Src, NPayload},
          NT = {send_params, {RecvTuple, {NType, LocalPC, NSBurstTuple}, NTail}},
          NEvent_params = add_to_event_params(SM, NT),
          fsm:set_timeout(SM1#sm{event_params = NEvent_params}, ?ANSWER_TIMEOUT, send_next_poll_data_tmo)
      end
  end;
handle_poll_response_data(_MM, #sm{event = send_poll_pbm} = SM, _Term) ->
  Local_address = share:get(SM, local_address),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),

  RecvParams = find_event_params(SM, recv),
  {recv, {Pid, _Len, Src, Dst, _Flag, _}} = RecvParams,

  [Tail, MsgType, LocalPC, Data] = create_poll_data_response(SM, Src, <<"V">>),
  case Data of
    nothing ->
      SM#sm{event = poll_data_completed};
    _ when Local_address == Dst ->
      case Answer_timeout of
        true ->
          fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {send_burst, RecvParams});
        false ->
          SBurstTuple = {at, {pid, Pid}, "*SEND", Src, Data},
          Tuple = {send_params, {RecvParams, {MsgType, LocalPC, SBurstTuple}, Tail}},
          NEvent_params = add_to_event_params(SM, Tuple),
          [
           fsm:send_at_command(__, {at, "?PC", ""}),
           fsm:set_timeout(__#sm{event_params = NEvent_params}, ?ANSWER_TIMEOUT, wait_pc)
          ] (SM)
      end;
      _ ->
        SM#sm{event = poll_data_completed}
  end;
handle_poll_response_data(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_poll_response_pbm(_MM, #sm{event = recv_poll_seq} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  RecvParams = find_event_params(SM, recv),

  case Answer_timeout of
    true ->
      fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, retransmit_pbm);
    false ->
      try
        {recv, {Pid, _Len, Src, Dst, _Flag, DataCDT}} = RecvParams,
        [MsgType, BurstExist, Poll_data_len, Poll_data, _Position, PollingFlagBurst, Process] = extract_CDT_msg(SM, DataCDT),
        case Process of
          ignore ->
            SM#sm{event = ignore_recv_poll_seq};
          answer_pbm when BurstExist == <<"B">> ->
            SM#sm{event = ignore_recv_poll_seq};
          answer_pbm ->
            case Poll_data_len of
              0 -> nothing;
              _ when MsgType == <<"B">> ->
                fsm:cast(SM, nl_impl, {send, {nl, recv, Src, 255, Poll_data}});
              _ ->
                fsm:cast(SM, nl_impl, {send, {nl, recv, Src, Dst, Poll_data}})
            end,

            BroadcastExistMsg = share:get(SM, broadcast),
            Data = create_VDT_pbm_msg(SM, Src, PollingFlagBurst, BroadcastExistMsg),
            SPMTuple = {at, {pid, Pid}, "*SENDPBM", Src, Data},

            SM1 =
            [
            fsm:send_at_command(__, SPMTuple),
            fsm:clear_timeout(__, retransmit_pbm)
            ](SM),

            NEvent_params = add_to_event_params(SM, RecvParams),
            case PollingFlagBurst of
              nb -> SM1#sm{event = ignore_recv_poll_seq};
              b -> SM1#sm{event = send_poll_pbm, event_params = NEvent_params}
            end
        end
      catch error:_ -> SM#sm{event = eps}
      end
  end;
handle_poll_response_pbm(_MM, #sm{event = send_next_poll_data} = SM, _Term) ->
  ?ERROR(?ID, "REPRODUCED~n",[]),
  SM#sm{event = eps};
handle_poll_response_pbm(_MM, SM, _Term) ->
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions------------------------
init_poll(SM)->
  share:put(SM, polling_seq, []),
  share:put(SM, polling_seq_msgs, []),
  share:put(SM, local_pc, 1),
  share:put(SM, polling_pc, 1),
  share:put(SM, recv_packages, []),
  share:put(SM, poll_flag_burst, nb),
  init_poll_index(SM).

add_to_event_params(SM, Tuple) ->
 Event_params = SM#sm.event_params,
 {Name, _} = Tuple,

 case Event_params of
  [] -> [Tuple];
  _ ->
    case find_event_params(SM, Name) of
      new -> [Tuple | Event_params];
      _ ->
        NE =
        lists:filtermap(
        fun(Param) ->
            case Param of
                {Name, _} -> false;
                _ -> {true, Param}
           end
        end, Event_params),
        [Tuple | NE]
    end
  end.

find_event_params(SM, Name) ->
 Event_params = SM#sm.event_params,
 if Event_params == [] ->
    [];
 true ->
    P =
    lists:filtermap(
    fun(Param) ->
        case Param of
            {Name, _} -> {true, Param};
            _ -> false
       end
    end, Event_params),
    if P =/= [] -> [NP] = P, NP;
    true -> new end
 end.

init_packet_counter(SM, PC) ->
  PCI = list_to_integer(PC),
  share:put(SM, packet_counter, PCI).

increase_local_pc(SM, CounterName) ->
  PC = share:get(SM, CounterName),
  if PC > 127 ->
    share:put(SM, CounterName, 1);
  true ->
    share:put(SM, CounterName, PC + 1)
  end.

init_poll_index(SM) ->
  share:put(SM, current_polling_i, 1).

poll_next_addr(SM) ->
  LSeq = share:get(SM, polling_seq),
  Current_polling_i = share:get(SM, current_polling_i),
  Ind =
  if Current_polling_i >= length(LSeq) -> 1;
  true -> Current_polling_i + 1
  end,
  share:put(SM, current_polling_i, Ind),
  get_current_poll_addr(SM).

extract_status(SM, Status) ->
  StatusL = [string:rstr(X, "INITIATION LISTEN") || X <- string:tokens (Status, "\r\n")],
  ?TRACE(?ID, "~p~n", [Status]),
  lists:filtermap(fun(X) ->
                    if X == 0 -> false;
                      true -> {true, true}
                  end end, StatusL).

get_current_poll_addr(SM) ->
  LSeq = share:get(SM, polling_seq),
  ?TRACE(?ID, "LSeq = ~p CurrentPoll Ind ~p~n", [LSeq, share:get(SM, current_polling_i)]),

  case LSeq of
   _  when LSeq == nothing; LSeq == []->
       nothing;
  _ -> Ind = share:get(SM, current_polling_i),
       lists:nth(Ind, LSeq)
  end.

get_buffer(SM) ->
  LSeq = share:get(SM, polling_seq_msgs),
  F = fun(X) ->
    QSens = get_share_var(X, sensitive),
    QTol = get_share_var(X, tolerant),
    Sens = get_list(share:get(SM, QSens), X),
    Tol = get_list(share:get(SM, QTol), X),
    lists:append([Sens, Tol])
  end,
  lists:flatten([ F(X) || X <- LSeq]).

get_list(nothing, _) ->
 [];
get_list(Q, Dst) ->
 L = queue:to_list(Q),
 F = fun(X) ->
    {_, _, XStatus, _, XMsgType, _, Payload} = X,
    %<<Hash:16, _/binary>> = crypto:hash(md5,Payload),
    {Payload, XStatus, Dst, XMsgType}
  end,
  [ F(X) || X <- L].

clear_buffer(SM) ->
  LSeq = share:get(SM, polling_seq_msgs),
  F = fun(X) ->
    QSens = get_share_var(X, sensitive),
    share:put(SM, QSens, queue:new()),
    QTol = get_share_var(X, tolerant),
    share:put(SM, QTol, queue:new()),
    share:clean(SM, broadcast)
  end,
  [ F(X) || X <- LSeq],
  SM.

get_share_var(Dst, Name) ->
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),
  list_to_atom(atom_to_list(Name) ++ atom_to_list(DstA)).

extract_poll_data(_SM, Payload) ->
  try
    {match, [Type, Data]} = re:run(Payload,"^(CDB|V)(.*)", [dotall, {capture, [1, 2], binary}]),
    [Type, Data]
  catch error: _Reason -> ignore
  end.

extract_VDT_pbm_msg(SM, Payload) ->
  ?TRACE(?ID, ">>>> extract_VDT_pbm_msg ~p ~n", [Payload]),
  try
    Max_burst_len = share:get(SM, max_burst_len),
    CMaxBurstLenBits = nl_mac_hf:count_flag_bits(Max_burst_len),

    <<"VPbm", MsgType:8/bitstring, BLenBurst:CMaxBurstLenBits, Rest/bitstring>> = Payload,

    ?TRACE(?ID, ">>>> extract_VDT_pbm_msg MsgType=~p BLenBurst=~p CMaxBurstLenBits=~p Rest=~p~n", [MsgType, BLenBurst, CMaxBurstLenBits, Rest]),

    Data_bin = (bit_size(Payload) rem 8) =/= 0,
    BroadCastData =
    if Data_bin =:= false ->
      Add = bit_size(Rest) rem 8,
      <<_:Add, Data/binary>> = Rest,
      Data;
    true ->
      Rest
    end,
    [MsgType, BLenBurst, BroadCastData]
  catch error: _Reason -> [0, 0, <<>>]
  end.

create_VDT_pbm_msg(SM, Dst, FlagBurst, nothing) ->
  ?TRACE(?ID, ">>>> create_VDT_pbm_msg no broadcast ~p ~p ~n", [Dst, FlagBurst]),
  Max_burst_len = share:get(SM, max_burst_len),
  CMaxBurstLenBits = nl_mac_hf:count_flag_bits(Max_burst_len),
  Len =
  case FlagBurst of
    nb -> 0;
    b -> get_length_all_msgs(SM, Dst)
  end,

  BLenBurst = <<Len:CMaxBurstLenBits>>,

  ?TRACE(?ID, ">>>> create_VDT_pbm_msg Len ~p Maxlen ~p BLenBurst~p ~n", [Len, Max_burst_len, BLenBurst]),

  TmpData = <<"VPbm", "N", BLenBurst/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"VPbm", "N", BLenBurst/bitstring, 0:Add>>;
  true ->
    TmpData
  end;
create_VDT_pbm_msg(SM, Dst, FlagBurst, BroadcastExistMsg) ->
  ?TRACE(?ID, ">>>> create_VDT_pbm_msg broadcast ~p ~p ~p ~n", [BroadcastExistMsg, Dst, FlagBurst]),
  Max_burst_len = share:get(SM, max_burst_len),
  CMaxBurstLenBits = nl_mac_hf:count_flag_bits(Max_burst_len),

  {Time, broadcast, _Status, TransmitLen, BroadcastPayload} = BroadcastExistMsg,
  NTuple = {Time, broadcast, sent, TransmitLen, BroadcastPayload},
  share:put(SM, broadcast, NTuple),

  Len =
  case FlagBurst of
    nb -> 0;
    b  -> get_length_all_msgs(SM, Dst)
  end,

  BLenBurst = <<Len:CMaxBurstLenBits>>,

  ?TRACE(?ID, ">>>> create_VDT_pbm_msg Len ~p Maxlen ~p BLenBurst~p ~n", [Len, Max_burst_len, BLenBurst]),

  TmpData = <<"VPbm", "B", BLenBurst/bitstring, BroadcastPayload/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"VPbm", "B", BLenBurst/bitstring, 0:Add, BroadcastPayload/binary>>;
  true ->
    TmpData
  end.

create_next_poll_data_response(_SM, LTransmission, Header) ->
  case LTransmission of
    nothing ->
      [nothing, nothing, nothing, nothing];
    [] ->
      [nothing, nothing, nothing, nothing];
    _ ->
      [{Type, LocalPC, _, DataVDT} | Tail] = LTransmission,
      [Tail, Type, LocalPC, <<Header/binary, DataVDT/binary>>]
  end.

create_poll_data_response(SM, Dst, Header) ->
  Res = create_data_queue(SM, Dst),
  Len = get_length_all_msgs(SM, Dst),
  case Len of
    0 ->
      [nothing, nothing, nothing, nothing];
    _ ->
    [{Type, LocalPC, _, DataVDT} | Tail] = Res,
    [Tail, Type, LocalPC, <<Header/binary, DataVDT/binary>>]
  end.

get_length_all_msgs(SM, Dst) ->
  DS = queue_to_data(SM, Dst, sensitive),
  DT = queue_to_data(SM, Dst, tolerant),
  ?TRACE(?ID, ">>>> get_length_all_msgs LenSensitive ~p LenTolerant ~p~n", [byte_size(DS), byte_size(DT)]),
  SumLen = byte_size(DS) + byte_size(DT),
  Max_burst_len = share:get(SM, max_burst_len),
  if(SumLen > Max_burst_len) -> Max_burst_len; true -> SumLen end.

create_data_queue(SM, Dst) ->
  % TODO : we have to implement the limit of the transmission list, parameter
  QNsens = get_share_var(Dst, sensitive),
  QSens = share:get(SM, QNsens),
  QNtol = get_share_var(Dst, tolerant),
  QTol = share:get(SM, QNtol),

  Max_packets_sensitive_transmit = share:get(SM, max_packets_sensitive_transmit),
  Max_packets_tolerant_transmit = share:get(SM, max_packets_tolerant_transmit),

  NL =
  case QTol of
    _ when QTol =/= nothing, QSens =/= nothing ->
      QTolPart = get_part_of_list(Max_packets_tolerant_transmit, QTol),
      QSensPart = get_part_of_list(Max_packets_sensitive_transmit, QSens),
      NQ = queue:join(QSensPart, QTolPart),
      queue:to_list(NQ);
    nothing when QSens =/= nothing ->
      QSensPart = get_part_of_list(Max_packets_sensitive_transmit, QSens),
      queue:to_list(QSensPart);
    _ when QTol =/= nothing, QSens == nothing ->
      QTolPart = get_part_of_list(Max_packets_tolerant_transmit, QTol),
      queue:to_list(QTolPart);
    _ ->
      []
  end,

  lists:foldr(
  fun(X, A) ->
    {_PC, LocalPC, _Status, _Time, Type, _Len, Data} = X,
    [{Type, LocalPC, Dst, Data} | A]
  end, [], NL).

get_part_of_list(Max, Q) ->
  case Max >= queue:len(Q) of
    true -> Q;
    false ->
      {Q1, _Q2} = queue:split(Max, Q),
      Q1
  end.

extract_position(SM, Msg) ->
  try
    CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
    CBitsPosLen = nl_mac_hf:count_flag_bits(63),
    CPollingCounterLen = nl_mac_hf:count_flag_bits(127),
    <<"C", _:8/bitstring, _:8/bitstring, _:CPollingFlagBurst, _:CPollingCounterLen, PLen:CBitsPosLen, RPayload/bitstring>> = Msg,
    <<Pos:PLen/binary, _/bitstring>> = RPayload,
    fsm:cast(SM, nmea, {send, decode_position(share:get(SM, reference_position), Pos)})
  catch _:_ ->
      nothing
  end.

extract_CDT_msg(SM, Msg) ->
  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),

  <<"C", MsgType:8/bitstring, BurstExist:8/bitstring, PollingFlagBurst:CPollingFlagBurst, PC:CPollingCounterLen, PLen:CBitsPosLen, RPayload/bitstring>> = Msg,

  <<Pos:PLen/binary, Rest/bitstring>> = RPayload,
  case decode_position(share:get(SM, reference_position), Pos) of
    Position when is_tuple(Position) ->
      fsm:cast(SM, nmea, {send, Position});
    _ ->
      nothing
  end,      
  Data_bin = (bit_size(Msg) rem 8) =/= 0,
  CDTData =
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    Data;
  true ->
    Rest
  end,

  Recv_packages = share:get(SM, recv_packages),
  PC_exist = lists:member(PC, Recv_packages),
  add_to_limited_list(SM, Recv_packages, PC, recv_packages, 6),

  ?TRACE(?ID, ">>>> extract_CDT_msg PC_exist=~p PollingFlagBurst=~p = MsgType=~p BurstExist=~p LenCTDData=~p CDTData=~p Pos=~p~n",
    [PC_exist, PollingFlagBurst, MsgType, BurstExist, byte_size(CDTData), CDTData, Pos]),

  Res =
  case PollingFlagBurst of
    _ when PC_exist == true ->
      [MsgType, BurstExist, byte_size(CDTData), CDTData, Pos, b, ignore];
    1 -> [MsgType, BurstExist, byte_size(CDTData), CDTData, Pos, nb, answer_pbm];
    0 -> [MsgType, BurstExist, byte_size(CDTData), CDTData, Pos, b, answer_pbm]
  end,
  ?TRACE(?ID, ">>>> extract_CDT_msg ResultTuple ~p~n", [Res]),
  Res.

encode_position(nothing) ->
  <<>>;
encode_position({MTime, TID, LatD, LonD}) ->
  DT = 
    case erlang:monotonic_time(seconds) - MTime of
      T when T < 255 -> T;
      _ -> 255
    end,
  <<TID:8, DT:8, LatD:24/signed, LonD:24/signed>>.

decode_position({LatRef,LonRef}, <<TID:8, _DT:8, LatD:24/signed, LonD:24/signed>>) ->
  Lat = LatD / 1.0e6 + LatRef,
  Lon = LonD / 1.0e6 + LonRef,
  MTime = erlang:system_time(millisecond)/1000,
  {nmea, {evossb, MTime, TID, nothing, ok, nothing, geod, reconstructed, Lat, Lon, nothing, nothing, nothing, nothing}};
decode_position(_, <<>>) ->
  nothing.

create_CDT_msg(SM, nb, nothing) ->
  Current_polling_addr = get_current_poll_addr(SM),
  PollingCounter = share:get(SM, polling_pc),
  DataPos = encode_position(share:get(SM, gps_diff)),
  LenDataPos = byte_size(DataPos),

  PollFlagBurst = 1,

  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),

  BPollFlagBurst = <<PollFlagBurst:CPollingFlagBurst>>,
  BPollingCounter = <<PollingCounter:CPollingCounterLen>>,
  BLenPos = <<LenDataPos:CBitsPosLen>>,

  TmpData = <<"C", "N", "N", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"C", "N", "N", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, 0:Add>>;
  true ->
    TmpData
  end,
  increase_local_pc(SM, polling_pc),
  Pid = share:get(SM, pid),
  ?WARNING(?ID, "CDT: Pid = ~p~n", [Pid]),
  [no_burst, {at, {pid, Pid},"*SENDIM", Current_polling_addr, ack, Data}];
create_CDT_msg(SM, b, nothing) ->
  % TODO: DATA? Fused Position + CDT ?
  % Burst fomt CDT? or dummy with POS?
  % Set max pos len

  Send_im_no_burst = share:get(SM, send_im_no_burst),
  Current_polling_addr = get_current_poll_addr(SM),

  DS = queue_to_data(SM, Current_polling_addr, sensitive),
  DT = queue_to_data(SM, Current_polling_addr, tolerant),

  PollingCounter = share:get(SM, polling_pc),
  DataPos = encode_position(share:get(SM, gps_diff)),
  LenDataPos = byte_size(DataPos),
  DataCDT = list_to_binary([DS, DT]),

  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),

  PollFlagBurst = 0,

  BPollFlagBurst = <<PollFlagBurst:CPollingFlagBurst>>,
  BPollingCounter = <<PollingCounter:CPollingCounterLen>>,
  BLenPos = <<LenDataPos:CBitsPosLen>>,

  LenData = byte_size(DataCDT),

  [FlagBurst, HeaderBurst] =
  case LenData of
    0 -> [no_burst, <<"N">>];
    _ when Send_im_no_burst == true ->
      share:clean(SM, send_im_no_burst),
      [no_burst, <<"N">>];
    _ -> [burst_exist, <<"B">>]
  end,

  TmpData = <<"C", "N", HeaderBurst:8/bitstring, BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary>>,

  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"C", "N", HeaderBurst:8/bitstring, BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, 0:Add>>;
  true ->
    TmpData
  end,
  increase_local_pc(SM, polling_pc),
  Pid = share:get(SM, pid),
  ?WARNING(?ID, "CDT: Pid = ~p~n", [Pid]),
  [FlagBurst, {at, {pid, Pid},"*SENDIM", Current_polling_addr, ack, Data}];

create_CDT_msg(SM, FlagBurst, BroadcastExistMsg) ->
  Current_polling_addr = get_current_poll_addr(SM),
  DataPos = encode_position(share:get(SM, gps_diff)),
  LenDataPos = byte_size(DataPos),
  PollingCounter = share:get(SM, polling_pc),

  PollFlagBurst =
  case FlagBurst of
    nb -> 1;
    b -> 0
  end,

  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),

  {_Time, broadcast, _Status, _TransmitLen, BroadcastPayload} = BroadcastExistMsg,

  BPollFlagBurst = <<PollFlagBurst:CPollingFlagBurst>>,
  BLenPos = <<LenDataPos:CBitsPosLen>>,
  BPollingCounter = <<PollingCounter:CPollingCounterLen>>,

  TmpData = <<"C", "B", "N", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, BroadcastPayload/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"C", "B", "N", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, 0:Add, BroadcastPayload/binary>>;
  true ->
    TmpData
  end,

  increase_local_pc(SM, polling_pc),
  Pid = share:get(SM, pid),
  ?WARNING(?ID, "CDT: Pid = ~p~n", [Pid]),
  [no_burst, {at, {pid, Pid},"*SENDIM", Current_polling_addr, ack, Data}].

queue_to_data(SM, Dst, Name) ->
  Qname = get_share_var(Dst, Name),
  Q = share:get(SM, Qname),
  QData =
  case Q of
    nothing -> <<"">>;
    {[],[]} -> <<"">>;
    _ ->
      LData = queue:to_list(Q),
      F = fun(X) -> {_PC, _LocalPC, _Status, _Time, _Type, _Len, Data} = X, Data end,
      list_to_binary(lists:join(<<"">>, [ F(X)  || X <- LData]))
  end,
  ?TRACE(?ID, ">>>> queue_to_data QData ~p~n", [QData]),
  QData.

add_to_limited_list(SM, L, Key, NameQ, Max) ->
  NL =
  case length(L) > Max of
    true -> lists:delete(lists:nth(length(L), L), L);
    false -> L
  end,

  Member = lists:member(Key, L),
  case Member of
    false ->
      share:put(SM, NameQ, [Key | NL]);
    true  ->
      nothing
  end.

add_to_CDT_queue(SM, {nl, send, broadcast, IDst, Payload}) ->
  Polling_seq_msgs = share:get(SM, polling_seq_msgs),
  add_to_limited_list(SM, Polling_seq_msgs, IDst, polling_seq_msgs, 10),
  Time = erlang:monotonic_time(micro_seconds),
  TransmitLen = byte_size(Payload),
  MsgTuple = {Time, broadcast, not_sent, TransmitLen, Payload},
  share:put(SM, broadcast, MsgTuple),
  ?TRACE(?ID, "add_to_CDT_queue ~p~n", [share:get(SM, broadcast)]),
  SM;
add_to_CDT_queue(SM, {nl, send, MsgType, IDst, Payload}) ->
  LocalPC = share:get(SM, local_pc),
  increase_local_pc(SM, local_pc),
  TransmitLen = byte_size(Payload),
  Polling_seq_msgs = share:get(SM, polling_seq_msgs),
  add_to_limited_list(SM, Polling_seq_msgs, IDst, polling_seq_msgs, 10),
  Qname = get_share_var(IDst, MsgType),

  QShare = share:get(SM, Qname),
  Q =
  if QShare == nothing ->
    queue:new();
  true ->
    QShare
  end,
  PC = unknown,
  Status = not_delivered,
  Time = erlang:monotonic_time(micro_seconds),
  Item = {PC, LocalPC, Status, Time, MsgType, TransmitLen, Payload},
  NQ =
  case MsgType of
    tolerant ->
      queue:in(Item, Q);
    sensitive ->
      Max_sensitive_queue = share:get(SM, max_sensitive_queue),
      nl_mac_hf:queue_limited_push(Q, Item, Max_sensitive_queue)
  end,
  share:put(SM, Qname, NQ),
  ?TRACE(?ID, "add_to_CDT_queue ~p~n", [Item]),
  SM.

delete_delivered_item(SM, Name, PC, Dst) ->
  ?TRACE(?ID, "delete_delivered_item Name=~p, PC=~p, Dst=~p~n", [Name, PC, Dst]),
  Qname = get_share_var(Dst, Name),
  QueueItems = share:get(SM, Qname),

  ?TRACE(?ID, "delete_delivered_item before QueueItems=~p~n", [QueueItems]),

  case QueueItems of
    nothing -> nothing;
    _ ->
      QueueItemsList = queue:to_list(QueueItems),

      NL =
      lists:filtermap(fun(X) ->
      case X of
        {PC, _, _, _, _, _, _} -> false;
        _ -> {true, X}
      end end, QueueItemsList),

      NQ = queue:from_list(NL),
      share:put(SM, Qname, NQ)
  end,
  ?TRACE(?ID, "delete_delivered_item after QueueItems=~p~n", [share:get(SM, Qname)]),
  SM.

change_status_item(SM, PC, {MsgType, LocalPC, ATSendTuple}) ->
  ?TRACE(?ID, "change_status_item PC=~p, MsgType=~p, LocalPC=~p, SendTuple=~p~n", [PC, MsgType, LocalPC, ATSendTuple]),
  {at, {pid, _}, "*SEND", Dst, Data} = ATSendTuple,
  Max_sensitive_queue = share:get(SM, max_sensitive_queue),
  Qname = get_share_var(Dst, MsgType),

  QueueItems = share:get(SM, Qname),
  QueueItemsList = queue:to_list(QueueItems),

  [_, Payload] = extract_poll_data(SM, Data),

  NQ =
  lists:foldr(
  fun(X, Q) ->
    {_, XPC, XStatus, XTime, XMsgType, XTransmitLen, XPayload} = X,
    case MsgType of
      tolerant when XMsgType == MsgType, XPC == LocalPC, Payload == XPayload ->
        Item = {PC, XPC, XStatus, XTime, XMsgType, XTransmitLen, Payload},
        queue:in(Item, Q);
      sensitive when XMsgType == MsgType, XPC == LocalPC, Payload == XPayload ->
        Item = {PC, XPC, XStatus, XTime, XMsgType, XTransmitLen, Payload},
        nl_mac_hf:queue_limited_push(Q, Item, Max_sensitive_queue);
      tolerant ->
        queue:in(X, Q);
      sensitive ->
        nl_mac_hf:queue_limited_push(Q, X, Max_sensitive_queue)
    end
  end, queue:new(), QueueItemsList),
  share:put(SM, Qname, NQ),
  SM.
