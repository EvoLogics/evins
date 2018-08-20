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

-module(nl_hf). % network layer helper functions
-compile({parse_transform, pipeline}).

-import(lists, [filter/2, foldl/3, map/2, member/2]).

-include("fsm.hrl").
-include("nl.hrl").

-export([fill_transmission_queue/3, increase_pkgid/3, code_send_tuple/2, create_nl_at_command/2, get_params_spec_timeout/2]).
-export([extract_payload_nl/2, extract_payload_nl_header/2]).
-export([mac2nl_address/1, num2flag/2, add_neighbours/3]).
-export([get_front_transmission_queue/1, check_received_queue/2, change_TTL_received_queue/2,
         delete_from_transmission_queue/2, decrease_TTL_transmission_queue/1]).
-export([init_dets/1, fill_dets/4, get_event_params/2, set_event_params/2, clear_event_params/2]).
% later do not needed to export
-export([nl2mac_address/1, get_routing_address/3, nl2at/3, create_payload_nl_header/8, flag2num/1, queue_limited_push/4]).
-export([decrease_local_retries/2]).
-export([process_set_command/2, process_get_command/2, update_statistics/4, set_processing_time/3,fill_statistics_queue/2]).

set_event_params(SM, Event_Parameter) ->
  SM#sm{event_params = Event_Parameter}.

