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

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_polling/3, handle_wait_poll_pbm/3, handle_wait_poll_data/3]).
-export([handle_poll_response_pbm/3, handle_poll_response_data/3]).
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

                 {send_poll_data, idle}
                 ]},

                {polling,
                 [{poll_next_addr, polling},
                 {send_poll_data, wait_poll_pbm},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {retransmit_im, polling},

                 {recv_poll_data, polling},
                 {recv_poll_pbm, polling},

                 {error, idle}
                 ]},

                {wait_poll_pbm,
                 [{poll_start, polling},
                 {poll_stop, idle},

                 {process_poll_pbm, wait_poll_pbm},

                 {recv_poll_pbm, wait_poll_data},
                 {recv_poll_data, wait_poll_pbm},

                 {poll_next_addr, polling}
                 ]},

                {wait_poll_data,
                 [
                 {poll_start, polling},
                 {poll_stop, idle},

                 {recv_poll_pbm, wait_poll_data},
                 {recv_poll_data, wait_poll_data},

                 {poll_next_addr, polling},
                 {send_poll_data, wait_poll_data}
                 ]},

                {poll_response_data,
                [{poll_data_completed, idle},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {send_next_poll_data, poll_response_data},
                 {recv_poll_seq, poll_response_data},
                 {send_poll_pbm, poll_response_data},
                 {wait_pc, poll_response_data},
                 {send_poll_data, idle}
                ]},

                {poll_response_pbm,
                 [{recv_poll_seq, poll_response_pbm},

                 {recv_poll_pbm, poll_response_pbm},
                 {recv_poll_data, poll_response_pbm},

                 {send_poll_pbm, poll_response_data},
                 {no_poll_data, idle},

                 {poll_start, polling},
                 {poll_stop, idle},

                 {ignore_recv_poll_seq, idle},
                 {send_poll_data, poll_response_pbm}
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
  %?INFO(?ID, "HANDLE EVENT  ~p   ~p ~n", [MM, SM]),
  ?TRACE(?ID, "~p~n", [Term]),
  SeqPollAddrs = share:get(SM, polling_seq),
  Local_address = share:get(SM, local_address),

  % case Local_address of
  %   2 ->
  %    io:format("!!!!!!!!!!!!! handle_event ~p: ~p ~p ~p~n", [Local_address, Term, SM#sm.event, SM#sm.state]);
  %   1 ->
  %    io:format("!!!!!!!!!!!!! handle_event ~p: ~p ~p ~p~n", [Local_address, Term, SM#sm.event, SM#sm.state]);
  %     _ -> nothing
  % end,

  Wait_pc = fsm:check_timeout(SM, wait_pc),
  Send_next_poll_data = fsm:check_timeout(SM, send_next_poll_data_tmo),
  Event_params = SM#sm.event_params,

  case Term of
    {timeout, answer_timeout} ->
      TupleResponse = {response, {error, <<"ANSWER TIMEOUT">>}},
      fsm:cast(SM, polling_mux, {send, TupleResponse}),
      SM;
    {timeout, wait_recv_pbm} ->
      poll_next_addr(SM),
      fsm:run_event(MM, SM#sm{event = poll_next_addr}, {});
    {timeout, wait_rest_poll_data} ->
      poll_next_addr(SM),
      fsm:run_event(MM, SM#sm{event = poll_next_addr}, {});
    {timeout, send_next_poll_data_tmo} ->
      SM;
    {timeout, {send_burst, SBurstTuple}} ->
      fsm:run_event(MM, SM#sm{event = send_poll_pbm, event_params = SBurstTuple}, {});
    {timeout, {retransmit_im, STuple}} ->
      fsm:run_event(MM, SM#sm{event = retransmit_im}, {retransmit_im, STuple});
    {timeout, {retransmit_pbm, STuple}} ->
      fsm:run_event(MM, SM#sm{event = recv_poll_seq, event_params = STuple}, {});
    {timeout, {retransmit, send_next_poll_data}} ->
      fsm:run_event(MM, SM#sm{event = send_next_poll_data}, Event_params);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {allowed} ->
      ?INFO(?ID, "allowed ~n", []),
      fsm:send_at_command(SM, {at, "?PC", ""}),
      SM;
    {rcv_ul, {get, protocol}} ->
      ProtocolName = share:get(SM, nl_protocol),
      fsm:cast(SM, polling_mux, {send, {response, {nl, protocol, ProtocolName}}}),
      SM;
    {rcv_ul, {flush, buffer}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      clear_buffer(SM),
      fsm:clear_timeouts(SM);
    {rcv_ul, {nl, send, _TransmitLen, Local_address, _MsgType, _Payload}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, error}}}),
      SM;
    {rcv_ul, STuple = {nl, send, _TransmitLen, _IDst, _MsgType, _Payload}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      add_to_CDT_queue(SM, STuple),
      SM;
    {rcv_ul, {nl, send, _TransmitLen, _IDst, _Payload}} ->
      % Is it neceessary to add the msg type???
      fsm:cast(SM, polling_mux, {send, {response, {nl, error}}}),
      SM;
    {rcv_ul, {set, polling_seq, LSeq}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      init_poll_index(SM),
      share:put(SM, polling_seq, LSeq),
      SM;
    {rcv_ul, {set, polling, start, Flag}} when (SeqPollAddrs =/= []) ->
      SM1 = fsm:clear_timeouts(SM),
      share:put(SM, poll_flag_burst, Flag),
      fsm:cast(SM1, polling_mux, {send, {response, {nl, ok}}}),
      fsm:run_event(MM, SM1#sm{event = poll_start}, {});
    {rcv_ul, {set, polling, start, _Flag}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, seq, empty}}}),
      SM;
    {rcv_ul, {set, polling, stop}} ->
      SM1 = fsm:clear_timeouts(SM),
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      fsm:run_event(MM, SM1#sm{event = poll_stop}, {});
    {rcv_ul, {set, neighbours, Flag, NL} } ->
      case Flag of
        normal ->
          share:put(SM, current_neighbours, NL);
        add ->
          Neighbours = [ A || {A, _, _, _} <- NL],
          share:put(SM, current_neighbours, Neighbours)
      end,
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok} } }),
      SM;
    {rcv_ul, {set, routing, Routing} } ->
      share:put(SM, routing_table, Routing),
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok} } }),
      SM;
    {rcv_ul, {get, routing} } ->
      Answer = {nl, routing, nl_mac_hf:routing_to_bin(SM)},
      fsm:cast(SM, polling_mux, {send, {response, Answer}}),
      SM;
    {async, {pid, _Pid}, RTuple = {recv, _Len, Src, Local_address , _,  _,  _,  _,  _, Data}} ->
      Poll_data = extract_poll_data(SM, Data),
      Poll_data_len = byte_size(Poll_data),
      fsm:cast(SM, polling_mux, {send, {response, {nl, recv, Poll_data_len, Local_address, Src, Poll_data}}}),
      io:format("<<<<  Poll_data ~p ~p~n", [Src, Poll_data]),
      fsm:run_event(MM, SM#sm{event = recv_poll_data}, {recv_poll_data, RTuple});
    {async, {pid, _Pid}, RTuple = {recvpbm, _Len, _Src, Local_address, _, _, _, _, _Data}} ->
      fsm:run_event(MM, SM#sm{event = process_poll_pbm}, {recv_poll_pbm, RTuple});
    {async, {pid, Pid}, {recvim, Len, Src, Local_address, Flag, _, _, _,_, Data}} ->
      RecvTuple = {recv, {Pid, Len, Src, Local_address, Flag, Data}},
      fsm:run_event(MM, SM#sm{event = recv_poll_seq, event_params = RecvTuple}, {});
    {async, {pid, _Pid}, {recvim, _Len, _Src, _Dst, _Flag, _, _, _, _, _Data}} ->
      % TODO: ooverhearing
      SM;
    {async, PosTerm = {usbllong, _FCurrT, _FMeasT, _Src, _X, _Y, _Z,
                      _E, _N, _U, _Roll, _Pitch, _Yaw, _P, _Rssi, _I, _Acc}} ->
      fsm:cast(SM, polling_nmea, {send, PosTerm}),
      SM;
    {async, {delivered, PC, Src}} ->
      io:format(">>>>>>>>>>>>> DELIVERED ~p ~p~n", [?ID, PC]),
      delete_delivered_item(SM, tolerant, PC, Src),
      delete_delivered_item(SM, sensitive, PC, Src),
      SM;
    {async, _Tuple} ->
      SM;
    {sync,"?PC", PC} when Wait_pc == true ->
      % TODO: check counter, agter firmware upfate
      SM1 = fsm:clear_timeout(SM, wait_pc),
      SM2 = fsm:clear_timeout(SM1, answer_timeout),
      SM3 = init_packet_counter(SM2, PC),
      {_, ITuple, _} = Event_params,
      change_status_item(SM, list_to_integer(PC), ITuple),
      fsm:run_event(MM, SM3#sm{event = send_next_poll_data}, Event_params);
    {sync,"?PC", PC} ->
      SM1 = fsm:clear_timeout(SM, answer_timeout),
      init_packet_counter(SM1, PC);
    {sync, "*SEND", "OK"} when Send_next_poll_data == true ->
      SM1 = fsm:clear_timeout(SM, send_next_poll_data_tmo),
      SM2 = nl_mac_hf:clear_spec_timeout(SM1, send_burst),
      SM3 = fsm:clear_timeout(SM2, answer_timeout),
      SM4 = fsm:send_at_command(SM3, {at, "?PC", ""}),
      fsm:set_timeout(SM4#sm{event_params = Event_params}, ?ANSWER_TIMEOUT, wait_pc);
    {sync, "*SEND", "OK"} ->
      SM1 = fsm:clear_timeout(SM, answer_timeout),
      SM2 = nl_mac_hf:clear_spec_timeout(SM1, send_burst),
      fsm:run_event(MM, SM2#sm{event = send_poll_data}, {});
    {sync, _Req, _Answer} ->
      SM1 = fsm:clear_timeout(SM, answer_timeout),
      SM1;
    {nl, error} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, error}}});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

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

  Poll_flag_burst = share:get(SM, poll_flag_burst),
  STuple = create_CDT_msg(SM, Poll_flag_burst),
  Current_poll_addr = get_current_poll_addr(SM),

  io:format("handle_polling ======================================> ~p ~p ~n", [Poll_flag_burst, Current_poll_addr]),

  case Answer_timeout of
    true ->
      fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {retransmit_im, STuple});
    false ->
      % TODO: change 20 to be a parameter
      SM1 = fsm:send_at_command(SM, STuple),
      SM2 = fsm:set_timeout(SM1, {s, 20}, wait_recv_pbm),
      SM2#sm{event = send_poll_data}
  end;
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
  % TODO: if pbm contains burst data flag, wait till recv_poll_data
  % if not, directly to poll next address
  % or timeout, nothing was received

  Current_poll_addr = get_current_poll_addr(SM),
  {recvpbm, _, Src, _, _, _, _, _, _} = Pbm,

  case Src of
    Current_poll_addr ->
      ExtrLen = extract_VDT_pbm_msg(SM, Pbm),

      io:format("<<<<  Extr ~p ~120p~n", [Src, ExtrLen]),

      case ExtrLen of
        0 ->
          poll_next_addr(SM),
          SM#sm{event = poll_next_addr};
        _ ->
          SM1 = fsm:set_timeout(SM, {s, 20}, wait_rest_poll_data),
          SM1#sm{event = recv_poll_pbm, event_params = {poll_data_len, ExtrLen}}
      end;
    _ ->
      % TODO: Maybe timetout, if no conn to VDT, no pbm
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

  Event_params = SM#sm.event_params,
  Poll_data_len_whole =
  case Event_params of
    {poll_data_len, ExtrLen} -> ExtrLen;
    _ -> 0
  end,

  Poll_data = extract_poll_data(SM, Payload),
  Poll_data_len = byte_size(Poll_data),
  WaitingRestData = Poll_data_len_whole - Poll_data_len,

  case Src of
    Current_poll_addr when WaitingRestData =< 0->
      poll_next_addr(SM),
      SM#sm{event = poll_next_addr};
    _ ->
      % TODO: set timeout, if data could not be delivered, add a paramer
      SM1 = fsm:set_timeout(SM, {s, 20}, wait_rest_poll_data),
      SM1#sm{event = eps, event_params = {poll_data_len, WaitingRestData}}
  end;
handle_wait_poll_data(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_poll_response_data(_MM, #sm{event = send_next_poll_data} = SM, {}) ->
  SM#sm{event = eps};
handle_poll_response_data(_MM, #sm{event = send_next_poll_data} = SM, Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Answer_timeout of
    true ->
      fsm:set_timeout(SM#sm{event_params = Term}, ?ANSWER_TIMEOUT, {retransmit, send_next_poll_data} );
    false ->
      {Event_params, {_MsgType, _LocalPC, SBurstTuple}, Tail} = Term,
      {recv, {Pid, _Len, Src, _Dst, _Flag, _}} = Event_params,
      SM1 = fsm:send_at_command(SM, SBurstTuple),
      [NTail, NType, LocalPC, NPayload] = create_next_poll_data_response(SM, Tail),

      case NPayload of
        nothing ->
          SM1#sm{event = poll_data_completed};
        _ ->
          NSBurstTuple = {at, {pid, Pid}, "*SEND", Src, NPayload},
          NT = {Event_params, {NType, LocalPC, NSBurstTuple}, NTail},
          fsm:set_timeout(SM1#sm{event_params = NT}, ?ANSWER_TIMEOUT, send_next_poll_data_tmo)
      end
  end;

handle_poll_response_data(_MM, #sm{event = send_poll_pbm} = SM, _Term) ->
  Local_address = share:get(SM, local_address),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  Event_params = SM#sm.event_params,
  % TODO: processed data!

  {recv, {Pid, _Len, Src, Dst, _Flag, _}} = Event_params,

  [Tail, MsgType, LocalPC, Data] = create_poll_data_response(SM, Src),
  case Data of
    nothing ->
      SM#sm{event = poll_data_completed};
    _ when Local_address == Dst ->
      case Answer_timeout of
        true ->
          fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {send_burst, Event_params});
        false ->
          SM1 = fsm:send_at_command(SM, {at, "?PC", ""}),

          SBurstTuple = {at, {pid, Pid}, "*SEND", Src, Data},
          Tuple = {Event_params, {MsgType, LocalPC, SBurstTuple}, Tail},
          fsm:set_timeout(SM1#sm{event_params = Tuple}, ?ANSWER_TIMEOUT, wait_pc)
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
  Event_params = SM#sm.event_params,

  case Answer_timeout of
    true ->
      fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {retransmit_pbm, Event_params} );
    false ->
      {recv, {Pid, _Len, Src, Dst, _Flag, DataCDT}} = Event_params,
      [Poll_data_len, Poll_data, Position, PollingFlagBurst, Process] = extract_CDT_msg(SM, DataCDT),
      case Process of
        ignore ->
          SM#sm{event = ignore_recv_poll_seq};
        answer_pbm ->
          if Poll_data_len > 0 ->
            fsm:cast(SM, polling_mux, {send, {response, {nl, recv, Poll_data_len, Src, Dst, Poll_data}}});
          true -> nothing
          end,
          fsm:cast(SM, polling_nmea, {send, Position}),

          Data = create_VDT_pbm_msg(SM, Src, PollingFlagBurst),
          SPMTuple = {at, {pid, Pid}, "*SENDPBM", Src, Data},
          SM1 = fsm:send_at_command(SM, SPMTuple),

          if PollingFlagBurst == nb ->
            SM1#sm{event = ignore_recv_poll_seq};
          true ->
            SM1#sm{event = send_poll_pbm, event_params = Event_params}
          end
      end
  end;
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

get_current_poll_addr(SM) ->
  LSeq = share:get(SM, polling_seq),
  Ind = share:get(SM, current_polling_i),
  lists:nth(Ind, LSeq).

clear_buffer(SM) ->
  LSeq = share:get(SM, polling_seq_msgs),
  F = fun(X) ->
    DstA = binary_to_atom(integer_to_binary(X), utf8),
    QSens = list_to_atom(atom_to_list(sensitive) ++ atom_to_list(DstA)),
    share:put(SM, QSens, queue:new()),
    QTol = list_to_atom(atom_to_list(tolerant) ++ atom_to_list(DstA)),
    share:put(SM, QTol, queue:new())
  end,
  [ F(X) || X <- LSeq].

extract_poll_data(_SM, Payload) ->
  try
    <<"V", DataVDT/binary>> = Payload,
    DataVDT
  catch error: _Reason -> ignore
  end.

extract_VDT_pbm_msg(SM, Pbm) ->
  try
    Local_address = share:get(SM, local_address),
    {recvpbm, _Len, _Dst, Local_address, _, _Rssi, _Int, _, Payload} = Pbm,
    <<"VPbm", BLenBurst/binary>> = Payload,
    binary:decode_unsigned(BLenBurst, big)
  catch error: _Reason -> 0 %!!! ignore
  end.

create_VDT_pbm_msg(_SM, _Dst, nb) ->
  BLenBurst = binary:encode_unsigned(0, big),
  <<"VPbm", BLenBurst/binary>>;
create_VDT_pbm_msg(SM, Dst, b) ->
  %Local_address = share:get(SM, local_address),
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),

  DS = queue_to_data(SM, DstA, sensitive),
  DT = queue_to_data(SM, DstA, tolerant),
  Len = byte_size(DS) + byte_size(DT),
  BLenBurst = binary:encode_unsigned(Len, big),
  <<"VPbm", BLenBurst/binary>>.

create_next_poll_data_response(_SM, LTransmission) ->
  case LTransmission of
    nothing ->
      [nothing, nothing, nothing, nothing];
    [] ->
      [nothing, nothing, nothing, nothing];
    _ ->
      [{Type, LocalPC, _, DataVDT} | Tail] = LTransmission,
      [Tail, Type, LocalPC, <<"V", DataVDT/binary>>]
  end.

create_poll_data_response(SM, Dst) ->
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),

  Res = create_data_queue(SM, Dst),
  DS = queue_to_data(SM, DstA, sensitive),
  DT = queue_to_data(SM, DstA, tolerant),
  Len = byte_size(DS) + byte_size(DT),
  case Len of
    0 ->
      [nothing, nothing, nothing, nothing];
    _ ->
    [{Type, LocalPC, _, DataVDT} | Tail] = Res,
    [Tail, Type, LocalPC, <<"V", DataVDT/binary>>]
  end.

create_data_queue(SM, Dst) ->
  % TODO : we have to implement the limit of the transmission list, parameter
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),
  QNsens = list_to_atom(atom_to_list(sensitive) ++ atom_to_list(DstA)),
  QSens = share:get(SM, QNsens),
  QNtol = list_to_atom(atom_to_list(tolerant) ++ atom_to_list(DstA)),
  QTol = share:get(SM, QNtol),

  NL =
  case QTol of
    _ when QTol =/= nothing, QSens =/= nothing ->
      NQ = queue:join(QSens, QTol),
      queue:to_list(NQ);
    nothing when QSens =/= nothing ->
      queue:to_list(QSens);
    _ when QTol =/= nothing, QSens == nothing ->
      queue:to_list(QTol);
    _ ->
      []
  end,

  lists:foldr(
  fun(X, A) ->
    {_PC, LocalPC, _Status, _Time, Type, _Len, Data} = X,
    [{Type, LocalPC, Dst, Data} | A]
  end, [], NL).


extract_CDT_msg(SM, Msg) ->
  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),

  <<"C", PollingFlagBurst:CPollingFlagBurst, PC:CPollingCounterLen, PLen:CBitsPosLen, RPayload/bitstring>> = Msg,
  <<Pos:PLen/binary, Rest/bitstring>> = RPayload,
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
  ResAdd = add_to_limited_list(SM, Recv_packages, PC, recv_packages, 10),
  case ResAdd of
    nothing  ->
      [nothing, nothing, nothing, nothing, ignore];
    _ when  PollingFlagBurst == 1 ->
      [byte_size(CDTData), CDTData, Pos, nb, answer_pbm];
    _ when  PollingFlagBurst == 0 ->
      [byte_size(CDTData), CDTData, Pos, b, answer_pbm]
  end.

create_CDT_msg(SM, nb) ->
  Current_polling_addr = get_current_poll_addr(SM),
  PollingCounter = share:get(SM, polling_pc),
  DataPos = <<"POS....">>,
  LenDataPos = byte_size(DataPos),
  PollFlagBurst = 1,

  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),

  BPollFlagBurst = <<PollFlagBurst:CPollingFlagBurst>>,
  BPollingCounter = <<PollingCounter:CPollingCounterLen>>,
  BLenPos = <<LenDataPos:CBitsPosLen>>,
  TmpData = <<"C", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"C", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, 0:Add>>;
  true ->
    TmpData
  end,
  increase_local_pc(SM, polling_pc),
  {at, {pid, 0},"*SENDIM", Current_polling_addr, ack, Data};
create_CDT_msg(SM, b) ->
  % TODO: DATA? Fused Position + CDT ?
  % Burst fomt CDT? or dummy with POS?
  Current_polling_addr = get_current_poll_addr(SM),
  Dst = binary_to_atom(integer_to_binary(Current_polling_addr), utf8),

  DS = queue_to_data(SM, Dst, sensitive),
  DT = queue_to_data(SM, Dst, tolerant),

  PollingCounter = share:get(SM, polling_pc),
  DataPos = <<"POS....">>,
  LenDataPos = byte_size(DataPos),
  DataCDT = list_to_binary([DS, DT]),

  % TODO: Set max pos len
  CPollingFlagBurst = nl_mac_hf:count_flag_bits(1),
  CPollingCounterLen = nl_mac_hf:count_flag_bits(127),
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),

  PollFlagBurst = 0,
  BPollFlagBurst = <<PollFlagBurst:CPollingFlagBurst>>,
  BPollingCounter = <<PollingCounter:CPollingCounterLen>>,
  BLenPos = <<LenDataPos:CBitsPosLen>>,

  TmpData = <<"C", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, DataCDT/binary>>,

  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"C", BPollFlagBurst/bitstring, BPollingCounter/bitstring, BLenPos/bitstring, DataPos/binary, 0:Add, DataCDT/binary>>;
  true ->
    TmpData
  end,

  LenData = byte_size(Data),
  increase_local_pc(SM, polling_pc),

  if LenData < 64 ->
    {at, {pid, 0},"*SENDIM", Current_polling_addr, ack, Data};
  true ->
    {at, {pid, 0},"*SEND", Current_polling_addr, Data}
  end.

queue_to_data(SM, Dst, Name) ->
  Qname = list_to_atom(atom_to_list(Name) ++ atom_to_list(Dst)),
  Q = share:get(SM, Qname),
  case Q of
    nothing -> <<"">>;
    {[],[]} -> <<"">>;
    _ ->
      LData = queue:to_list(Q),
      F = fun(X) -> {_PC, _LocalPC, _Status, _Time, _Type, _Len, Data} = X, Data end,
      list_to_binary(lists:join(<<"">>, [ F(X)  || X <- LData]))
  end.

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

add_to_CDT_queue(SM, STuple) ->
  LocalPC = share:get(SM, local_pc),
  increase_local_pc(SM, local_pc),
  % TODO: maybe we have to save messages to a file
  {nl, send, TransmitLen, IDst, MsgType, Payload} = STuple,

  Polling_seq_msgs = share:get(SM, polling_seq_msgs),
  add_to_limited_list(SM, Polling_seq_msgs, IDst, polling_seq_msgs, 10),

  ADst = binary_to_atom(integer_to_binary(IDst), utf8),
  Qname = list_to_atom(atom_to_list(MsgType) ++ atom_to_list(ADst)),

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
      %TODO: configurable parameter Max
      nl_mac_hf:queue_limited_push(Q, Item, 3)
  end,
  share:put(SM, Qname, NQ),
  ?TRACE(?ID, "add_to_CDT_queue ~p~n", [share:get(SM, Qname)]).

delete_delivered_item(SM, Name, PC, Dst) ->
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),
  Qname = list_to_atom(atom_to_list(Name) ++ atom_to_list(DstA)),
  QueueItems = share:get(SM, Qname),
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
  SM.

change_status_item(SM, PC, {MsgType, LocalPC, ATSendTuple}) ->
  {at, {pid, _}, "*SEND", Dst, Data} = ATSendTuple,
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),

  Qname = list_to_atom(atom_to_list(MsgType) ++ atom_to_list(DstA)),
  QueueItems = share:get(SM, Qname),
  QueueItemsList = queue:to_list(QueueItems),

  Payload = extract_poll_data(SM, Data),
  NQ =
  lists:foldr(
  fun(X, Q) ->
    case X of
      {_, LocalPC, Status, Time, MsgType, TransmitLen, Payload} when MsgType == tolerant ->
        Item = {PC, LocalPC, Status, Time, MsgType, TransmitLen, Payload},
        queue:in(Item, Q);
      {_, LocalPC, Status, Time, MsgType, TransmitLen, Payload} when MsgType == sensitive ->
        Item = {PC, LocalPC, Status, Time, MsgType, TransmitLen, Payload},
        nl_mac_hf:queue_limited_push(Q, Item, 3);
      Rest when MsgType == tolerant ->
        queue:in(Rest, Q);
      Rest when MsgType == sensitive ->
        nl_mac_hf:queue_limited_push(Q, Rest, 3)
    end
  end, queue:new(), QueueItemsList),

  share:put(SM, Qname, NQ),
  SM.
