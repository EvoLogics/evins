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

-export([fill_transmission/3, increase_pkgid/3, code_send_tuple/2, create_nl_at_command/2, get_params_timeout/2]).
-export([extract_payload_nl/2, extract_payload_nl_header/2, clear_spec_timeout/2]).
-export([mac2nl_address/1, num2flag/2, add_neighbours/3, list_push/4]).
-export([head_transmission/1, exists_received/2, update_received_TTL/2,
         pop_transmission/3, pop_transmission/2, decrease_TTL/1, delete_neighbour/2]).
-export([init_dets/1, fill_dets/4, get_event_params/2, set_event_params/2, clear_event_params/2, clear_spec_event_params/2]).
-export([add_event_params/2, find_event_params/3, find_event_params/2]).
-export([nl2mac_address/1, get_routing_address/2, nl2at/3, create_payload_nl_header/8, flag2num/1, queue_push/4, queue_push/3]).
-export([decrease_retries/2, rand_float/2, update_states/1, count_flag_bits/1]).
-export([create_response/6, recreate_response/3, extract_response/1]).
-export([process_set_command/2, process_get_command/2, set_processing_time/3,fill_statistics/2, fill_statistics/3, fill_statistics/5]).

set_event_params(SM, Event_Parameter) ->
  SM#sm{event_params = Event_Parameter}.

add_event_params(SM, Tuple) when SM#sm.event_params == []->
  set_event_params(SM, [Tuple]);