get_event_params(SM, Event) ->
  if SM#sm.event_params =:= [] ->
       nothing;
     true ->
       EventP = hd(tuple_to_list(SM#sm.event_params)),
       if EventP =:= Event -> SM#sm.event_params;
        true -> nothing
       end
  end.

clear_event_params(SM, Event) ->
  if SM#sm.event_params =:= [] ->
       SM;
     true ->
       EventP = hd(tuple_to_list(SM#sm.event_params)),
       if EventP =:= Event -> SM#sm{event_params = []};
        true -> SM
       end
  end.

get_params_spec_timeout(SM, Spec) ->
  lists:filtermap(
   fun({E, _TRef}) ->
     case E of
       {Spec, P} -> {true, P};
       _  -> false
     end
  end, SM#sm.timeouts).

code_send_tuple(SM, NL_Send_Tuple) ->
  % TODO: change, usig also other protocols
  Protocol_Name = share:get(SM, protocol_name),
  TTL = share:get(SM, ttl),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_address = share:get(SM, local_address),
  {nl, send, Dst, Payload} = NL_Send_Tuple,
  PkgID = increase_pkgid(SM, Local_address, Dst),

  Flag = data,
  Src = Local_address,

  ?TRACE(?ID, "Code Send Tuple Flag ~p, PkgID ~p, TTL ~p, Src ~p, Dst ~p~n",
              [Flag, PkgID, TTL, Src, Dst]),

  if (((Dst =:= ?ADDRESS_MAX) and Protocol_Config#pr_conf.br_na)) ->
      error;
  true ->
      {Flag, PkgID, TTL, Src, Dst, Payload}
  end.

queue_limited_push(SM, Qname, Item, Max) ->
  Q = share:get(SM, Qname),
  Q_Member = queue:member(Item, Q),
  case queue:len(Q) of
    Len when Len >= Max, not Q_Member ->
      share:put(SM, Qname, queue:in(Item, queue:drop(Q)));
    _ when not Q_Member ->
      share:put(SM, Qname, queue:in(Item, Q));
    _ -> SM
  end.

queue_limited_push(Q, Item, Max) ->
  Q_Member = queue:member(Item, Q),
  case queue:len(Q) of
    Len when Len >= Max, not Q_Member ->
      queue:in(Item, queue:drop(Q));
    _ when not Q_Member ->
      queue:in(Item, Q);
    _ -> Q
  end.

fill_transmission_queue(SM, _, error) ->
  set_event_params(SM, {fill_tq, error});
fill_transmission_queue(SM, Type, NL_Send_Tuple) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),
  case queue:len(Q) of
    Len when Len >= ?TRANSMISSION_QUEUE_SIZE ->
      set_event_params(SM, {fill_tq, error});
    _ when Type == filo ->
      ?INFO(?ID, "fill_transmission_queue 1 ~p~n", [NL_Send_Tuple]),
      [fill_statistics_queue(__, NL_Send_Tuple),
      share:put(__, Qname, queue:in(NL_Send_Tuple, Q)),
      set_event_params(__, {fill_tq, ok})](SM);
    _ when Type == fifo ->
      ?INFO(?ID, "fill_transmission_queue 2 ~p~n", [NL_Send_Tuple]),
      [fill_statistics_queue(__, NL_Send_Tuple),
      share:put(__, Qname, queue:in_r(NL_Send_Tuple, Q)),
      set_event_params(__, {fill_tq, ok})](SM)
  end.

fill_statistics_queue(SM, {dst_reached, _PkgID, _TTL, _Src, _Dst, _Payload}) ->
  SM;
fill_statistics_queue(SM, Tuple) ->
  Local_Address = share:get(SM, local_address),
  Qname = statistics_queue,
  Q = share:get(SM, Qname),
  Role =
  case Tuple of
    {_Flag, _PkgID, _TTL, Local_Address, _Dst, _Payload} -> source;
    {_Flag, _PkgID, _TTL, _Src, Local_Address, _Payload} -> destination;
    _ -> relay
  end,
  ?INFO(?ID, "fill_sq_helper ~p~n", [Tuple]),
  fill_sq_helper(SM, Role, Tuple, not_inside, Q, queue:new()).

fill_sq_helper(SM, _Role, _Tuple, inside, {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
fill_sq_helper(SM, Role, Tuple, not_inside, {[],[]}, NQ) ->
  Statistics_Tuple = {empty, empty, Role, Tuple},
  ?INFO(?ID, "add to statistics ~p~n", [Statistics_Tuple]),
  Processed_Q = queue_limited_push(NQ, Statistics_Tuple, ?Q_STATISTICS_SIZE),
  share:put(SM, statistics_queue, Processed_Q);
fill_sq_helper(SM, Role, Tuple, Inside, Q, NQ) ->
  {Flag, PkgID, TTL, Src, Dst, Payload} = Tuple,
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {_STime, _RTime, _Role, {Flag, PkgID, Stored_TTL, Src, Dst, Payload}} when TTL < Stored_TTL ->
      Statistics_Tuple = {empty, empty, Role, Tuple},
      ?INFO(?ID, "add to statistics ~p~n", [Statistics_Tuple]),
      Processed_Q = queue_limited_push(NQ, Statistics_Tuple, ?Q_STATISTICS_SIZE),
      fill_sq_helper(SM, Role, Tuple, inside, Q_Tail, Processed_Q);
    _ ->
      Processed_Q = queue_limited_push(NQ, Q_Tuple, ?Q_STATISTICS_SIZE),
      fill_sq_helper(SM, Role, Tuple, Inside, Q_Tail, Processed_Q)
  end.

set_processing_time(SM, Type, Tuple) ->
  Qname = statistics_queue,
  Q = share:get(SM, Qname),
  set_processing_time_helper(SM, Type, Tuple, Q, queue:new()).

set_processing_time_helper(SM, _Type, _Tuple, {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
set_processing_time_helper(SM, Type, Tuple, Q, NQ) ->
  {Flag, PkgID, _, Src, Dst, Payload} = Tuple,
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Current_Time = erlang:monotonic_time(milli_seconds),
  ?INFO(?ID, "compare ~p  ~p ~p~n", [Q_Tuple, Type, Tuple]),
  case Q_Tuple of
    {_Send_Time, Recv_Time, _Role,
      {Stored_Flag, PkgID, TTL, Dst, Src, Stored_Payload}} when Type == transmitted,
                                                                Flag == dst_reached ->
      NL_Recv_Tuple = {Stored_Flag, PkgID, TTL, Src, Dst, Stored_Payload},
      Statistics_Tuple = {Current_Time, Recv_Time, destination, NL_Recv_Tuple},
      Processed_Q = queue_limited_push(NQ, Statistics_Tuple, ?Q_STATISTICS_SIZE),
      set_processing_time_helper(SM, Type, Tuple, Q_Tail, Processed_Q);
    {_Send_Time, Recv_Time, Role, {Flag, PkgID, _TTL, Src, Dst, Payload}} when Type == transmitted ->
      Statistics_Tuple = {Current_Time, Recv_Time, Role, Tuple},
      Processed_Q = queue_limited_push(NQ, Statistics_Tuple, ?Q_STATISTICS_SIZE),
      set_processing_time_helper(SM, Type, Tuple, Q_Tail, Processed_Q);
    {Send_Time, _Recv_Time, Role, {Flag, PkgID, _TTL, Src, Dst, Payload}} when Type == received,
                                                                               Flag =/= dst_reached ->
      Statistics_Tuple = {Send_Time, Current_Time, Role, Tuple},
      Processed_Q = queue_limited_push(NQ, Statistics_Tuple, ?Q_STATISTICS_SIZE),
      set_processing_time_helper(SM, Type, Tuple, Q_Tail, Processed_Q);
    _ ->
      Processed_Q = queue_limited_push(NQ, Q_Tuple, ?Q_STATISTICS_SIZE),
      set_processing_time_helper(SM, Type, Tuple, Q_Tail, Processed_Q)
  end.

get_front_transmission_queue(SM) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),
  Front=
  case queue:is_empty(Q) of
    true ->  empty;
    false -> {Item, _} = queue:out(Q), Item
  end,
  ?INFO(?ID, "GET FRONT ~p~n", [Front]),
  Front.

delete_from_transmission_queue(SM, Tuple) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),
  {Flag, PkgID, _, Src, Dst, Payload} = Tuple,
  Transmission_queue = get_front_transmission_queue(SM),
  case Transmission_queue of
    empty -> clear_sensing_timeout(SM, Tuple);
    {value, {Flag, PkgID, _TTL, Src, Dst, Payload}} ->
      {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
      ?TRACE(?ID, "deleted Tuple ~p from  ~p~n",[Tuple, share:get(SM, Qname)]),
      [delete_from_retries_queue(__, Q_Tuple),
      clear_sensing_timeout(__, Q_Tuple),
      share:put(__, transmission_queue, Q_Tail)](SM);
    {value, {_Flag, PkgID, _TTL, Dst, Src, _Payload}} ->
      {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
      ?TRACE(?ID, "deleted Tuple ~p from  ~p~n",[Tuple, share:get(SM, Qname)]),
      [delete_from_retries_queue(__, Q_Tuple),
      clear_sensing_timeout(__, Q_Tuple),
      share:put(__, transmission_queue, Q_Tail)](SM);
    _ -> clear_sensing_timeout(SM, Tuple)
  end.

clear_sensing_timeout(SM, Tuple) ->
  ?TRACE(?ID, "Clear sensing timeout ~p~n",[Tuple]),
  {Flag, PkgID, _, Src, Dst, Payload} = Tuple,
  TRefList = filter(
             fun({E, TRef}) ->
                 case E of
                    {sensing_timeout, {Flag, PkgID, _TTL, Src, Dst, Payload}} ->
                      timer:cancel(TRef),
                      false;
                    {sensing_timeout, {_Flag, PkgID, _TTL, Dst, Src, _Payload}} ->
                      timer:cancel(TRef),
                      false;
                   _  -> true
                 end
             end, SM#sm.timeouts),
  SM#sm{timeouts = TRefList}.

delete_from_retries_queue(SM, Tuple) ->
  Qname = retries_queue,
  Q = share:get(SM, Qname),
  ?TRACE(?ID, "deleted Tuple ~p from retry queue ~p~n",[Tuple, share:get(SM, Qname)]),
  delete_from_retq_helper(SM, Tuple, Q, queue:new()).

delete_from_retq_helper(SM, _Tuple, {[],[]}, NQ) ->
  share:put(SM, retries_queue, NQ);
delete_from_retq_helper(SM, Tuple = {Flag, PkgID, _, Src, Dst, Payload}, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {_Retries, {Flag, PkgID, _TTL, Src, Dst, Payload}} ->
      delete_from_retq_helper(SM, Tuple, Q_Tail, NQ);
    _ ->
      delete_from_retq_helper(SM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

decrease_local_retries(SM, Tuple) ->
  Qname = retries_queue,
  Q = share:get(SM, Qname),
  ?TRACE(?ID, "Change local tries of packet ~p in retry queue ~p~n",[Tuple, Q]),
  decrease_local_retq_helper(SM, Tuple, not_inside, Q, queue:new()).

decrease_local_retq_helper(SM, Tuple, _, Q = {[],[]}, {[],[]}) ->
  Local_Retries = share:get(SM, retries),
  share:put(SM, retries_queue, queue:in({Local_Retries, Tuple}, Q));
decrease_local_retq_helper(SM, Tuple, not_inside, {[],[]}, NQ) ->
  Local_Retries = share:get(SM, retries),
  share:put(SM, retries_queue, queue:in({Local_Retries, Tuple}, NQ));
decrease_local_retq_helper(SM, _Tuple, inside, {[],[]}, NQ) ->
  share:put(SM, retries_queue, NQ);
decrease_local_retq_helper(SM, Tuple = {Flag, PkgID, _, Src, Dst, Payload}, Inside, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {Retries, {Flag, PkgID, _TTL, Src, Dst, Payload}} when Retries =< 0 ->
      ?TRACE(?ID, "drop Tuple ~p from  ~p, retries ~p ~n",[Q_Tuple, Q, Retries]),
      [delete_from_transmission_queue(__, Tuple),
      decrease_local_retq_helper(__, Tuple, inside, Q_Tail, NQ)](SM);
    {Retries, {Flag, PkgID, _TTL, Src, Dst, Payload}} when Retries > 0 ->
      ?TRACE(?ID, "change Tuple ~p in  ~p, retries ~p ~n",[Q_Tuple, Q, Retries - 1]),
      decrease_local_retq_helper(SM, Tuple, inside, Q_Tail, queue:in({Retries - 1, Tuple}, NQ));
    _ ->
      decrease_local_retq_helper(SM, Tuple, Inside, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

decrease_TTL_transmission_queue(SM) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),
  ?INFO(?ID, "decrease TTL for every packet in the queue ~p ~n",[share:get(SM, Qname)]),
  decrease_TTL_tq(SM, Q, queue:new()).

decrease_TTL_tq(SM, {[],[]}, NQ) ->
  share:put(SM, transmission_queue, NQ);
decrease_TTL_tq(SM, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {Flag, PkgID, TTL, Src, Dst, Payload} when Flag =/= dst_reached ->
      Decreased_TTL = TTL - 1,
      if Decreased_TTL =< 0 ->
        ?INFO(?ID, "decrease and drop ~p, TTL ~p =< 0 ~n",[Q_Tuple, TTL]),
        [clear_sensing_timeout(__, Q_Tuple),
         decrease_TTL_tq(__, Q_Tail, NQ)](SM);
      true ->
        Tuple = {Flag, PkgID, Decreased_TTL, Src, Dst, Payload},
        decrease_TTL_tq(SM, Q_Tail, queue:in(Tuple, NQ))
      end;
    _ ->
      decrease_TTL_tq(SM, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

check_received_queue(SM, Tuple) ->
  Qname = received_queue,
  Q = share:get(SM, Qname),
  check_exist_rq_helper(SM, Tuple, Q).

check_exist_rq_helper(Tuple) ->
  Tuple.
check_exist_rq_helper(_SM, _Tuple, {[],[]}) ->
  {false, nothing};
check_exist_rq_helper(SM, Tuple = {Flag, PkgID, TTL, Src, Dst, Payload}, Q) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {Flag, PkgID, TTL, Src, Dst, Payload} ->
      check_exist_rq_helper({true, TTL});
    {Flag, PkgID, Stored_TTL, Src, Dst, Payload} ->
      check_exist_rq_helper({true, Stored_TTL});
    _ ->
      check_exist_rq_helper(SM, Tuple, Q_Tail)
  end.

change_TTL_received_queue(SM, Tuple) ->
  Qname = received_queue,
  Q = share:get(SM, Qname),
  change_TTL_rq_helper(SM, Tuple, Q, queue:new()).

change_TTL_rq_helper(SM, Tuple, {[],[]}, NQ) ->
  ?INFO(?ID, "change TTL for Tuple ~p in the queue ~p~n",[Tuple, NQ]),
  share:put(SM, received_queue, NQ);
change_TTL_rq_helper(SM, Tuple = {Flag, PkgID, TTL, Src, Dst, Payload}, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {Flag, PkgID, Stored_TTL, Src, Dst, Payload} when TTL < Stored_TTL ->
      NT = {Flag, PkgID, TTL, Src, Dst, Payload},
      change_TTL_rq_helper(SM, Tuple, Q_Tail, queue:in(NT, NQ));
    _ ->
      change_TTL_rq_helper(SM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

%%----------------------------Converting NL -------------------------------
%TOD0:!!!!
% return no_address, if no info
nl2mac_address(Address) -> Address.
mac2nl_address(Address) -> Address.

flag2num(Flag) when is_atom(Flag)->
  integer_to_binary(?FLAG2NUM(Flag)).

num2flag(Num, Layer) when is_integer(Num)->
  ?NUM2FLAG(Num, Layer);
num2flag(Num, Layer) when is_binary(Num)->
  ?NUM2FLAG(binary_to_integer(Num), Layer).

%%----------------------------Routing helper functions -------------------------------
%TOD0:!!!!
get_routing_address(_SM, _Flag, _Address) -> 255.
%%----------------------------Parse NL functions -------------------------------
fill_protocol_info_header(dst_reached, {Transmit_Len, Data}) ->
  fill_data_header(Transmit_Len, Data);
fill_protocol_info_header(data, {Transmit_Len, Data}) ->
  fill_data_header(Transmit_Len, Data).
% fill_msg(neighbours, Tuple) ->
%   create_neighbours(Tuple);
% fill_msg(neighbours_path, {Neighbours, Path}) ->
%   create_neighbours_path(Neighbours, Path);
% fill_msg(path_data, {TransmitLen, Data, Path}) ->
%   create_path_data(Path, TransmitLen, Data);
% fill_msg(path_addit, {Path, Additional}) ->
%   create_path_addit(Path, Additional).

nl2at(SM, IDst, Tuple) when is_tuple(Tuple)->
  PID = share:get(SM, pid),
  NLPPid = ?PROTOCOL_NL_PID(share:get(SM, protocol_name)),
  ?WARNING(?ID, ">>>>>>>> NLPPid: ~p~n", [NLPPid]),
  case Tuple of
    {Flag, PkgID, TTL, Src, Dst, Payload}  when byte_size(Payload) < ?MAX_IM_LEN ->
      AT_Payload = create_payload_nl_header(SM, NLPPid, Flag, PkgID, TTL, Src, Dst, Payload),
      {at, {pid,PID}, "*SENDIM", IDst, noack, AT_Payload};
    {Flag, PkgID, TTL, Src, Dst, Payload} ->
      AT_Payload = create_payload_nl_header(SM, NLPPid, Flag, PkgID, TTL, Src, Dst, Payload),
      {at, {pid,PID}, "*SEND", IDst, AT_Payload};
    _ ->
      error
  end.

%%------------------------- Extract functions ----------------------------------
create_nl_at_command(SM, NL_Info_Original) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_address = share:get(SM, local_address),

  {Flag, PkgID, TTL, Src, Dst, Original_Payload} = NL_Info_Original,

  % TODO: Additional_Info, different protocols have difeferent Header
  Transmit_Len = byte_size(Original_Payload),
  Payload = fill_protocol_info_header(Flag, {Transmit_Len, Original_Payload}),

  NL_Info = {Flag, PkgID, TTL, Src, Dst, Payload},

  Route_Addr = get_routing_address(SM, Flag, Dst),
  MAC_Route_Addr = nl2mac_address(Route_Addr),

  ?TRACE(?ID, "MAC_Route_Addr ~p, Src ~p, Dst ~p~n", [MAC_Route_Addr, Src, Dst]),

  if ((MAC_Route_Addr =:= error) or
      ((Dst =:= ?ADDRESS_MAX) and Protocol_Config#pr_conf.br_na)) ->
      % TODO: check if it can be
      error;
  true ->
      AT_Command = nl2at(SM, MAC_Route_Addr, NL_Info),
      Current_RTT = {rtt, Local_address, Dst},
      ?TRACE(?ID, "Current RTT ~p sending AT command ~p~n", [Current_RTT, AT_Command]),

      Monotonic_time = erlang:monotonic_time(micro_seconds),
      share:put(SM, [{{last_nl_sent_time, Current_RTT}, Monotonic_time},
                      {last_nl_sent, {send, NL_Info}},
                      {ack_last_nl_sent, {PkgID, Src, Dst}}]),
      fill_dets(SM, PkgID, Src, Dst),
      AT_Command
  end.

extract_payload_nl(SM, Payload) ->
  Protocol_Name = share:get(SM, protocol_name),
  _Protocol_Config = share:get(SM, protocol_config, Protocol_Name),

  {Pid, Flag_Num, Pkg_ID, TTL, NL_Src, NL_Dst, Tail} = extract_payload_nl_header(SM, Payload),
  Flag = nl_hf:num2flag(Flag_Num, nl),
  % TODO: split path data
  Splitted_Payload =
  case Flag of
    data ->
      case split_path_data(SM, Tail) of
        [_Path, _B_LenData, Data] -> Data;
        _ -> Tail
      end;
    _ -> <<"">>
  end,

  {Pid, Flag_Num, Pkg_ID, TTL, NL_Src, NL_Dst, Splitted_Payload}.

extract_payload_nl_header(SM, Payload) ->
  % 6 bits NL_Protocol_PID
  % 3 bits Flag
  % 6 bits PkgID
  % 2 bits TTL
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 3)

  Max_TTL = share:get(SM, ttl),
  C_Bits_Pid = count_flag_bits(?NL_PID_MAX),
  C_Bits_Flag = count_flag_bits(?FLAG_MAX),
  C_Bits_PkgID = count_flag_bits(?PKG_ID_MAX),
  C_Bits_TTL = count_flag_bits(Max_TTL),
  C_Bits_Addr = count_flag_bits(?ADDRESS_MAX),

  Data_Bin = (bit_size(Payload) rem 8) =/= 0,
  <<B_Pid:C_Bits_Pid, B_Flag:C_Bits_Flag, B_PkgID:C_Bits_PkgID, B_TTL:C_Bits_TTL,
    B_Src:C_Bits_Addr, B_Dst:C_Bits_Addr, Rest/bitstring>> = Payload,
  if Data_Bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    {B_Pid, B_Flag, B_PkgID, B_TTL, B_Src, B_Dst, Data};
  true ->
    {B_Pid, B_Flag, B_PkgID, B_TTL, B_Src, B_Dst, Rest}
  end.

create_payload_nl_header(SM, Pid, Flag, PkgID, TTL, Src, Dst, Data) ->
  % 6 bits NL_Protocol_PID
  % 3 bits Flag
  % 6 bits PkgID
  % 2 bits TTL
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 3)
  Max_TTL = share:get(SM, ttl),
  C_Bits_Pid = count_flag_bits(?NL_PID_MAX),
  C_Bits_Flag = count_flag_bits(?FLAG_MAX),
  C_Bits_PkgID = count_flag_bits(?PKG_ID_MAX),
  C_Bits_TTL = count_flag_bits(Max_TTL),
  C_Bits_Addr = count_flag_bits(?ADDRESS_MAX),

  B_Pid = <<Pid:C_Bits_Pid>>,

  Flag_Num = ?FLAG2NUM(Flag),
  B_Flag = <<Flag_Num:C_Bits_Flag>>,

  B_PkgID = <<PkgID:C_Bits_PkgID>>,
  B_TTL = <<TTL:C_Bits_TTL>>,
  B_Src = <<Src:C_Bits_Addr>>,
  B_Dst = <<Dst:C_Bits_Addr>>,

  Tmp_Data = <<B_Pid/bitstring, B_Flag/bitstring, B_PkgID/bitstring, B_TTL/bitstring,
               B_Src/bitstring, B_Dst/bitstring, Data/binary>>,
  Data_Bin = is_binary(Tmp_Data) =:= false or ( (bit_size(Tmp_Data) rem 8) =/= 0),

  if Data_Bin =:= false ->
    Add = (8 - bit_size(Tmp_Data) rem 8) rem 8,
    <<B_Pid/bitstring, B_Flag/bitstring, B_PkgID/bitstring, B_TTL/bitstring, B_Src/bitstring,
      B_Dst/bitstring, 0:Add, Data/binary>>;
  true ->
    Tmp_Data
  end.

%-------> data
% 3b        6b
%   TYPEMSG   MAX_DATA_LEN
fill_data_header(TransmitLen, Data) ->
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  TypeNum = ?TYPEMSG2NUM(data),

  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenData = <<TransmitLen:CBitsMaxLenData>>,

  BHeader = <<BType/bitstring, BLenData/bitstring>>,
  Add = (8 - (bit_size(BHeader)) rem 8) rem 8,
  <<BHeader/bitstring, 0:Add, Data/binary>>.

% TODO:
split_path_data(SM, Payload) ->
  C_Bits_TypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  _C_Bits_LenPath = count_flag_bits(?MAX_LEN_PATH),
  C_Bits_MaxLenData = count_flag_bits(?MAX_DATA_LEN),

  Data_Bin = (bit_size(Payload) rem 8) =/= 0,
  <<B_Type:C_Bits_TypeMsg, B_LenData:C_Bits_MaxLenData, Path_Rest/bitstring>> = Payload,

  {Path, Rest} =
  case ?NUM2TYPEMSG(B_Type) of
    % TODO path data
    %path_data ->
    %  extract_header(path, CBitsLenPath, CBitsLenPath, PathRest);
    data ->
      {nothing, Path_Rest}
  end,

  ?TRACE(?ID, "extract path data BType ~p ~n", [B_Type]),
  if Data_Bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [Path, B_LenData, Data];
  true ->
    [Path, B_LenData, Rest]
  end.

%%------------------------- ETS Helper functions ----------------------------------
init_dets(SM) ->
  Ref = SM#sm.dets_share,
  NL_protocol = share:get(SM, protocol_name),

  case B = dets:lookup(Ref, NL_protocol) of
    [{NL_protocol, ListIds}] ->
      [ share:put(SM, {packet_id, S, D}, ID) || {ID, S, D} <- ListIds];
    _ ->
      nothing
  end,

  ?TRACE(?ID,"init_dets LA ~p:   ~p~n", [share:get(SM, local_address), B]),
  SM#sm{dets_share = Ref}.

fill_dets(SM, PkgID, Src, Dst) ->
  Local_Address  = share:get(SM, local_address),
  Ref = SM#sm.dets_share,
  Protocol_Name = share:get(SM, protocol_name),

  case dets:lookup(Ref, Protocol_Name) of
    [] ->
      dets:insert(Ref, {Protocol_Name, [{PkgID, Src, Dst}]});
    [{Protocol_Name, ListIds}] ->
      Member = lists:filtermap(fun({ID, S, D}) when S == Src, D == Dst ->
                                 {true, ID};
                                (_S) -> false
                               end, ListIds),
      LIds =
      case Member of
        [] -> [{PkgID, Src, Dst} | ListIds];
        _  -> ListIds
      end,

      NewListIds = lists:map(fun({_, S, D}) when S == Src, D == Dst -> {PkgID, S, D}; (T) -> T end, LIds),
      %[ share:put(SM, {packet_id, S, D}, ID) || {ID, S, D} <- NewListIds],
      dets:insert(Ref, {Protocol_Name, NewListIds});
    _ -> nothing
  end,

  Ref1 = SM#sm.dets_share,
  B = dets:lookup(Ref1, Protocol_Name),

  ?INFO(?ID, "Fill dets for local address ~p ~p ~p ~n", [Local_Address, B, PkgID] ),

  SM#sm{dets_share = Ref1}.

%%------------------------- Math Helper functions ----------------------------------
count_flag_bits (F) ->
count_flag_bits_helper(F, 0).

count_flag_bits_helper(0, 0) -> 1;
count_flag_bits_helper(0, C) -> C;
count_flag_bits_helper(F, C) ->
  Rem = F rem 2,
  D =
  if Rem =:= 0 ->
    F / 2;
    true -> F / 2 - 0.5
  end,
  count_flag_bits_helper(round(D), C + 1).

get_average(0, Val2) ->
  round(Val2);
get_average(Val1, Val2) ->
  round((Val1 + Val2) / 2).

%----------------------- Pkg_ID Helper functions ----------------------------------
increase_pkgid(SM, Src, Dst) ->
  Max_Pkg_ID = share:get(SM, max_pkg_id),
  PkgID = case share:get(SM, {packet_id, Src, Dst}) of
            nothing -> 0;
            Prev_ID when Prev_ID >= Max_Pkg_ID -> 0;
            (Prev_ID) -> Prev_ID + 1
          end,
  ?TRACE(?ID, "Increase Pkg Id LA ~p: packet_id ~p~n", [share:get(SM, local_address), PkgID]),
  share:put(SM, {packet_id, Src, Dst}, PkgID),
  PkgID.

add_neighbours(SM, Src, {Rssi, Integrity}) ->
  ?INFO(?ID, "Add neighbour Src ~p, Rssi ~p Integrity ~p ~n", [Src, Rssi, Integrity]),
  Neighbours_Channel = share:get(SM, neighbours_channel),
  Current_Time = erlang:monotonic_time(milli_seconds) - share:get(SM, nl_start_time),
  Neighbours = share:get(SM, current_neighbours),
  case lists:member(Src, Neighbours) of
    _ when Neighbours_Channel == nothing ->
      [share:put(__, neighbours_channel, [{Src, Rssi, Integrity, Current_Time}]),
      share:put(__, current_neighbours, [Src])](SM);
    true ->
      Key = lists:keyfind(Src, 1, Neighbours_Channel),
      {_, Stored_Rssi, Stored_Integrity, _} = Key,
      Averaged_Rssi = get_average(Rssi, Stored_Rssi),
      Averaged_Integrity = get_average(Integrity, Stored_Integrity),
      Updated_Neighbours = lists:delete(Key, Neighbours_Channel),
      Channel_Tuple = {Src, Averaged_Rssi, Averaged_Integrity, Current_Time},
      [share:put(__, neighbours_channel, [Channel_Tuple | Updated_Neighbours]),
      share:put(__, current_neighbours, Neighbours)](SM);
    false ->
      Channel_Tuple = {Src, Rssi, Integrity, Current_Time},
      [share:put(__, neighbours_channel, [Channel_Tuple | Neighbours_Channel]),
      share:put(__, current_neighbours, [Src | Neighbours])](SM)
  end.

%%--------------------------------------------------  command functions -------------------------------------------
process_set_command(SM, Command) ->
  Protocol_Name = share:get(SM, protocol_name),
  Cast =
  case Command of
    {address, Address} when is_integer(Address) ->
      share:put(SM, local_address, Address),
      {nl, address, Address};
    {protocol, Name} ->
      case lists:member(Name, ?LIST_ALL_PROTOCOLS) of
        true ->
          share:put(SM, protocol_name, Name),
          {nl, protocol, Name};
        _ ->
          {nl, protocol, error}
      end;
    {neighbours, Neighbours} when Protocol_Name =:= staticr;
                                  Protocol_Name =:= staticrack ->
      case Neighbours of
        empty ->
          share:put(SM, current_neighbours, []),
          share:put(SM, neighbours_channel, []);
        [H|_] when is_integer(H) ->
          share:put(SM, current_neighbours, Neighbours),
          share:put(SM, neighbours_channel, Neighbours);
        _ ->
          CurrentTime = erlang:monotonic_time(milli_seconds),
          Neighbours_channel = [ {A, I, R, CurrentTime - T } || {A, I, R, T} <- Neighbours],
          share:put(SM, neighbours_channel, Neighbours_channel),
          share:put(SM, current_neighbours, [ A || {A, _, _, _} <- Neighbours])
      end,
      {nl, neighbours, Neighbours};
    {neighbours, _Neighbours} ->
      {nl, neighbours, error};
    {routing, Routing} when Protocol_Name =:= staticr;
                            Protocol_Name =:= staticrack ->
      Routing_Format = lists:map(
                        fun({default, To}) -> To;
                            (Other) -> Other
                        end, Routing),
      share:put(SM, routing_table, Routing_Format),
      {nl, routing, Routing};
    {routing, _Routing} ->
      {nl, routing, error};
    _ ->
      {nl, error}
  end,
  fsm:cast(SM, nl_impl, {send, Cast}).

process_get_command(SM, Command) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol = share:get(SM, protocol_config, Protocol_Name),
  Neighbours_Channel = share:get(SM, neighbours_channel),
  Statistics_Queue = share:get(SM, statistics_queue),
  Statistics_Queue_Empty = queue:is_empty(Statistics_Queue),
  Cast =
  case Command of
    protocols ->
      {nl, Command, ?LIST_ALL_PROTOCOLS};
    states ->
      Last_states = share:get(SM, last_states),
      {nl, states, queue:to_list(Last_states)};
    state ->
      {nl, state, {SM#sm.state, SM#sm.event}};
    address ->
      {nl, address, share:get(SM, local_address)};
    neighbours when Neighbours_Channel == nothing;
                    Neighbours_Channel == [] ->
      {nl, neighbours, empty};
    neighbours ->
      {nl, neighbours, Neighbours_Channel};
    routing ->
      {nl, routing, routing_to_list(SM)};
    {protocolinfo, Name} ->
      {nl, protocolinfo, Name, get_protocol_info(SM, Name)};
    {statistics, paths} when Protocol#pr_conf.pf ->
      Paths =
        lists:map(fun({{Role, Path}, Duration, Count, TS}) ->
                      {Role, Path, Duration, Count, TS}
                  end, queue:to_list(share:get(SM, paths))),
      Answer = case Paths of []  -> empty; _ -> Paths end,
      {nl, statistics, paths, Answer};
    {statistics, paths} ->
      {nl, statistics, paths, error};
    {statistics, neighbours} ->
      Neighbours =
        lists:map(fun({{Role, Address}, _Time, Count, TS}) ->
                      {Role, Address, Count, TS}
                  end, queue:to_list(share:get(SM, nothing, st_neighbours, empty))),
      Answer = case Neighbours of []  -> empty; _ -> Neighbours end,
      {nl, statistics, neighbours, Answer};
    {statistics, data} when Protocol#pr_conf.ack ->
      Data =
        lists:map(fun({{Role, Payload}, Time, Length, State, TS, Dst, Hops}) ->
                      TRole = case Role of source -> source; _ -> relay end,
                      <<Hash:16, _/binary>> = crypto:hash(md5,Payload),
                      {TRole,Hash,Length,Time,State,TS,Dst,Hops}
                  end, queue:to_list(share:get(SM, nothing, st_data, empty))),
      Answer = case Data of []  -> empty; _ -> Data end,
      {nl, statistics, data, Answer};
    {statistics, data} when not Statistics_Queue_Empty ->
      Data =
        lists:map(fun({Send_Timestamp, Recv_Timestamp, Role, Tuple}) ->
                      {_Flag, _PkgID, TTL, Src, Dst, Payload} = Tuple,
                      Send_Time =
                      if Send_Timestamp == empty -> 0;
                      true -> Send_Timestamp - share:get(SM, nl_start_time)
                      end,
                      Recv_Time =
                      if Recv_Timestamp == empty -> 0;
                      true -> Recv_Timestamp - share:get(SM, nl_start_time)
                      end,
                      <<Hash:16, _/binary>> = crypto:hash(md5,Payload),
                      {Role, Hash, Send_Time, Recv_Time, Src, Dst, TTL}
                  end, queue:to_list(Statistics_Queue)),
      Answer = case Data of []  -> empty; _ -> Data end,
      {nl, statistics, data, Answer};
    {statistics, data} ->
      {nl, statistics, data, empty};
    {delete, neighbour, Address} ->
      Current_Neighbours = share:get(SM, current_neighbours),
      delete_neighbour(SM, Address, Current_Neighbours),
      {nl, neighbour, ok};
    _ ->
      {nl, error}
  end,
  fsm:cast(SM, nl_impl, {send, Cast}).

get_protocol_info(SM, Name) ->
  Conf = share:get(SM, protocol_config, Name),
  Prop_list =
    lists:foldl(fun(stat,A) when Conf#pr_conf.stat -> [{"type","static routing"} | A];
                   (ry_only,A) when Conf#pr_conf.ry_only -> [{"type", "only relay"} | A];
                   (ack,A) when Conf#pr_conf.ack -> [{"ack", "true"} | A];
                   (ack,A) when not Conf#pr_conf.ack -> [{"ack", "false"} | A];
                   (br_na,A) when Conf#pr_conf.br_na -> [{"broadcast", "not available"} | A];
                   (br_na,A) when not Conf#pr_conf.br_na -> [{"broadcast", "available"} | A];
                   (pf,A) when Conf#pr_conf.pf -> [{"type", "path finder"} | A];
                   (evo,A) when Conf#pr_conf.evo -> [{"specifics", "evologics dmac rssi and integrity"} | A];
                   (dbl,A) when Conf#pr_conf.dbl -> [{"specifics", "2 waves to find bidirectional path"} | A];
                   (rm,A) when Conf#pr_conf.rm   -> [{"route", "maintained"} | A];
                   (_,A) -> A
                end, [], ?LIST_ALL_PARAMS),
  lists:reverse(Prop_list).

delete_neighbour(SM, _Address, _Neighbours) ->
  %TODO
  SM.

routing_to_list(SM) ->
  Routing_table = share:get(SM, routing_table),
  Local_address = share:get(SM, local_address),
  case Routing_table of
    ?ADDRESS_MAX ->
      [{default,?ADDRESS_MAX}];
    _ ->
      lists:filtermap(fun({From, To}) when From =/= Local_address -> {true, {From, To}};
                         ({_,_}) -> false;
                         (To) -> {true, {default, To}}
                      end, Routing_table)
  end.

update_statistics(SM, _Type, _Src, S={Real_Src, Real_Dst}) ->
  ?INFO(?ID, "update_statistics STATS ~p~n", [S]),
  %{Time, Role, TSC, _Addrs} =
  get_statistics_time(SM, Real_Src, Real_Dst),
  SM.

get_statistics_time(SM, _Src, _Dst) ->
  Qname = statistics_queue,
  Q = share:get(SM, Qname),
  ?INFO(?ID, "!!!!!!!!! STATS ~p~n", [Q]),
  SM.