add_event_params(SM, Tuple = {Name, _}) ->
  Params =
  case find_event_params(SM, Name, new) of
    new -> [Tuple | SM#sm.event_params];
    _ ->
      NE =
      lists:filtermap(
      fun(Param) ->
          case Param of
              {Name, _} -> false;
              _ -> {true, Param}
         end
      end, SM#sm.event_params),
      [Tuple | NE]
  end,
  set_event_params(SM, Params).

find_event_params(#sm{event_params = []}, _Name, Default)->
  Default;
find_event_params(SM, Name, Default) ->
  P = find_event_params(SM, Name),
  if P == [] -> Default;
  true -> P end.

find_event_params(#sm{event_params = []}, _Name)->
  [];
find_event_params(SM, Name) ->
  P =
  lists:filtermap(
  fun(Param) ->
      case Param of
          {Name, _} -> {true, Param};
          _ -> false
     end
  end, SM#sm.event_params),
  if P == [] -> [];
  true -> [NP] = P, NP end.

get_event_params(SM, Event) ->
  if SM#sm.event_params =:= [] ->
       nothing;
     true ->
       EventP = hd(tuple_to_list(SM#sm.event_params)),
       if EventP =:= Event -> SM#sm.event_params;
        true -> nothing
       end
  end.

clear_spec_timeout(SM, Spec) ->
  TRefList = filter(
               fun({E, TRef}) ->
                   case E of
                     {Spec, _} -> timer:cancel(TRef), false;
                     Spec -> timer:cancel(TRef), false;
                     _  -> true
                   end
               end, SM#sm.timeouts),
  SM#sm{timeouts = TRefList}.

clear_spec_event_params(#sm{event_params = []} = SM, _Event) ->
  SM;
clear_spec_event_params(SM, Event) ->
  Params =
    lists:filtermap(
    fun(Param) ->
        case Param of
            Event -> false;
            _ -> {true, Param}
        end
    end, SM#sm.event_params),
  set_event_params(SM, Params).

clear_event_params(#sm{event_params = []} = SM, _Event) ->
  SM;
clear_event_params(SM, Event) ->
  EventP = hd(tuple_to_list(SM#sm.event_params)),
  if EventP =:= Event -> SM#sm{event_params = []};
    true -> SM
  end.

get_params_timeout(SM, Spec) ->
  lists:filtermap(
   fun({E, _TRef}) ->
     case E of
       {Spec, P} -> {true, P};
       _  -> false
     end
  end, SM#sm.timeouts).

code_send_tuple(SM, Tuple) ->
  % TODO: change, usig also other protocols
  Protocol_Name = share:get(SM, protocol_name),
  TTL = share:get(SM, ttl),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_address = share:get(SM, local_address),
  {nl, send, Dst, Payload} = Tuple,
  PkgID = increase_pkgid(SM, Local_address, Dst),

  Flag = data,
  Src = Local_address,

  ?TRACE(?ID, "Code Send Tuple Flag ~p, PkgID ~p, TTL ~p, Src ~p, Dst ~p~n",
              [Flag, PkgID, TTL, Src, Dst]),

  if (((Dst =:= ?ADDRESS_MAX) and Protocol_Config#pr_conf.br_na)) ->
      {PkgID, error};
  true ->
      {PkgID, {Flag, PkgID, TTL, Src, Dst, Payload}}
  end.

list_push(SM, LName, Item, Max) ->
  L = share:get(SM, LName),
  Member = lists:member(Item, L),

  List_handler =
  fun (LSM) when length(L) > Max, not Member ->
        NL = lists:delete(lists:nth(length(L), L), L),
        share:put(LSM, LName, [Item | NL]);
      (LSM) when length(L) > Max, Member ->
        NL = lists:delete(lists:nth(length(L), L), L),
        share:put(LSM, LName, NL);
      (LSM) when not Member ->
        share:put(LSM, LName, [Item | L]);
      (LSM) ->
        LSM
  end,
  List_handler(SM).

queue_push(SM, Qname, Item, Max) ->
  Q = share:get(SM, Qname),
  QP = queue_push(Q, Item, Max),
  share:put(SM, Qname, QP).

queue_push(nothing, Item, Max) ->
  queue_push(queue:new(), Item, Max);
queue_push(Q, Item, Max) ->
  Q_Member = queue:member(Item, Q),
  case queue:len(Q) of
    Len when Len >= Max, not Q_Member ->
      queue:in(Item, queue:drop(Q));
    _ when not Q_Member ->
      queue:in(Item, Q);
    _ -> Q
  end.

% -------------------------------- Message queues handling functions -------------------------------------
fill_transmission(SM, _, error) ->
  set_event_params(SM, {fill_tq, error});
fill_transmission(SM, Type, Tuple) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),

  Fill_handler =
  fun(LSM) when Type == filo ->
    share:put(LSM, Qname, queue:in(Tuple, Q));
     (LSM) when Type == fifo ->
    share:put(LSM, Qname, queue:in_r(Tuple, Q))
  end,

  ?INFO(?ID, "fill_transmission ~p to ~p~n", [Tuple, Q]),
  case queue:len(Q) of
    Len when Len >= ?TRANSMISSION_QUEUE_SIZE ->
      set_event_params(SM, {fill_tq, error});
    _  ->
      [fill_statistics(__, Tuple),
      Fill_handler(__),
      set_event_params(__, {fill_tq, ok})](SM)
  end.

head_transmission(SM) ->
  Q = share:get(SM, transmission_queue),
  Head =
  case queue:is_empty(Q) of
    true ->  empty;
    false -> {Item, _} = queue:out(Q), Item
  end,
  ?INFO(?ID, "GET HEAD ~p~n", [Head]),
  Head.

pop_transmission(SM, head, Tuple) ->
  Qname = transmission_queue,
  Q = share:get(SM, Qname),
  {Flag, PkgID, _, Src, Dst, Payload} = Tuple,
  Head = head_transmission(SM),

  Pop_hadler =
  fun(LSM) ->
    {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
    ?TRACE(?ID, "deleted Tuple ~p from  ~p~n",[Tuple, Q]),
    [remove_retries(__, Q_Tuple),
     clear_sensing_timeout(__, Q_Tuple),
     share:put(__, transmission_queue, Q_Tail)
    ](LSM)
  end,

  case Head of
    {value, {Flag, PkgID, _TTL, Src, Dst, Payload}} ->
      Pop_hadler(SM);
    {value, {_Flag, PkgID, _TTL, Dst, Src, _Payload}} ->
      Pop_hadler(SM);
    _ ->
      clear_sensing_timeout(SM, Tuple)
  end.

pop_transmission(SM, Tuple = {ack, _, TTL, Src, Dst, Payload}) ->
  Q = share:get(SM, transmission_queue),
  {_, PkgID} = extract_response(Payload),
  Ack_tuple = {ack, PkgID, TTL, Src, Dst, Payload},
  ?INFO(?ID, ">>>>>>>>>>> pop_transmission Tuple ~p  ~p~n", [Tuple, Q]),
  [pop_tq_helper(__, Ack_tuple, Q, queue:new()),
   pop_tq_helper(__, Tuple, share:get(SM, transmission_queue), queue:new())
  ](SM);
pop_transmission(SM, Tuple = {dst_reached, _, TTL, Src, Dst, Payload}) ->
  Q = share:get(SM, transmission_queue),
  {_, PkgID} = extract_response(Payload),
  % remove all tuples whith the same pkg id
  ?INFO(?ID, ">>>>>>>>>>> pop_transmission ~p ~p~n", [Tuple, Q]),
  pop_tq_helper(SM, {dst_reached, PkgID, TTL, Src, Dst, Payload}, Q, queue:new());
pop_transmission(SM, Tuple) ->
  Q = share:get(SM, transmission_queue),
  ?INFO(?ID, ">>>>>>>>>>> pop_transmission ~p ~p~n", [Tuple, Q]),
  pop_tq_helper(SM, Tuple, Q, queue:new()).

pop_tq_helper(SM, _Tuple, {[],[]}, NQ) ->
  share:put(SM, transmission_queue, NQ);
pop_tq_helper(SM, Tuple = {Flag, PkgID, _, Src, Dst, Payload}, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Pop_handler =
  fun (LSM) ->
    ?TRACE(?ID, "deleted Tuple ~p from  ~p~n",[Tuple, Q]),
    [remove_retries(__, Tuple),
     remove_retries(__, Q_Tuple),
     clear_sensing_timeout(__, Q_Tuple),
     clear_sensing_timeout(__, Tuple)
    ](LSM)
  end,
  Ack_handler =
  fun (LSM, Id) when Id == PkgID ->
        [Pop_handler(__),
         pop_tq_helper(__, Tuple, Q_Tail, NQ)
        ](LSM);
      (LSM, _) ->
        pop_tq_helper(LSM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end,

  ?TRACE(?ID, ">pop_transmission ~p ~p ~p~n", [Flag, Q_Tuple, Tuple]),
  case Q_Tuple of
    {ack, _, _TTL, Dst, Src, QPayload} when Flag == dst_reached ->
      {_, Ack_Pkg_ID} = nl_hf:extract_response(QPayload),
      ?TRACE(?ID, "compare Ack_Pkg_ID ~p PkgID ~p~n", [Ack_Pkg_ID, PkgID]),
      Ack_handler(SM, Ack_Pkg_ID);
    {ack, PkgID, _TTL, Src, Dst, _} ->
      [Pop_handler(__),
       pop_tq_helper(__, Tuple, Q_Tail, NQ)
      ](SM);
    {data, PkgID, _TTL, Dst, Src, _} when Flag == dst_reached; Flag == ack ->
      [Pop_handler(__),
       pop_tq_helper(__, Tuple, Q_Tail, NQ)
      ](SM);
    {Flag, PkgID, _TTL, Src, Dst, Payload} ->
      [Pop_handler(__),
       pop_tq_helper(__, Tuple, Q_Tail, NQ)
      ](SM);
    _ ->
      pop_tq_helper(SM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

clear_sensing_timeout(SM, Tuple) ->
  ?TRACE(?ID, "Clear sensing timeout ~p~n",[Tuple]),
  {_Flag, PkgID, _, Src, Dst, Payload} = Tuple,
  TRefList =
  filter(
   fun({E, TRef}) ->
       case E of
          {sensing_timeout, {data, PkgID, _TTL, Src, Dst, Payload}} ->
            timer:cancel(TRef),
            false;
          {sensing_timeout, {Flag, PkgID, _TTL, Src, Dst, _Payload}} when Flag == ack;
                                                                          Flag == dst_reached ->
            timer:cancel(TRef),
            false;
          {sensing_timeout, {_, PkgID, _TTL, Dst, Src, _Payload}} ->
            timer:cancel(TRef),
            false;
         _  -> true
       end
   end, SM#sm.timeouts),
  SM#sm{timeouts = TRefList}.


remove_retries(SM, Tuple = {Flag, _, TTL, Src, Dst, Payload}) when Flag == ack;
                                                                   Flag == dst_reached ->
  Q = share:get(SM, retries_queue),
  {_, PkgID} = extract_response(Payload),
  [remove_rq_retries(__, {Flag, PkgID, TTL, Src, Dst, Payload}, Q, queue:new()),
   remove_rq_retries(__, Tuple, share:get(SM, retries_queue), queue:new())
  ](SM);
remove_retries(SM, Tuple) ->
  Q = share:get(SM, retries_queue),
  ?TRACE(?ID, "deleted Tuple ~p from retry queue ~p~n",[Tuple, Q]),
  remove_rq_retries(SM, Tuple, Q, queue:new()).

remove_rq_retries(SM, _Tuple, {[],[]}, NQ) ->
  share:put(SM, retries_queue, NQ);
remove_rq_retries(SM, Tuple = {_, PkgID, _, Src, Dst, Payload}, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {_Retries, {data, PkgID, _TTL, Src, Dst, Payload}} ->
      remove_rq_retries(SM, Tuple, Q_Tail, NQ);
    {_Retries, {_, PkgID, _TTL, Src, Dst, _}} ->
      remove_rq_retries(SM, Tuple, Q_Tail, NQ);
    _ ->
      remove_rq_retries(SM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

decrease_retries(SM, Tuple) ->
  Q = share:get(SM, retries_queue),
  ?TRACE(?ID, "Change local tries of packet ~p~n",[Tuple]),
  decrease_rq_helper(SM, Tuple, not_inside, Q, queue:new()).

decrease_rq_helper(SM, Tuple, _, Q = {[],[]}, {[],[]}) ->
  Local_Retries = share:get(SM, retries),
  share:put(SM, retries_queue, queue:in({Local_Retries, Tuple}, Q));
decrease_rq_helper(SM, Tuple, not_inside, {[],[]}, NQ) ->
  Local_Retries = share:get(SM, retries),
  share:put(SM, retries_queue, queue:in({Local_Retries, Tuple}, NQ));
decrease_rq_helper(SM, _Tuple, inside, {[],[]}, NQ) ->
  share:put(SM, retries_queue, NQ);
decrease_rq_helper(SM, Tuple = {Flag, PkgID, _, Src, Dst, Payload}, Inside, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),

  {Retries, {_QFlag, QPkgID, _TTL, QSrc, QDst, QPayload}} = Q_Tuple,
  Pop_queue =
  fun (LSM, Tries) when Tries =< 0 ->
        ?TRACE(?ID, "drop Tuple ~p from  ~p, retries ~p ~n",[Q_Tuple, Q, Tries]),
        [pop_transmission(__, Tuple),
         decrease_rq_helper(__, Tuple, inside, Q_Tail, NQ)
        ](LSM);
      (LSM, Tries) when Tries > 0 ->
        ?TRACE(?ID, "change Tuple ~p in  ~p, retries ~p ~n",[Q_Tuple, Q, Tries - 1]),
        decrease_rq_helper(LSM, Tuple, inside, Q_Tail, queue:in({Tries - 1, Tuple}, NQ))
  end,

  Flag_handler =
  fun (LSM, data) when QPkgID == PkgID, QSrc == Src, QDst == Dst, QPayload == Payload ->
        Pop_queue(LSM, Retries);
      (LSM, _) when QPkgID == PkgID, QSrc == Src, QDst == Dst ->
        Pop_queue(LSM, Retries);
      (LSM, _) ->
        decrease_rq_helper(LSM, Tuple, Inside, Q_Tail, queue:in(Q_Tuple, NQ))
  end,

  Flag_handler(SM, Flag).

decrease_TTL(SM) ->
  Q = share:get(SM, transmission_queue),
  ?INFO(?ID, "decrease TTL for every packet in the queue ~p ~n",[Q]),
  decrease_TTL_tq(SM, Q, queue:new()).

decrease_TTL_tq(SM, {[],[]}, NQ) ->
  share:put(SM, transmission_queue, NQ);
decrease_TTL_tq(SM, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  {Flag, PkgID, QTTL, Src, Dst, Payload} = Q_Tuple,

  TTL_handler =
  fun (LSM, dst_reached, _) ->
        decrease_TTL_tq(LSM, Q_Tail, queue:in(Q_Tuple, NQ));
      (LSM, _, TTL) when TTL > 0 ->
        Tuple = {Flag, PkgID, TTL, Src, Dst, Payload},
        decrease_TTL_tq(LSM, Q_Tail, queue:in(Tuple, NQ));
      (LSM, _, TTL) when TTL =< 0 ->
        ?INFO(?ID, "decrease and drop ~p, TTL ~p =< 0 ~n",[Q_Tuple, TTL]),
        [clear_sensing_timeout(__, Q_Tuple),
         decrease_TTL_tq(__, Q_Tail, NQ)
        ](LSM)
  end,

  TTL_handler(SM, Flag, QTTL - 1).

exists_received(SM, Tuple) ->
  exists_rq_response(SM, Tuple, share:get(SM, received_queue)).

exists_rq_response(Tuple) -> Tuple.
exists_rq_response(SM, Tuple, {[],[]}) ->
  exists_rq_ttl(SM, Tuple, share:get(SM, received_queue));
exists_rq_response(SM, Tuple = {Flag, PkgID, _, Src, Dst, Payload}, Q) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  PkgID_handler =
  fun (Id1, Id2) when Id1 == Id2 ->
        exists_rq_response({true, dst_reached});
      (_, _) ->
        exists_rq_response(SM, Tuple, Q_Tail)
  end,
  case Q_Tuple of
    {dst_reached, _, _QTTL, Dst, Src, QPayload} when Flag == data ->
      {_, Dst_Reached_PkgID} = extract_response(QPayload),
      ?TRACE(?ID, "exists_rq_response ~p and ~p: parsed ~p, recv ~p ~n",
        [Q_Tuple, Tuple, Dst_Reached_PkgID, PkgID]),
      PkgID_handler(PkgID, Dst_Reached_PkgID);
    {dst_reached, _, _QTTL, Dst, Src, QPayload} when Flag == ack ->
      {_, Dst_Reached_PkgID} = extract_response(QPayload),
      {_, Ack_PkgID} = extract_response(Payload),
      ?TRACE(?ID, "exists_rq_response ~p and ~p: parsed ~p, recv ~p ~n",
        [Q_Tuple, Tuple, Dst_Reached_PkgID, Ack_PkgID]),
      PkgID_handler(Dst_Reached_PkgID, Ack_PkgID);
    _ ->
      exists_rq_response(SM, Tuple, Q_Tail)
  end.

exists_rq_ttl(Tuple) ->
  Tuple.
exists_rq_ttl(_SM, _Tuple, {[],[]}) ->
  {false, 0};
exists_rq_ttl(SM, Tuple = {_, PkgID, _TTL, Src, Dst, Payload}, Q) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {data, PkgID, QTTL, Src, Dst, Payload} ->
      exists_rq_ttl({true, QTTL});
    {ack, PkgID, QTTL, Src, Dst, _} ->
      exists_rq_ttl({true, QTTL});
    _ ->
      exists_rq_ttl(SM, Tuple, Q_Tail)
  end.

update_received_TTL(SM, Tuple) ->
  Q = share:get(SM, received_queue),
  update_TTL_rq_helper(SM, Tuple, Q, queue:new()).

update_TTL_rq_helper(SM, Tuple, {[],[]}, NQ) ->
  ?INFO(?ID, "change TTL for Tuple ~p in the~n",[Tuple]),
  share:put(SM, received_queue, NQ);
update_TTL_rq_helper(SM, Tuple = {Flag, PkgID, TTL, Src, Dst, Payload}, Q, NQ) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),

  {QFlag, QPkgID, QTTL, QSrc, QDst, QPayload} = Q_Tuple,

  TTL_handler =
  fun (LSM, true, data) when PkgID == QPkgID, Src == QSrc,
                             Dst == QDst, Payload == QPayload ->
        NT = {Flag, PkgID, TTL, Src, Dst, Payload},
        update_TTL_rq_helper(LSM, Tuple, Q_Tail, queue:in(NT, NQ));
      (LSM, true, ack) when PkgID == QPkgID, Src == QSrc, Dst == QDst ->
        NT = {Flag, PkgID, TTL, Src, Dst, Payload},
        update_TTL_rq_helper(LSM, Tuple, Q_Tail, queue:in(NT, NQ));
      (LSM, _, _) ->
        update_TTL_rq_helper(LSM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end,

  TTL_handler(SM, TTL < QTTL, QFlag).
%%----------------------------Converting NL -------------------------------
%TOD0:!!!!
% return no_address, if no info
nl2mac_address(?ADDRESS_MAX) -> 255;
nl2mac_address(Address) -> Address.
mac2nl_address(255) -> ?ADDRESS_MAX;
mac2nl_address(Address) -> Address.

flag2num(Flag) when is_atom(Flag)->
  integer_to_binary(?FLAG2NUM(Flag)).

num2flag(Num, Layer) when is_integer(Num)->
  ?NUM2FLAG(Num, Layer);
num2flag(Num, Layer) when is_binary(Num)->
  ?NUM2FLAG(binary_to_integer(Num), Layer).

%%----------------------------Routing helper functions -------------------------------
find_routing(?ADDRESS_MAX, _) -> ?ADDRESS_MAX;
find_routing(_, ?ADDRESS_MAX) -> ?ADDRESS_MAX;
find_routing([], _) -> no_routing_table;
find_routing(Routing, Address) ->
  find_routing_helper(Routing, Address, nothing).

find_routing_helper(Address) -> Address.
find_routing_helper([], _Address, nothing) ->
  ?ADDRESS_MAX;
find_routing_helper([], _Address, Default) ->
  Default;
find_routing_helper([H | T], Address, Default) ->
  case H of
    {Address, To} -> find_routing_helper(To);
    Default_address when not is_tuple(Default_address) ->
      find_routing_helper(T, Address, Default_address);
    _ -> find_routing_helper(T, Address, Default)
  end.

%get_routing_address(_SM, _Flag, _Address) -> 255.
get_routing_address(SM, Address) ->
  Routing = share:get(SM, nothing, routing_table, []),
  find_routing(Routing, Address).
  %nl2mac_address(RAddress).
%%----------------------------Parse NL functions -------------------------------
fill_protocol_info_header(dst_reached, {Transmit_Len, Data}) ->
  fill_data_header(Transmit_Len, Data);
fill_protocol_info_header(data, {Transmit_Len, Data}) ->
  fill_data_header(Transmit_Len, Data);
fill_protocol_info_header(ack, {Transmit_Len, Data}) ->
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
create_nl_at_command(SM, NL) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_address = share:get(SM, local_address),

  {Flag, PkgID, TTL, Src, Dst, NL_Payload} = NL,

  % TODO: Additional_Info, different protocols have difeferent Header
  Transmit_Len = byte_size(NL_Payload),
  Payload = fill_protocol_info_header(Flag, {Transmit_Len, NL_Payload}),
  ?INFO(?ID, "create_nl_at_command ~p ~p ~p Payload ~p ~n", [Flag, Transmit_Len, NL_Payload, Payload]),

  NL_Info = {Flag, PkgID, TTL, Src, Dst, Payload},

  Route_Addr = get_routing_address(SM, Dst),
  MAC_Route_Addr = nl2mac_address(Route_Addr),

  ?TRACE(?ID, "MAC_Route_Addr ~p, Route_Addr ~p Src ~p, Dst ~p~n", [MAC_Route_Addr, Route_Addr, Src, Dst]),

  if ((MAC_Route_Addr =:= error) or
      ((Dst =:= ?ADDRESS_MAX) and Protocol_Config#pr_conf.br_na)) ->
      error;
  true ->
      AT = nl2at(SM, MAC_Route_Addr, NL_Info),
      Current_RTT = {rtt, Local_address, Dst},
      ?TRACE(?ID, "Current RTT ~p sending AT command ~p~n", [Current_RTT, AT]),
      fill_dets(SM, PkgID, Src, Dst),
      AT
  end.

extract_payload_nl(SM, Payload) ->
  {Pid, Flag_Num, Pkg_ID, TTL, NL_Src, NL_Dst, Tail} =
    extract_payload_nl_header(SM, Payload),
  Flag = num2flag(Flag_Num, nl),
  % TODO: split path data
  Splitted_Payload =
  case Flag of
    Flag when Flag == data; Flag == ack; Flag == dst_reached ->
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

extract_response(Payload) ->
  C_Bits_PkgID = count_flag_bits(?PKG_ID_MAX),
  C_Bits_Hops = count_flag_bits(?MAX_LEN_PATH),
  <<Hops:C_Bits_Hops, Pkg_ID:C_Bits_PkgID, _Rest/bitstring>> = Payload,
  {Hops, Pkg_ID}.

create_response(SM, dst_reached, Pkg_ID, Src, Dst, Hops) ->
  create_response(SM, dst_reached, Pkg_ID, Src, Dst, 0, Hops);
create_response(SM, ack, Pkg_ID, Src, Dst, Hops) ->
  Max_ttl = share:get(SM, ttl),
  create_response(SM, ack, Pkg_ID, Src, Dst, Max_ttl, Hops).

recreate_response(SM, ack, Tuple) ->
  {Flag, Pkg_ID, TTL, Src, Dst, Payload} = Tuple,
  {Hops, Ack_Pkg_ID} = extract_response(Payload),
  Coded_payload = encode_response(Hops + 1, Ack_Pkg_ID),
  ?TRACE(?ID, "recreate_response ~p Hops ~p ~p ~p ~p~n", [Flag, Hops, Ack_Pkg_ID, Tuple, Coded_payload]),
  {Flag, Pkg_ID, TTL, Src, Dst, Coded_payload}.

create_response(SM, Type, Pkg_ID, Src, Dst, TTL, Hops) ->
  Coded_payload = encode_response(Hops, Pkg_ID),
  Incereased_Pkg_ID = increase_pkgid(SM, Dst, Src),
  {Type, Incereased_Pkg_ID, TTL, Dst, Src, Coded_payload}.

encode_response(Hops, Pkg_ID) ->
  C_Bits_PkgID = count_flag_bits(?PKG_ID_MAX),
  C_Bits_Hops = count_flag_bits(?MAX_LEN_PATH),
  B_Hops = <<Hops:C_Bits_Hops>>,
  B_PkgID = <<Pkg_ID:C_Bits_PkgID>>,

  Tmp_Data = <<B_Hops/bitstring, B_PkgID/bitstring>>,
  Data_Bin = is_binary(Tmp_Data) =:= false or ( (bit_size(Tmp_Data) rem 8) =/= 0),
  if Data_Bin =:= false ->
    Add = (8 - bit_size(Tmp_Data) rem 8) rem 8,
    <<B_Hops/bitstring, B_PkgID/bitstring, 0:Add>>;
  true ->
    Tmp_Data
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

      Ids = lists:map(fun({_, S, D}) when S == Src, D == Dst -> {PkgID, S, D}; (T) -> T end, LIds),
      dets:insert(Ref, {Protocol_Name, Ids});
    _ -> nothing
  end,

  Ref1 = SM#sm.dets_share,
  B = dets:lookup(Ref1, Protocol_Name),
  ?INFO(?ID, "Fill dets for local address ~p ~p ~p ~n", [Local_Address, B, PkgID] ),
  SM#sm{dets_share = Ref1}.

%%------------------------- Math Helper functions ----------------------------------
rand_float(SM, Random_interval) ->
  {Start, End} = share:get(SM, Random_interval),
  (Start + rand:uniform() * (End - Start)) * 1000.

count_flag_bits (F) ->
count_flag_bits_helper(F, 0).

count_flag_bits_helper(0, 0) -> 1;
count_flag_bits_helper(0, C) -> C;
count_flag_bits_helper(F, C) ->
  Rem = F rem 2,
  D =
  if Rem =:= 0 -> F / 2;
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
  PkgID =
  case share:get(SM, {packet_id, Src, Dst}) of
    nothing -> 0; %rand:uniform(Max_Pkg_ID);
    Prev_ID when Prev_ID >= Max_Pkg_ID -> 0;
    (Prev_ID) -> Prev_ID + 1
  end,
  ?TRACE(?ID, "Increase Pkg Id LA ~p: packet_id ~p~n", [share:get(SM, local_address), PkgID]),
  share:put(SM, {packet_id, Src, Dst}, PkgID),
  PkgID.

add_neighbours(SM, Src, {Rssi, Integrity}) ->
  ?INFO(?ID, "Add neighbour Src ~p, Rssi ~p Integrity ~p ~n", [Src, Rssi, Integrity]),
  N_Channel = share:get(SM, neighbours_channel),
  Time = erlang:monotonic_time(milli_seconds) - share:get(SM, nl_start_time),
  Neighbours = share:get(SM, current_neighbours),
  case lists:member(Src, Neighbours) of
    _ when N_Channel == nothing ->
      [share:put(__, neighbours_channel, [{Src, Rssi, Integrity, Time}]),
       share:put(__, current_neighbours, [Src])
      ](SM);
    true ->
      Key = lists:keyfind(Src, 1, N_Channel),
      {_, Stored_Rssi, Stored_Integrity, _} = Key,
      Aver_Rssi = get_average(Rssi, Stored_Rssi),
      Aver_Integrity = get_average(Integrity, Stored_Integrity),
      NNeighbours = lists:delete(Key, N_Channel),
      C_Tuple = {Src, Aver_Rssi, Aver_Integrity, Time},
      [share:put(__, neighbours_channel, [C_Tuple | NNeighbours]),
       share:put(__, current_neighbours, Neighbours)
      ](SM);
    false ->
      C_Tuple = {Src, Rssi, Integrity, Time},
      [share:put(__, neighbours_channel, [C_Tuple | N_Channel]),
       share:put(__, current_neighbours, [Src | Neighbours])
      ](SM)
  end.

%%--------------------------------------------------  command functions -------------------------------------------
update_states(SM) ->
  Q = share:get(SM, last_states),
  Max = 50,
  QP =
  case queue:len(Q) of
    Len when Len >= Max ->
      queue:in({SM#sm.state, SM#sm.event}, queue:drop(Q));
    _ ->
      queue:in({SM#sm.state, SM#sm.event}, Q)
  end,
  share:put(SM, last_states, QP).

process_set_command(SM, Command) ->
  Protocol_Name = share:get(SM, protocol_name),
  Cast =
  case Command of
    {address, Address} when is_integer(Address) ->
      share:put(SM, local_address, Address),
      {nl, address, Address};
    {address, _Address} ->
      {nl, address, error};
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
          [share:put(__, current_neighbours, []),
           share:put(__, neighbours_channel, [])
          ](SM);
        [H|_] when is_integer(H) ->
          [share:put(__, current_neighbours, Neighbours),
           share:put(__, neighbours_channel, Neighbours)
          ](SM);
        _ ->
          Time = erlang:monotonic_time(milli_seconds),
          N_Channel = [ {A, I, R, Time - T } || {A, I, R, T} <- Neighbours],
          [share:put(__, neighbours_channel, N_Channel),
           share:put(__, current_neighbours, [ A || {A, _, _, _} <- Neighbours])
          ](SM)
      end,
      {nl, neighbours, Neighbours};
    {neighbours, _Neighbours} ->
      {nl, neighbours, error};
    {routing, Routing} ->
      Routing_Format = lists:map(
                        fun({default, To}) -> To;
                            (Other) -> Other
                        end, Routing),
      share:put(SM, routing_table, Routing_Format),
      {nl, routing, Routing};
    _ ->
      {nl, error}
  end,
  fsm:cast(SM, nl_impl, {send, Cast}).

from_start(_SM, Time) when Time == empty -> 0;
from_start(SM, Time) -> Time - share:get(SM, nl_start_time).

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

delete_neighbour(SM, Address) ->
  Neighbours = share:get(SM, current_neighbours),
  N_Channel = share:get(SM, neighbours_channel),
  Routing_handler =
    fun (LSM, ?ADDRESS_MAX) -> LSM;
        (LSM, Routing_table) ->
          NRouting_table =
          lists:filtermap(fun(X) ->
                case X of
                  {_, Address} -> false;
                  Address -> false;
                  _ -> {true, X}
          end end, Routing_table),
          share:put(LSM, routing_table, NRouting_table)
    end,

  Channel_handler =
    fun(LSM, false) ->
        PN_Channel = lists:delete(Address, N_Channel),
        share:put(LSM, neighbours_channel, PN_Channel);
       (LSM, Element) ->
        PN_Channel = lists:delete(Element, N_Channel),
        share:put(LSM, neighbours_channel, PN_Channel)
    end,

  Neighbour_handler =
    fun(LSM, true) ->
        PNeighbours = lists:delete(Address, Neighbours),

        [share:put(__, current_neighbours, PNeighbours),
         Routing_handler(__, share:get(SM, routing_table)),
         Channel_handler(__, lists:keyfind(Address, 1, N_Channel))
        ] (LSM);
       (LSM, false) ->
        LSM
    end,

  Neighbour_handler(SM, lists:member(Address, Neighbours)).

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
%-------------------------- Statistics helper functions---------------------------
fill_statistics(SM, _Type, Src) ->
  Q = share:get(SM, statistics_neighbours),
  Time = erlang:monotonic_time(milli_seconds),

  Counter_handler =
  fun (LSM, true) ->
        Tuple = {Src, Time, 1},
        [share:put(__, statistics_neighbours, queue:in(Tuple, Q)),
         share:put(__, neighbours_counter, 1)
        ](LSM);
      (LSM, false) ->
        Total = share:get(SM, neighbours_counter),
        [share:put(__, neighbours_counter, Total + 1),
         fill_sq_helper(__, Src, not_inside, Q, queue:new())
        ](LSM)
  end,
  Counter_handler(SM, queue:is_empty(Q)).

fill_statistics(SM, {dst_reached, _, _, _, _, _}) ->
  SM;
fill_statistics(SM, {ack, _, _, NL_Src, NL_Dst, Payload}) ->
  {Hops, Ack_Pkg_ID} = extract_response(Payload),
  Ack_tuple = {Ack_Pkg_ID, NL_Dst, NL_Src},
  fill_statistics(SM, ack, delivered, Hops, Ack_tuple);
fill_statistics(SM, Tuple) ->
  Local_Address = share:get(SM, local_address),
  Q = share:get(SM, statistics_queue),
  {_, _, _, Src, Dst, _} = Tuple,

  Role_handler =
  fun (A) when Src == A -> source;
      (A) when Dst == A; Dst == ?ADDRESS_MAX -> destination;
      (_A) -> relay
  end,

  ?INFO(?ID, "fill_sq_helper ~p~n", [Tuple]),
  Role = Role_handler(Local_Address),
  fill_sq_helper(SM, Role, Tuple, not_inside, Q, queue:new()).

fill_statistics(SM, ack, State, Hops, Tuple) ->
  Time = erlang:monotonic_time(milli_seconds),
  Q = share:get(SM, statistics_queue),
  fill_sq_ack(SM, State, Hops, Time, Tuple, not_inside, Q, queue:new()).

fill_sq_ack(SM, _State, _Hops, _Time, _Ack_tuple, not_inside,  {[],[]}, _NQ) ->
  SM;
fill_sq_ack(SM, _State, _Hops, _Time, _Ack_tuple, inside,  {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
fill_sq_ack(SM, State, Hops, Time, Ack_tuple, Inside, Q, NQ) ->
  {PkgID, Src, Dst} = Ack_tuple,
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {STime, RTime, Role, _, _, _,
     Tuple = {_, PkgID, _, Src, Dst, _}} when State == delivered_on_src ->
      PQ = queue_push(NQ, {STime, RTime, Role, Time, delivered, Hops, Tuple}, ?Q_STATISTICS_SIZE),
      fill_sq_ack(SM, State, Hops, Time, Ack_tuple, inside, Q_Tail, PQ);
    {STime, RTime, Role, _, no_info, 0,
     Tuple = {_, PkgID, _, Src, Dst, _}} ->
      PQ = queue_push(NQ, {STime, RTime, Role, Time, State, Hops, Tuple}, ?Q_STATISTICS_SIZE),
      fill_sq_ack(SM, State, Hops, Time, Ack_tuple, inside, Q_Tail, PQ);
    _ ->
      PQ = queue_push(NQ, Q_Tuple, ?Q_STATISTICS_SIZE),
      fill_sq_ack(SM, State, Hops, Time, Ack_tuple, Inside, Q_Tail, PQ)
  end.

fill_sq_helper(SM, Src, not_inside, {[],[]}, NQ) ->
  Time = erlang:monotonic_time(milli_seconds),
  share:put(SM, statistics_neighbours, queue:in({Src, Time, 1}, NQ));
fill_sq_helper(SM, _Src, inside, {[],[]}, NQ) ->
  share:put(SM, statistics_neighbours, NQ);
fill_sq_helper(SM, Src, Inside, Q, NQ) ->
  Time = erlang:monotonic_time(milli_seconds),
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {Src, _, Count} ->
      PQ = queue:in({Src, Time, Count + 1}, NQ),
      fill_sq_helper(SM, Src, inside, Q_Tail, PQ);
    _ ->
      PQ = queue:in(Q_Tuple, NQ),
      fill_sq_helper(SM, Src, Inside, Q_Tail, PQ)
  end.
fill_sq_helper(SM, _Role, _Tuple, inside, {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
fill_sq_helper(SM, Role, Tuple, not_inside, {[],[]}, NQ) ->
  PQ = queue_push(NQ, {empty, empty, Role, 0, no_info, 0, Tuple}, ?Q_STATISTICS_SIZE),
  share:put(SM, statistics_queue, PQ);
fill_sq_helper(SM, Role, Tuple, Inside, Q, NQ) ->
  {Flag, PkgID, TTL, Src, Dst, Payload} = Tuple,
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {_, _, _, _, _, _, {Flag, PkgID, STTL, Src, Dst, Payload}} when TTL < STTL ->
      PQ = queue_push(NQ, {empty, empty, Role, 0, no_info, 0, Tuple}, ?Q_STATISTICS_SIZE),
      fill_sq_helper(SM, Role, Tuple, inside, Q_Tail, PQ);
    _ ->
      PQ = queue_push(NQ, Q_Tuple, ?Q_STATISTICS_SIZE),
      fill_sq_helper(SM, Role, Tuple, Inside, Q_Tail, PQ)
  end.

set_processing_time(SM, Type, Tuple) ->
  Q = share:get(SM, statistics_queue),
  set_pt_helper(SM, Type, Tuple, Q, queue:new()).

set_pt_helper(SM, _Type, _Tuple, {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
set_pt_helper(SM, Type, Tuple, Q, NQ) ->
  {Flag, PkgID, _, Src, Dst, Payload} = Tuple,
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Current_Time = erlang:monotonic_time(milli_seconds),

  Push_queue =
  fun (LSM, PTuple) ->
      PQ = queue_push(NQ, PTuple, ?Q_STATISTICS_SIZE),
      set_pt_helper(LSM, Type, Tuple, Q_Tail, PQ)
  end,

  case Q_Tuple of
    {_Send_Time, Recv_Time, _Role, Duration, State, Hops,
      {Stored_Flag, Stored_PkgID, TTL, Dst, Src, Stored_Payload}} when Type == transmitted,
                                                                       Flag == dst_reached ->
      PkgID_handler =
      fun ({_, Id}) when Stored_PkgID == Id ->
            NL_Recv_Tuple = {Stored_Flag, PkgID, TTL, Src, Dst, Stored_Payload},
            Statistic = {Current_Time, Recv_Time, destination, Duration, State, Hops, NL_Recv_Tuple},
            Push_queue(SM, Statistic);
          (_) ->
            Push_queue(SM, Q_Tuple)
      end,
      PkgID_handler(extract_response(Payload));
    {_Send_Time, Recv_Time, Role, Duration, State, Hops,
      {Flag, PkgID, _TTL, Src, Dst, Payload}} when Type == transmitted ->
      Statistic = {Current_Time, Recv_Time, Role, Duration, State, Hops, Tuple},
      Push_queue(SM, Statistic);
    {Send_Time, _Recv_Time, Role, Duration, State, Hops,
      {Flag, PkgID, _TTL, Src, Dst, Payload}} when Type == received,
                                                   Flag =/= dst_reached ->
      Statistic = {Send_Time, Current_Time, Role, Duration, State, Hops, Tuple},
      Push_queue(SM, Statistic);
    _ ->
      Push_queue(SM, Q_Tuple)
  end.

process_get_command(SM, Command) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol = share:get(SM, protocol_config, Protocol_Name),
  N_Channel = share:get(SM, neighbours_channel),
  Statistics = share:get(SM, statistics_queue),
  Statistics_Empty = queue:is_empty(Statistics),

  Cast =
  case Command of
    protocols ->
      {nl, Command, ?LIST_ALL_PROTOCOLS};
    states ->
      States = queue:to_list(share:get(SM, last_states)),
      {nl, states, States};
    state ->
      {nl, state, {SM#sm.state, SM#sm.event}};
    address ->
      {nl, address, share:get(SM, local_address)};
    neighbours when N_Channel == nothing;
                    N_Channel == [] ->
      {nl, neighbours, empty};
    neighbours ->
      {nl, neighbours, N_Channel};
    routing ->
      {nl, routing, routing_to_list(SM)};
    {protocolinfo, Name} ->
      {nl, protocolinfo, Name, get_protocol_info(SM, Name)};
    {statistics, paths} when Protocol#pr_conf.pf ->
      %TODO, implement protocols pf
      Paths =
        lists:map(fun({{Role, Path}, Duration, Count, TS}) ->
                      {Role, Path, Duration, Count, TS}
                  end, queue:to_list(share:get(SM, paths))),
      Answer = case Paths of []  -> empty; _ -> Paths end,
      {nl, statistics, paths, Answer};
    {statistics, paths} ->
      {nl, statistics, paths, error};
    {statistics, neighbours} ->
      Total = share:get(SM, neighbours_counter),
      Neighbours =
        lists:map(fun({Address, Time, Count}) ->
                    Duration = from_start(SM, Time),
                    {Address,Duration,Count,Total}
                  end, queue:to_list(share:get(SM, nothing, statistics_neighbours, empty))),
      Answer = case Neighbours of []  -> empty; _ -> Neighbours end,
      {nl, statistics, neighbours, Answer};
    {statistics, data} when Protocol#pr_conf.ack, not Statistics_Empty ->
      Duration_handler =
        fun (source, Timestamp, Duration) when Timestamp =/= 0 ->
              Duration / 1000;
            (_, _, _) -> 0.00
        end,
      Data =
        lists:map(fun({STimestamp, _RTimestamp, Role, DTimestamp, State, Hops, Tuple}) ->
                      {_Flag, _PkgID, _TTL, Src, Dst, Payload} = Tuple,
                      Send_Time = from_start(SM, STimestamp),
                      Ack_time = from_start(SM, DTimestamp),
                      Duration = Duration_handler(Role, DTimestamp, Ack_time - Send_Time),
                      Len = byte_size(Payload),
                      <<Hash:16, _/binary>> = crypto:hash(md5,Payload),
                      {Role, Hash, Len, Duration, State, Src, Dst, Hops}
                  end, queue:to_list(Statistics)),
      Answer = case Data of []  -> empty; _ -> Data end,
      {nl, statistics, data, Answer};
    {statistics, data} when not Statistics_Empty ->
      Data =
        lists:map(fun({STimestamp, RTimestamp, Role, _DTimestamp, _State, _Hops, Tuple}) ->
                      {_Flag, _PkgID, TTL, Src, Dst, Payload} = Tuple,
                      Send_Time = from_start(SM, STimestamp),
                      Recv_Time = from_start(SM, RTimestamp),
                      Len = byte_size(Payload),
                      <<Hash:16, _/binary>> = crypto:hash(md5,Payload),
                      {Role, Hash, Len, Send_Time, Recv_Time, Src, Dst, TTL}
                  end, queue:to_list(Statistics)),
      Answer = case Data of []  -> empty; _ -> Data end,
      {nl, statistics, data, Answer};
    {statistics, data} ->
      {nl, statistics, data, empty};
    {delete, neighbour, Address} ->
      delete_neighbour(SM, Address),
      {nl, neighbour, ok};
    _ ->
      {nl, error}
  end,
  fsm:cast(SM, nl_impl, {send, Cast}).
