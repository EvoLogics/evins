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
-export([extract_payload_nl_header/2, clear_spec_timeout/2]).
-export([mac2nl_address/1, num2flag/2, add_neighbours/3, list_push/4]).
-export([head_transmission/1, exists_received/2, update_received_TTL/2,
         pop_transmission/3, pop_transmission/2, decrease_TTL/1, delete_neighbour/2]).
-export([init_dets/1, fill_dets/4, get_event_params/2, set_event_params/2, clear_event_params/2, clear_spec_event_params/2]).
-export([add_event_params/2, find_event_params/3, find_event_params/2]).
-export([nl2mac_address/1, get_routing_address/2, nl2at/3, get_at_dst/1, flag2num/1, queue_push/4, queue_push/3]).
-export([decrease_retries/2, rand_float/2, update_states/1, count_flag_bits/1]).
-export([create_response/8, create_ack_path/9, recreate_response/5, extract_response/1, extract_response/2, prepare_path/5,
         recreate_path_evo/5, recreate_path_neighbours/2, update_stable_path/5, get_prev_neighbour/2]).
-export([process_set_command/2, process_get_command/2, set_processing_time/3,fill_statistics/2, fill_statistics/3, fill_statistics/5]).
-export([update_path/2, update_routing/2, update_received/2, routing_exist/2, routing_to_list/1]).
-export([getv/2, geta/1, replace/3, drop_postponed/2]).
-export([add_to_paths/7, get_stable_path/4, get_stable_path/3, remove_old_paths/3, if_path_packet/1,has_path_packets/3, check_tranmission_path/2]).
-export([check_binary/1, add_bits/1, cut_add_bits/2, cut_add_bits/1, process_async_status/1]).

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
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  TTL = share:get(SM, ttl),
  Local_address = share:get(SM, local_address),
  {nl, send, Dst, Payload} = Tuple,
  PkgID = increase_pkgid(SM, Local_address, Dst),

  Flag = data,
  Src = Local_address,
  Path = [Src],

  ?TRACE(?ID, "Code Send Tuple Flag ~p, PkgID ~p, TTL ~p, Src ~p, Dst ~p~n",
              [Flag, PkgID, TTL, Src, Dst]),

  if (((Dst =:= ?ADDRESS_MAX) and Protocol_Config#pr_conf.br_na)) ->
      {PkgID, error};
  true ->
      DTuple = create_default(SM),
      MType = specify_mtype(Protocol_Name, Flag),

      RTuple =
      replace(
        [flag, id, ttl, src, dst, mtype, path, payload],
        [Flag, PkgID, TTL, Src, Dst, MType, Path, Payload], DTuple),
      {PkgID, RTuple}
  end.

specify_mtype(icrpr, data) -> path_data;
specify_mtype(_, _) -> data.

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
  Q = share:get(SM, nothing, Qname, queue:new()),
  QP = queue_push(Q, Item, Max),
  share:put(SM, Qname, QP).

queue_push(Q, Item, Max) ->
  Q_Member = queue:member(Item, Q),
  case queue:len(Q) of
    Len when Len >= Max, not Q_Member ->
      queue:in(Item, queue:drop(Q));
    _ when not Q_Member ->
      queue:in(Item, Q);
    _ -> Q
  end.


%--------------------------------- Get from tuple -------------------------------------------
geta(Tuple) ->
  getv([flag, id, ttl, src, dst, mtype, path, rssi, integrity, min_integrity, neighbours, payload], Tuple).
getv(_, empty) -> nothing;
getv(Types, Tuple) when is_list(Types) ->
  lists:foldr(fun(Type, L) -> [getv(Type, Tuple) | L] end, [], Types);
getv(Type, Tuple) when is_atom(Type) ->
  PT =
  case Tuple of {_Retries, T} -> T; _-> Tuple end,
  {Flag, PkgID, TTL, Src, Dst, MType, Path, Rssi, Integrity, Min_integrity, Neighbours, Payload} = PT,

  Structure =
  [{flag, Flag}, {id, PkgID}, {ttl, TTL}, {src, Src}, {dst, Dst},
   {mtype, MType}, {path, Path}, {rssi, Rssi}, {integrity, Integrity},
   {min_integrity, Min_integrity}, {neighbours, Neighbours}, {payload, Payload}
  ],
  Map = maps:from_list(Structure),
  {ok, Val} = maps:find(Type, Map),
  Val.

create_default(SM) ->
  Max_ttl = share:get(SM, ttl),
  {data, 0, Max_ttl, 0, 0, data, [], 0, 0, 0, [], <<"">>}.

replace(Types, Values, Tuple) when is_list(Types) ->
  replace_helper(Types, Values, Tuple);
replace(Type, Value, Tuple) when is_atom(Type) ->
  {Flag, PkgID, TTL, Src, Dst, MType, Path, Rssi, Integrity, Min_integrity, Neighbours, Payload} = Tuple,
  Structure =
  [{flag, Flag}, {id, PkgID}, {ttl, TTL}, {src, Src}, {dst, Dst},
   {mtype, MType}, {path, Path}, {rssi, Rssi}, {integrity, Integrity},
   {min_integrity, Min_integrity}, {neighbours, Neighbours}, {payload, Payload}
  ],
  list_to_tuple(lists:foldr(
  fun({X, _V}, L) when X == Type -> [Value | L];
     ({_X, V}, L) ->  [V | L]
  end, [], Structure)).

replace_helper([], _, Tuple) -> Tuple;
replace_helper([Type | Types], [Value | Values], Tuple) ->
  replace_helper(Types, Values, replace(Type, Value, Tuple)).

%--------------------------------- Rules to handle messages -------------------------------------------
is_response(SM, Tuple1, Tuple2) ->
  Flag1 = getv(flag, Tuple1),
  Flag2 = getv(flag, Tuple2),
  is_response(SM, Flag1, Flag2, Tuple1, Tuple2).

is_same(SM, Tuple1, Tuple2) ->
  Flag1 = getv(flag, Tuple1),
  Flag2 = getv(flag, Tuple2),
  is_same(SM, Flag1, Flag2, Tuple1, Tuple2).

is_same(_, data, data, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1, Payload1] =
    getv([id, src, dst, mtype, payload], Tuple1),
  [PkgID2, Src2, Dst2, MType2, Payload2] =
    getv([id, src, dst, mtype, payload], Tuple2),
  (PkgID1 == PkgID2) and (Src1 == Src2) and (Dst1 == Dst2)
  and (MType1 == MType2) and (Payload1 == Payload2);
is_same(_, ack, ack, Tuple1, Tuple2) ->
  MType1 = getv(mtype, Tuple1),
  MType2 = getv(mtype, Tuple2),
  is_same(ack, ack, MType1, MType2, Tuple1, Tuple2);
is_same(_, dst_reached, dst_reached, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1] =
    getv([id, src, dst, mtype], Tuple1),
  [PkgID2, Src2, Dst2, MType2] =
    getv([id, src, dst, mtype], Tuple2),
  (PkgID1 == PkgID2) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2);
is_same(_, path, path, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1] =
    getv([id, src, dst, mtype], Tuple1),
  [PkgID2, Src2, Dst2, MType2] =
    getv([id, src, dst, mtype], Tuple2),
  (PkgID1 == PkgID2) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2);
is_same(_, _, _, _, _) ->
  false.

is_response(SM, data, data, Tuple1, Tuple2) ->
  is_same(SM, data, data, Tuple1, Tuple2);
is_response(SM, ack, ack, Tuple1, Tuple2) ->
  is_same(SM, ack, ack, Tuple1, Tuple2);
is_response(SM, dst_reached, dst_reached, Tuple1, Tuple2) ->
  is_same(SM, dst_reached, dst_reached, Tuple1, Tuple2);
is_response(SM, path, path, Tuple1, Tuple2) ->
  is_same(SM, path, path, Tuple1, Tuple2);
is_response(SM, data, dst_reached, Tuple1, Tuple2) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Ack_protocol = Protocol_Config#pr_conf.ack,
  is_response(SM, Ack_protocol, data, dst_reached, Tuple1, Tuple2);
is_response(_, ack, dst_reached, Tuple1, Tuple2) ->
  [Src1, Dst1, MType1, Payload1] =
    getv([src, dst, mtype, payload], Tuple1),
  [Src2, Dst2, MType2, Payload2] =
    getv([src, dst, mtype, payload], Tuple2),
  [Ack_Pkg_ID, Hash1] = nl_hf:extract_response([id, hash], Payload1),
  [Dst_Pkg_ID, Hash2] = nl_hf:extract_response([id, hash], Payload2),
  (Ack_Pkg_ID == Dst_Pkg_ID) and (Src1 == Dst2)
  and (Src2 == Dst1) and (MType1 == MType2)
  and (Hash1 == Hash2);
is_response(_, data, ack, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1, Payload1] =
    getv([id, src, dst, mtype, payload], Tuple1),
  [Src2, Dst2, MType2, Payload2] =
    getv([src, dst, mtype, payload], Tuple2),
  <<Hash1:16, _/binary>> = crypto:hash(md5, Payload1),
  [Ack_Pkg_ID, Hash2] = nl_hf:extract_response([id, hash], Payload2),
  (PkgID1 == Ack_Pkg_ID) and (Src1 == Dst2)
  and (Dst1 == Src2) and (MType1 == MType2)
  and (Hash1 == Hash2);
is_response(_, path, ack, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1] =
    getv([id, src, dst, mtype], Tuple1),
  [Src2, Dst2, MType2, Payload2] =
    getv([src, dst, mtype, payload], Tuple2),
  Ack_Pkg_ID = nl_hf:extract_response(id, Payload2),
  (PkgID1 == Ack_Pkg_ID) and (Src1 == Dst2)
  and (Dst1 == Src2) and (MType1 == MType2);
is_response(_, _, _, _, _) ->
  false.

is_response(_, true, data, dst_reached, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1, Payload1] =
    getv([id, src, dst, mtype, payload], Tuple1),
  [Src2, Dst2, MType2, Payload2] =
    getv([src, dst, mtype, payload], Tuple2),
  <<Hash1:16, _/binary>> = crypto:hash(md5, Payload1),
  [Dst_Pkg_ID, Hash2] = nl_hf:extract_response([id, hash], Payload2),
  (PkgID1 == Dst_Pkg_ID) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2)
  and (Hash1 == Hash2);
is_response(_, false, data, dst_reached, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1, Payload1] =
    getv([id, src, dst, mtype, payload], Tuple1),
  [Src2, Dst2, MType2, Payload2] =
    getv([src, dst, mtype, payload], Tuple2),
  <<Hash1:16, _/binary>> = crypto:hash(md5, Payload1),
  [Dst_Pkg_ID, Hash2] = nl_hf:extract_response([id, hash], Payload2),
  (PkgID1 == Dst_Pkg_ID) and (Src1 == Dst2)
  and (Dst1 == Src2) and (MType1 == MType2)
  and (Hash1 == Hash2).

is_same(ack, ack, path_addit, path_addit, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1] = getv([id, src, dst, mtype], Tuple1),
  [PkgID2, Src2, Dst2, MType2] = getv([id, src, dst, mtype], Tuple2),
  (PkgID1 == PkgID2) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2);
is_same(ack, ack, path_neighbours, path_neighbours, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1] = getv([id, src, dst, mtype], Tuple1),
  [PkgID2, Src2, Dst2, MType2] = getv([id, src, dst, mtype], Tuple2),
  (PkgID1 == PkgID2) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2);
is_same(ack, ack, MType1, MType2, Tuple1, Tuple2) ->
  [PkgID1, Src1, Dst1, MType1, Payload1] =
    getv([id, src, dst, mtype, payload], Tuple1),
  [PkgID2, Src2, Dst2, MType2, Payload2] =
    getv([id, src, dst, mtype, payload], Tuple2),
  Hash1 = nl_hf:extract_response(hash, Payload1),
  Hash2 = nl_hf:extract_response(hash, Payload2),
  (PkgID1 == PkgID2) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2)
  and (Hash1 == Hash2).

data_reached(SM, Tuple1, Tuple2) ->
  Flag1 = getv(flag, Tuple1),
  Flag2 = getv(flag, Tuple2),
  data_reached(SM, Flag1, Flag2, Tuple1, Tuple2).
data_reached(_, ack, data, Tuple1, Tuple2) ->
  [Src1, Dst1, MType1, Payload1] =
    getv([src, dst, mtype, payload], Tuple1),
  [PkgID2, Src2, Dst2, MType2, Payload2] =
    getv([id, src, dst, mtype, payload], Tuple2),
  <<Hash2:16, _/binary>> = crypto:hash(md5, Payload2),
  [Ack_Pkg_ID, Hash1] = nl_hf:extract_response([id, hash], Payload1),
  (PkgID2 == Ack_Pkg_ID) and (Src1 == Dst2)
  and (Dst1 == Src2) and (MType1 == MType2)
  and (Hash1 == Hash2);
data_reached(SM, dst_reached, data, Tuple1, Tuple2) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Ack_protocol = Protocol_Config#pr_conf.ack,
  [Src1, Dst1, MType1, Payload1] =
    getv([src, dst, mtype, payload], Tuple1),
  [PkgID2, Src2, Dst2, MType2, Payload2] =
    getv([id, src, dst, mtype, payload], Tuple2),
  [Dst_Pkg_ID, Hash1] = nl_hf:extract_response([id, hash], Payload1),
  <<Hash2:16, _/binary>> = crypto:hash(md5, Payload2),
  (Ack_protocol and ((PkgID2 == Dst_Pkg_ID) and (Src1 == Src2)
  and (Dst1 == Dst2) and (MType1 == MType2)
  and (Hash1 == Hash2)) ) or
  ((PkgID2 == Dst_Pkg_ID) and (Src1 == Dst2)
  and (Dst1 == Src2) and (MType1 == MType2)
  and (Hash1 == Hash2));
data_reached(_, _, _, _, _) ->
  false.

if_path_packet(empty) -> false;
if_path_packet(Tuple) ->
  [Flag, MType] = getv([flag, mtype], Tuple),
  if (((Flag == path) or (Flag == ack)) and
     ((MType == path_addit) or (MType == path_neighbours))) -> true;
  true -> false
  end.
% -------------------------------- Message queues handling functions -------------------------------------
fill_transmission(SM, _, error) ->
  ?INFO(?ID, "fill_transmission 1 to ~p~n", [?TRANSMISSION_QUEUE_SIZE]),
  set_event_params(SM, {fill_tq, error});
fill_transmission(SM, Type, Tuple) ->
  Qname = transmission,
  Q = share:get(SM, Qname),

  Is_path = if_path_packet(Tuple),
  Has_path_packets = has_path_packets(Q, false, 0),
  ?INFO(?ID, "Has_path_packets ~p ~n", [Has_path_packets]),
  Fill_handler =
  fun(LSM, path) ->
        share:put(LSM, Qname, queue:in_r(Tuple, Q));
     (LSM, filo) ->
        share:put(LSM, Qname, queue:in(Tuple, Q));
     (LSM, combination) ->
        share:put(LSM, Qname, queue:in(Tuple, Q));
     (LSM, fifo) when not Has_path_packets ->
        share:put(LSM, Qname, queue:in_r(Tuple, Q));
     (LSM, fifo) ->
        NQ = shift_push(Q, Tuple, Has_path_packets),
        share:put(LSM, Qname, NQ)
  end,

  ?INFO(?ID, "fill_transmission ~p to ~p~n", [Tuple, Q]),
  case queue:len(Q) of
    _ when Is_path ->
      Fill_handler(SM, path);
    Len when Len >= ?TRANSMISSION_QUEUE_SIZE ->
      set_event_params(SM, {fill_tq, error});
    _  ->
      [fill_statistics(__, Tuple),
       Fill_handler(__, Type),
       set_event_params(__, {fill_tq, ok})
      ](SM)
  end.

drop_postponed(SM, Dst) ->
  Q = share:get(SM, transmission),
  drop_postponed(SM, Dst, Q).

drop_postponed(SM, _, {[],[]}) ->
  SM;
drop_postponed(SM, Dst, Q) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  [QID, QFlag, QDst] = getv([id, flag, dst], Q_Tuple),
  ?INFO(?ID, "drop_postponed ~p dst ~p  ~p from Q ~p~n", [Q_Tuple, Dst, QDst, Q]),
  if QDst == Dst ->
    Cast_handler =
    fun (LSM, data) ->
        fsm:cast(LSM, nl_impl, {send, {nl, drop, QID}});
        (LSM, _) -> LSM
    end,
    [Cast_handler(__, QFlag),
     pop_transmission(__, Q_Tuple),
     drop_postponed(__, Dst, Q_Tail)
    ](SM);
  true ->
    drop_postponed(SM, Dst, Q_Tail)
  end.

has_path_packets({[],[]}, false, _) -> false;
has_path_packets({[],[]}, true, Num) -> {true, Num};
has_path_packets(Q, Inside, Num) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Is_path = if_path_packet(Q_Tuple),
  if Is_path ->
    has_path_packets(Q_Tail, true, Num + 1);
  true ->
    has_path_packets(Q_Tail, Inside, Num + 1)
  end.

check_tranmission_path(SM, Tuple) ->
  check_tranmission_path(SM, Tuple, transmission) or
  check_tranmission_path(SM, Tuple, received).

check_tranmission_path(SM, Tuple, Qname) ->
  {Pkg_ID, NL_Src, NL_Dst, MType, _} = Tuple,
  Q = share:get(SM, Qname),
  Ack_paths =
  lists:filtermap(
  fun (X) ->
      [XFlag, XSrc, XDst, XMtype, XPayload] =
        getv([flag, src, dst, mtype, payload], X),
      if XFlag == ack, XMtype == MType, XSrc == NL_Dst,
         NL_Src == XDst ->
        Ack_Pkg_ID = extract_response(id, XPayload),
        if Pkg_ID == Ack_Pkg_ID -> {true, Tuple};
        true -> false end;
      true -> false
      end
  end, queue:to_list(Q)),
  ?INFO(?ID, "Check in queue ~p ~p~n",  [Qname, length(Ack_paths)]),
  length(Ack_paths) > 0.

head_transmission(SM) ->
  Q = share:get(SM, transmission),
  Head =
  case queue:is_empty(Q) of
    true ->  empty;
    false -> {{value, Item}, _} = queue:out(Q), Item
  end,
  ?INFO(?ID, "GET HEAD ~p~n", [Head]),
  Head.

shift_push(Q, Tuple, {true, Num}) ->
  {Q1, Q2} = queue:split(Num, Q),
  NQ = queue:in_r(Tuple, Q2),
  queue:join(Q1, NQ).

pop_transmission(SM, head, Tuple) ->
  Qname = transmission,
  Q = share:get(SM, Qname),
  Head = head_transmission(SM),

  Pop_handler =
  fun(LSM) ->
    {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
    ?TRACE(?ID, "deleted Tuple ~p from  ~p~n",[Tuple, Q]),
    [set_zero_retries(__, Q_Tuple),
     clear_sensing_timeout(__, Q_Tuple),
     share:put(__, transmission, Q_Tail)
    ](LSM)
  end,

  Response = is_response(SM, Head, Tuple),
  ?TRACE(?ID, "pop_transmission head Response ~p ~p ~p~n", [Response, Head, Tuple]),
  if Response -> Pop_handler(SM);
  true ->
    clear_sensing_timeout(SM, Tuple)
  end.

pop_transmission(SM, Tuple) ->
  Q = share:get(SM, transmission),
  ?INFO(?ID, ">>>>>>>>>>> pop_transmission ~p ~p~n", [Tuple, Q]),
  pop_tq_helper(SM, Tuple, Q, queue:new()).

pop_tq_helper(SM, Tuple, {[],[]}, NQ = {[],[]}) ->
  ?TRACE(?ID, "Current transmission queue ~p~n", [NQ]),
  [share:put(__, transmission, NQ),
   set_zero_retries(__, Tuple),
   clear_sensing_timeout(__, Tuple)
  ](SM);
pop_tq_helper(SM, _Tuple, {[],[]}, NQ) ->
  ?TRACE(?ID, "Current transmission queue ~p~n", [NQ]),
  share:put(SM, transmission, NQ);
pop_tq_helper(SM, Tuple, Q, NQ) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Pop_handler =
  fun (LSM) ->
    ?TRACE(?ID, "deleted Tuple ~p from  ~p~n",[Q_Tuple, Q]),
    [set_zero_retries(__, Tuple),
     set_zero_retries(__, Q_Tuple),
     clear_sensing_timeout(__, Q_Tuple),
     clear_sensing_timeout(__, Tuple),
     pop_tq_helper(__, Tuple, Q_Tail, NQ)
    ](LSM)
  end,

  Response = is_response(SM, Q_Tuple, Tuple),
  ?TRACE(?ID, "pop_transmission Response ~p ~p ~p~n", [Response, Q_Tuple, Tuple]),

  if Response ->
    Pop_handler(SM);
  true ->
    pop_tq_helper(SM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end.

clear_sensing_timeout(SM, Tuple) ->
  ?TRACE(?ID, "Clear sensing timeout ~p in ~p~n",[Tuple, SM#sm.timeouts]),
  TRefList =
  filter(
   fun({E, TRef}) ->
      case E of
          {sensing_timeout, STuple} ->
            Response = is_response(SM, STuple, Tuple),
            if Response -> timer:cancel(TRef), false;
            true -> true
            end;
          _-> true

      end
  end, SM#sm.timeouts),
  ?TRACE(?ID, "Cleared ~p~n",[TRefList]),
  SM#sm{timeouts = TRefList}.

set_zero_retries(SM, Tuple) ->
  Q = share:get(SM, retriesq),
  zero_rq_retries(SM, Tuple, Q, queue:new()).

zero_rq_retries(SM, _Tuple, {[],[]}, NQ) ->
  ?TRACE(?ID, "current retry queue ~p~n",[NQ]),
  share:put(SM, retriesq, NQ);
zero_rq_retries(SM, Tuple, Q, NQ) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  {_Retries, QT} = Q_Tuple,
  Same = is_same(SM, QT, Tuple),
  Response = is_response(SM, QT, Tuple),
  ?TRACE(?ID, "zero_rq_retries Response ~p Same ~p ~p ~p~n", [Response, Same, QT, Tuple]),

  case Same of
    true ->
      Decreased_Q1 = queue_push(NQ, {-1, QT}, ?RQ_SIZE),
      zero_rq_retries(SM, Tuple, Q_Tail, Decreased_Q1);
    false when Response ->
      Decreased_Q1 = queue_push(NQ, {-1, QT}, ?RQ_SIZE),
      Decreased_Q2 = queue_push(Decreased_Q1, {-1, Tuple}, ?RQ_SIZE),
      zero_rq_retries(SM, Tuple, Q_Tail, Decreased_Q2);
    _ ->
      zero_rq_retries(SM, Tuple, Q_Tail, queue_push(NQ, Q_Tuple, ?RQ_SIZE))
  end.

decrease_retries(SM, Tuple) ->
  Q = share:get(SM, retriesq),
  ?TRACE(?ID, "Change local tries of packet ~p in retires Q ~p~n",[Tuple, Q]),
  decrease_rq_helper(SM, Tuple, not_inside, Q, queue:new()).

decrease_rq_helper(SM, Tuple, not_inside, {[],[]}, {[],[]}) ->
  Local_Retries = share:get(SM, retries),
  queue_push(SM, retriesq, {Local_Retries - 1, Tuple}, ?RQ_SIZE);
decrease_rq_helper(SM, Tuple, not_inside, {[],[]}, NQ) ->
  Local_Retries = share:get(SM, retries),
  Q = queue_push(NQ, {Local_Retries - 1, Tuple}, ?RQ_SIZE),
  share:put(SM, retriesq, Q);
decrease_rq_helper(SM, _Tuple, inside, {[],[]}, NQ) ->
  share:put(SM, retriesq, NQ);
decrease_rq_helper(SM, Tuple, Inside, Q, NQ) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  {Retries, QT} = Q_Tuple,
  Pop_queue =
  fun (LSM, Tries) when Tries =< 0 ->
        ?TRACE(?ID, "drop Tuple ~p from  ~p, retries ~p ~n",[Q_Tuple, Q, Tries]),
        Decreased_Q = queue_push(NQ, {Tries - 1, Tuple}, ?RQ_SIZE),
        [pop_transmission(__, Tuple),
         decrease_rq_helper(__, Tuple, inside, Q_Tail, Decreased_Q)
        ](LSM);
      (LSM, Tries) when Tries > 0 ->
        ?TRACE(?ID, "change Tuple ~p in  ~p, retries ~p ~n",[Q_Tuple, Q, Tries - 1]),
        Decreased_Q = queue_push(NQ, {Tries - 1, Tuple}, ?RQ_SIZE),
        decrease_rq_helper(LSM, Tuple, inside, Q_Tail, Decreased_Q)
  end,

  Same = is_same(SM, QT, Tuple),
  ?TRACE(?ID, "decrease_rq_helper ~p ~p ~p~n", [Same, QT, Tuple]),
  if Same -> Pop_queue(SM, Retries);
  true ->
    decrease_rq_helper(SM, Tuple, Inside, Q_Tail, queue_push(NQ, Q_Tuple, ?RQ_SIZE))
  end.

decrease_TTL(SM) ->
  Q = share:get(SM, transmission),
  ?INFO(?ID, "decrease TTL for every packet in the queue ~p ~n",[Q]),
  decrease_TTL_tq(SM, Q, queue:new()).

decrease_TTL_tq(SM, {[],[]}, NQ) ->
  share:put(SM, transmission, NQ);
decrease_TTL_tq(SM, Q, NQ) ->
  Waiting_path = share:get(SM, nothing, waiting_path, false),
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Is_path = nl_hf:if_path_packet(Q_Tuple),
  [Flag, QTTL] = getv([flag, ttl], Q_Tuple),
  TTL_handler =
  fun (LSM, dst_reached, _) ->
        decrease_TTL_tq(LSM, Q_Tail, queue:in(Q_Tuple, NQ));
      (LSM, _, TTL) when TTL > 0 ->
        Tuple = replace(ttl, TTL, Q_Tuple),
        decrease_TTL_tq(LSM, Q_Tail, queue:in(Tuple, NQ));
      (LSM, _, TTL) when TTL =< 0 ->
        ?INFO(?ID, "decrease and drop ~p, TTL ~p =< 0 ~n",[Q_Tuple, TTL]),
        [clear_sensing_timeout(__, Q_Tuple),
         decrease_TTL_tq(__, Q_Tail, NQ)
        ](LSM)
  end,

  case Waiting_path of
    true when Is_path -> TTL_handler(SM, Flag, QTTL - 1);
    true -> decrease_TTL_tq(SM, Q_Tail, queue:in(Q_Tuple, NQ));
    false -> TTL_handler(SM, Flag, QTTL - 1)
  end.

exists_received(Tuple) -> Tuple.
exists_received(SM, Tuple) ->
  Q = share:get(SM, received),
  LQ = queue:to_list(Q),
  Reached =
    length(lists:filtermap(
      fun(Q_Tuple) ->
        R = data_reached(SM, Q_Tuple, Tuple),
        if R -> true; true -> false end
      end, LQ)) > 0,

  SameQTTL =
    lists:filtermap(
      fun(Q_Tuple) ->
        QTTL = getv(ttl, Q_Tuple),
        R = is_same(SM, Q_Tuple, Tuple),
        if R -> {true, QTTL}; true -> false end
      end, LQ),
  Same = length(SameQTTL) > 0,
  Response =
    length(lists:filtermap(
      fun(Q_Tuple) ->
        R = is_response(SM, Q_Tuple, Tuple),
        if R -> {true, Q_Tuple}; true -> false end
      end, LQ)) > 0,

  ?TRACE(?ID, "exists_received Dst : ~p Same: ~p Response: ~p : ~p ~p~n",
    [Reached, Same, Response, Tuple, Q]),

  case Reached of
    true -> exists_received({true, 0});
    _ when Same ->
      TTL = hd(SameQTTL),
      exists_received({true, TTL});
    _ when Response -> exists_received({false, dst_reached});
    _ -> {false, 0}
  end.

update_received(SM, Tuple) ->
  Q = share:get(SM, received),
  update_rq_helper(SM, Tuple, not_inside, Q).

update_rq_helper(SM, Tuple, not_inside, {[],[]}) ->
  nl_hf:queue_push(SM, received, Tuple, ?RQ_SIZE);
update_rq_helper(SM, _, inside, {[],[]}) ->
  SM;
update_rq_helper(SM, Tuple, Inside, Q) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),

  Same = is_same(SM, Q_Tuple, Tuple),
  ?TRACE(?ID, "update_received Same ~p ~p ~p~n", [Same, Q_Tuple, Tuple]),
  if Same ->
    update_rq_helper(SM, Tuple, inside, Q_Tail);
  true ->
    update_rq_helper(SM, Tuple, Inside, Q_Tail)
  end.

update_received_TTL(SM, Tuple) ->
  Q = share:get(SM, received),
  update_TTL_rq_helper(SM, Tuple, Q, queue:new()).

update_TTL_rq_helper(SM, Tuple, {[],[]}, NQ) ->
  ?INFO(?ID, "change TTL for Tuple ~p~n",[Tuple]),
  share:put(SM, received, NQ);
update_TTL_rq_helper(SM, Tuple, Q, NQ) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  TTL = getv(ttl, Tuple),
  QTTL = getv(ttl, Q_Tuple),

  Same = is_same(SM, Q_Tuple, Tuple),
  ?TRACE(?ID, "update_received_TTL head Same ~p ~p ~p ~p ~p~n", [Same, Q_Tuple, Tuple, TTL, QTTL]),
  if Same and (TTL < QTTL) ->
    NT = replace(ttl, TTL, Q_Tuple),
    update_TTL_rq_helper(SM, Tuple, Q_Tail, queue:in(NT, NQ));
  true ->
    update_TTL_rq_helper(SM, Tuple, Q_Tail, queue:in(Q_Tuple, NQ))
  end.
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
find_routing([], _) -> ?ADDRESS_MAX;
find_routing(Routing, Address) ->
  find_routing_helper(Routing, Address, nothing).

find_routing_helper(Address) -> Address.
find_routing_helper([], _Address, nothing) ->
  ?ADDRESS_MAX;
find_routing_helper([], _Address, Default) ->
  Default;
find_routing_helper([H | T], Address, Default) ->
  case H of
    {Address, To, _} -> find_routing_helper(To);
    Default_address when not is_tuple(Default_address) ->
      find_routing_helper(T, Address, Default_address);
    _ -> find_routing_helper(T, Address, Default)
  end.

%get_routing_address(_SM, _Flag, _Address) -> 255.
get_routing_address(SM, Address) ->
  Routing = share:get(SM, nothing, routing_table, []),
  ?INFO(?ID, "get_routing_address ~p ~p~n", [Routing, Address]),
  find_routing(Routing, Address).

routing_exist(_SM, empty) ->
  false;
routing_exist(SM, NL) when is_tuple(NL) ->
  Dst = getv(dst, NL),
  routing_exist(SM, Dst);
routing_exist(SM, Dst) ->
  Route_Addr = get_routing_address(SM, Dst),
  ?INFO(?ID, "routing_exist ~p ~p~n", [Route_Addr, ?ADDRESS_MAX]),
  Route_Addr =/= ?ADDRESS_MAX.
%%----------------------------Path functions -------------------------------
update_path(SM, Tuple) when is_tuple(Tuple) ->
  New_path = update_path(SM, getv(path, Tuple)),
  replace(path, New_path, Tuple);
update_path(SM, Path) ->
  Local_address = share:get(SM, local_address),
  ?TRACE(?ID, "add ~p to path ~p~n", [Local_address, Path]),
  Path_handler =
  fun (true) -> strip_path(Local_address, Path, Path);
      (false) -> lists:reverse([Local_address | lists:reverse(Path)])
  end,
  New_path = Path_handler(lists:member(Local_address, Path)),
  ?TRACE(?ID, "new path ~p~n", [New_path]),
  New_path.

% delete every node between dublicated
strip_path(Address, Path, [H | T]) when H == Address ->
  Path -- T;
strip_path(Address, Path, [_ | T]) ->
  strip_path(Address, Path, T).

add_to_paths(SM, Src, Dst, Path, Integrity, Min_integrity, _Rssi) ->
  Paths = share:get(SM, nothing, stable_paths, []),
  Tuple = {Src, Dst, Integrity, Min_integrity, Path},
  ?INFO(?ID, "Add ~p to paths ~p~n", [Tuple, Paths]),
  share:put(SM, stable_paths, [ Tuple | Paths]).

update_stable_path(SM, AT_Src, AT_Dst, NL_Src, NL_Dst) ->
  Local_address = share:get(SM, local_address),
  Paths = share:get(SM, nothing, stable_paths, []),
  ?INFO(?ID, "update_stable_path ~p ~p~n", [AT_Src, Paths]),
  Update_handler =
  fun (LSM) when  Local_address == AT_Dst ->
        update_stable_path(LSM, AT_Src, Paths);
      (LSM) -> LSM
  end,

  [Update_handler(__),
   remove_old_paths(__, NL_Src, NL_Dst)
  ](SM).

update_stable_path(SM, _, []) -> SM;
update_stable_path(SM, Src, [H | Paths]) ->
  Routing_handler =
  fun (LSM, S, P) ->
      Member = lists:member(S, P),
      if Member ->
        update_routing(LSM, P);
      true -> LSM end
  end,
  {_, _, _, _, Path}  = H,
  New_path = update_path(SM, Path),
  [Routing_handler(__, Src, New_path),
   update_stable_path(__, Src, Paths)
  ](SM).

get_stable_path(SM, Src, Dst) ->
  Paths = share:get(SM, nothing, stable_paths, []),
  ?INFO(?ID, "Choose between paths ~p~n", [Paths]),
  get_stable_path_helper(SM, Src, Dst, lists:reverse(Paths), -1, -1, []).

get_stable_path(SM, path_neighbours, _Src, _Dst) ->
  Local_address = share:get(SM, local_address),
  [Local_address];
get_stable_path(SM, path_addit, Src, Dst) ->
  get_stable_path(SM, Src, Dst).

get_stable_path_helper(_, _, _, [], -1, -1, []) -> nothing;
get_stable_path_helper(_, _, _, [], _, _, NP) -> NP;
get_stable_path_helper(SM, Src, Dst, [ H | T], Max, Max_min, NP) ->
  case H of
    {Src, Dst, 0, 0, Path} ->
      get_stable_path_helper(SM, Src, Dst, T, 0, 0, Path);
    {Src, Dst, Integrity, Min_integrity, Path} when Min_integrity >= Max_min, Max_min =/= 0 ->
      Aver_integrity = (Integrity > Max) and (Max =/= 0),
      if Aver_integrity ->
        get_stable_path_helper(SM, Src, Dst, T, Integrity, Min_integrity, Path);
      true ->
        get_stable_path_helper(SM, Src, Dst, T, Max, Min_integrity, NP)
      end;
    _ ->
      get_stable_path_helper(SM, Src, Dst, T, Max, Max_min, NP)
  end.

remove_old_paths(SM, Src, Dst) ->
  Paths = share:get(SM, nothing, stable_paths, []),
  L =
  lists:foldr(fun
    ({XSrc, XDst, _, _}, A) when XSrc == Src, XDst == Dst -> A;
    (X, A) -> [X | A]
  end, [], Paths),
  ?INFO(?ID, "remove_old_paths ~p ~p : ~p ~p~n", [Src, Dst, Paths, L]),
  share:put(SM, stable_paths, L).
%%----------------------------Parse NL functions -------------------------------
fill_protocol_info_header(icrpr, _, data, _, {Path, _, _, _, _, Transmit_Len, Data}) ->
  fill_path_data_header(Path, Transmit_Len, Data);
fill_protocol_info_header(_, Protocol_Config, _, path_addit, Tuple) when Protocol_Config#pr_conf.evo->
  fill_path_evo_header(Tuple);
fill_protocol_info_header(_, Protocol_Config, _, path_neighbours, Tuple) when Protocol_Config#pr_conf.pf ->
  fill_path_neighbours_header(Tuple);
fill_protocol_info_header(_, _, _, MType, {_, _, _, _, _, Transmit_Len, Data}) ->
  fill_data_header(MType, Transmit_Len, Data).

nl2at(SM, IDst, Tuple) when is_tuple(Tuple) ->
  PID = share:get(SM, pid),
  NLPPid = ?PROTOCOL_NL_PID(share:get(SM, protocol_name)),
  ?WARNING(?ID, ">>>>>>>> NLPPid: ~p~n", [NLPPid]),
  Payload = getv(payload, Tuple),
  [AT_Payload, L] = create_payload_nl_header(SM, NLPPid, true, Tuple),

  IM = byte_size(Payload) < ?MAX_IM_LEN,
  AT =
  if IM ->
    {at, {pid,PID}, "*SENDIM", IDst, noack, AT_Payload};
  true ->
    {at, {pid,PID}, "*SEND", IDst, AT_Payload}
  end,
  [AT, L].

get_at_dst(Tuple) ->
  case Tuple of
    {at, _, "*SENDIM", IDst, _, _} -> IDst;
    {at, _, "*SEND", IDst, _} -> IDst
  end.

%%------------------------- Extract functions ----------------------------------
create_nl_at_command(SM, NL) ->
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Local_address = share:get(SM, local_address),

  [PkgID, Src, Dst] = getv([id, src, dst], NL),
  Route_Addr = get_routing_address(SM, Dst),
  MAC_Route_Addr = nl2mac_address(Route_Addr),

  ?TRACE(?ID, "MAC_Route_Addr ~p, Route_Addr ~p Src ~p, Dst ~p~n", [MAC_Route_Addr, Route_Addr, Src, Dst]),
  if ((MAC_Route_Addr =:= error) or
      ((Dst =:= ?ADDRESS_MAX) and Protocol_Config#pr_conf.br_na)) ->
      error;
  true ->
      [AT, L] = nl2at(SM, MAC_Route_Addr, NL),
      Current_RTT = {rtt, Local_address, Dst},
      ?TRACE(?ID, "Current RTT ~p sending AT command ~p~n", [Current_RTT, AT]),
      fill_dets(SM, PkgID, Src, Dst),
      [AT, L]
  end.

extract_response(Payload) ->
  C_Bits_PkgID = count_flag_bits(?PKG_ID_MAX),
  C_Bits_Hops = count_flag_bits(?MAX_LEN_PATH),
  <<Hops:C_Bits_Hops, PkgID:C_Bits_PkgID, Rest/bitstring>> = Payload,
  Hash = cut_add_bits(Rest),
  {Hops, PkgID, binary_to_integer(Hash)}.

extract_response(Types, Payload) when is_list(Types) ->
  lists:foldr(fun(Type, L) -> [extract_response(Type, Payload) | L] end, [], Types);
extract_response(Type, Payload) ->
  {Hops, PkgID, Hash} = extract_response(Payload),
  Structure =
  [{hops, Hops}, {id, PkgID}, {hash, Hash}],
  Map = maps:from_list(Structure),
  {ok, Val} = maps:find(Type, Map),
  Val.

create_response(SM, dst_reached, MType, Pkg_ID, Src, Dst, Hops, Payload) ->
  create_response(SM, dst_reached, MType, Pkg_ID, Src, Dst, 0, Hops, Payload);
create_response(SM, ack, MType, Pkg_ID, Src, Dst, Hops, Payload) ->
  Max_ttl = share:get(SM, ttl),
  create_response(SM, ack, MType, Pkg_ID, Src, Dst, Max_ttl, Hops, Payload).

recreate_response(SM, path_neighbours, Flag = ack, Tuple, Channel) ->
  {_, _, _, Integrity} = Channel,
  [Path, Path_integrity, Min_integrity, Payload] =
    getv([path, integrity, min_integrity, payload], Tuple),

  Aver_Integrity = get_average(Integrity, Path_integrity),
  Is_min = (Min_integrity =/= 0) and (Min_integrity < Integrity),
  Processed =
  if Is_min -> Min_integrity;
  true -> Integrity
  end,
  New_path = update_path(SM, Path),
  Neighbours = share:get(SM, current_neighbours),
  [Hops, Ack_Pkg_ID, Hash] = extract_response([hops, id, hash], Payload),
  Coded_payload = encode_response(Hops + 1, Ack_Pkg_ID, Hash),
  ?TRACE(?ID, "recreate_response ~p Hops ~p ~p ~p ~p~n",
    [Flag, Hops, New_path, Neighbours, Coded_payload]),
  replace([path, integrity, min_integrity, neighbours, payload],
          [New_path, Aver_Integrity, Processed, Neighbours, Coded_payload], Tuple);
recreate_response(SM, _, Flag = ack, Tuple, _) ->
  Payload = getv(payload, Tuple),
  [Hops, Ack_Pkg_ID, Hash] = extract_response([hops, id, hash], Payload),
  Coded_payload = encode_response(Hops + 1, Ack_Pkg_ID, Hash),
  ?TRACE(?ID, "recreate_response ~p Hops ~p ~p ~p ~p~n",
    [Flag, Hops, Ack_Pkg_ID, Tuple, Coded_payload]),
  replace(payload, Coded_payload, Tuple).

create_ack_path(SM, ack, MType, Pkg_ID, Src, Dst, Hops, Payload, Path) ->
  Max_ttl = share:get(SM, ttl),
  Tuple = create_response(SM, ack, MType, Pkg_ID, Src, Dst, Max_ttl, Hops, Payload),
  Path_replaced = replace(path, Path, Tuple),
  if MType == path_neighbours ->
    Neighbours = share:get(SM, current_neighbours),
    replace(neighbours, Neighbours, Path_replaced);
  true -> Path_replaced end.

create_response(SM, Flag, MType, Pkg_ID, Src, Dst, TTL, Hops, Payload) ->
  <<Hash:16, _/binary>> = crypto:hash(md5, Payload),
  Coded_payload = encode_response(Hops, Pkg_ID, Hash),
  Incereased = increase_pkgid(SM, Dst, Src),
  Tuple = create_default(SM),
  replace(
    [flag, id, ttl, src, dst, mtype, payload],
    [Flag, Incereased, TTL, Dst, Src, MType, Coded_payload], Tuple).

recreate_path_evo(SM,  Rssi, Integrity, Min_integrity, Tuple) ->
  [Path, Path_rssi, Path_integrity] = getv([path, rssi, integrity], Tuple),
  Aver_Rssi = get_average(Rssi, Path_rssi),
  Aver_Integrity = get_average(Integrity, Path_integrity),
  Is_min = (Min_integrity =/= 0) and (Min_integrity < Integrity),
  Processed =
  if Is_min -> Min_integrity;
  true -> Integrity
  end,
  New_path = update_path(SM, Path),
  replace(
    [path, rssi, integrity, min_integrity],
    [New_path, Aver_Rssi, Aver_Integrity, Processed],
    Tuple).

recreate_path_neighbours(SM, Tuple) ->
  Neighbours = share:get(SM, current_neighbours),
  [Path, _] = getv([path, neighbours], Tuple),
  New_path = update_path(SM, Path),
  replace(
    [path, neighbours],
    [New_path, Neighbours],
    Tuple).

prepare_path(SM, Flag, MType, Src, Dst) ->
  Max_ttl = share:get(SM, ttl),
  PkgID = increase_pkgid(SM, Src, Dst),
  Tuple = create_default(SM),
  New_path = [Src],
  replace(
    [flag, id, ttl, src, dst, mtype, path],
    [Flag, PkgID, Max_ttl, Src, Dst, MType, New_path], Tuple).

encode_response(Hops, Pkg_ID, Hash) ->
  BHash = integer_to_binary(Hash),
  C_Bits_PkgID = count_flag_bits(?PKG_ID_MAX),
  C_Bits_Hops = count_flag_bits(?MAX_LEN_PATH),
  B_Hops = <<Hops:C_Bits_Hops>>,
  B_PkgID = <<Pkg_ID:C_Bits_PkgID>>,

  Tmp_Data = <<B_Hops/bitstring, B_PkgID/bitstring, BHash/binary>>,
  Is_binary = check_binary(Tmp_Data),
  if not Is_binary ->
    Add = add_bits(Tmp_Data),
    <<B_Hops/bitstring, B_PkgID/bitstring, 0:Add, BHash/binary>>;
  true ->
    Tmp_Data
  end.

extract_payload_nl_header(SM, Payload) ->
  extract_payload_nl_header(SM, Payload, []).

extract_payload_nl_header(_, <<"">>, L) -> L;
extract_payload_nl_header(SM, Payload, L) ->
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

  ?INFO(?ID, "To extract Payload ~p ~p ~p ~p ~p ~p~n", [Payload, C_Bits_Pid, C_Bits_Flag, C_Bits_PkgID, C_Bits_TTL, C_Bits_Addr]),

  <<Pid:C_Bits_Pid, Flag_Num:C_Bits_Flag, PkgID:C_Bits_PkgID, TTL:C_Bits_TTL,
    Src:C_Bits_Addr, Dst:C_Bits_Addr, _Rest/bitstring>> = Payload,

  Bits_header = C_Bits_Pid + C_Bits_Flag + C_Bits_PkgID + C_Bits_TTL + 2 * C_Bits_Addr,
  Extract_payload = cut_add_bits(Bits_header, Payload),

  Flag = num2flag(Flag_Num, nl),
  [MType, Path, Rssi, Integrity, Min_integrity, Neighbours, Splitted_Payload, Other_msg] = extract_payload(SM, Extract_payload),

  NL = if L =/= [] -> {_, List} = L, List; true -> [] end,
  ?INFO(?ID, "Rest extract Payload ~p~n", [Other_msg]),
  Tuple = create_default(SM),
  RTuple =
  replace(
  [flag, id, ttl, src, dst, mtype, path, rssi, integrity, min_integrity, neighbours, payload],
  [Flag, PkgID, TTL, Src, Dst, MType, Path, Rssi, Integrity, Min_integrity, Neighbours, Splitted_Payload], Tuple),
  extract_payload_nl_header(SM, Other_msg, {Pid, [RTuple | NL]}).

  % 6 bits NL_Protocol_PID
  % 3 bits Flag
  % 6 bits PkgID
  % 2 bits TTL
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 3)
create_payload_nl_header(SM, Pid, Allowed, Tuple) ->
  [Flag, PkgID, TTL, Src, Dst, Mtype, Path, Rssi, Integrity, Min_integrity, Neighbours, Data] = geta(Tuple),

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

  Transmit_Len = byte_size(Data),
  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  CTuple = {Path, Rssi, Integrity, Min_integrity, Neighbours, Transmit_Len, Data},

  ?INFO(?ID, "Code Payload ~p ~p ~p ~p ~p~n", [Protocol_Name, Protocol_Config, Flag, Mtype, CTuple]),
  Coded_Payload = fill_protocol_info_header(Protocol_Name, Protocol_Config, Flag, Mtype, CTuple),

  Tmp_Data = <<B_Pid/bitstring, B_Flag/bitstring, B_PkgID/bitstring, B_TTL/bitstring,
               B_Src/bitstring, B_Dst/bitstring, Coded_Payload/binary>>,

  Is_binary = check_binary(Tmp_Data),
  Data_to_Send =
  if not Is_binary ->
    Add = add_bits(Tmp_Data),
    ?INFO(?ID, "Add ~p~n", [Add]),

    <<B_Pid/bitstring, B_Flag/bitstring, B_PkgID/bitstring, B_TTL/bitstring, B_Src/bitstring,
      B_Dst/bitstring, 0:Add, Coded_Payload/binary>>;
  true ->
    Tmp_Data
  end,

  Protocol_Name = share:get(SM, protocol_name),
  Protocol_Config = share:get(SM, protocol_config, Protocol_Name),
  Ack_protocol = Protocol_Config#pr_conf.ack,
  Combine = Ack_protocol and (byte_size(Data_to_Send) < 64) and Allowed
            and ((Flag == data) or (Mtype == data) or (Mtype == path_data)),
  ?INFO(?ID, "create_payload_nl_header ~p ~p ~p~n",
    [Combine, Ack_protocol, byte_size(Data_to_Send)]),

  if Combine ->
    ?INFO(?ID, "try_combine_ack ~p~n", [byte_size(Data_to_Send)]),
    try_combine_ack(SM, Pid, Tuple, Data_to_Send);
  true ->
    [Data_to_Send, [Tuple]]
  end.

check_binary(Data) ->
  is_binary(Data) or
  ((bit_size(Data) rem 8) == 0).

add_bits(Data) ->
  (8 - bit_size(Data) rem 8) rem 8.
get_add_bits(Data) ->
  bit_size(Data) rem 8.

cut_add_bits(Count, Payload) ->
  R = (8 - Count rem 8) rem 8,
  Add = Count + R,
  <<_:Add, Data/bitstring>> = Payload,
  Data.
cut_add_bits(Payload) ->
  Is_binary = check_binary(Payload),
  if not Is_binary ->
    Add = get_add_bits(Payload),
    <<_:Add, Data/binary>> = Payload,
    Data;
  true ->
    Payload
  end.

try_combine_ack(SM, Pid, Tuple, Data) ->
  Q = share:get(SM, transmission),
  ?INFO(?ID, "try_combine_ack ~p~n", [Q]),
  Flag = getv(flag, Tuple),
  Add_data = ((Flag == ack) or (Flag == dst_reached)),
  find_acks(SM, Pid, Tuple, Q, Data, [Tuple], Add_data).

find_acks(_, _, _, {[],[]}, Data, Acks, _) -> [Data, Acks];
find_acks(SM, Pid, Tuple, Q, Ack_bin, Acks, true) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  TDst = getv(dst, Tuple),
  QDst = getv(dst, Q_Tuple),
  Dst = get_routing_address(SM, TDst),
  QRoute = get_routing_address(SM, QDst),
  Same = Tuple == Q_Tuple,
  if not Same and ((Dst == QRoute) or (Dst == ?ADDRESS_MAX)) ->
    [Data_bin, _] = create_payload_nl_header(SM, Pid, false, Q_Tuple),
    Len = byte_size(Data_bin) + byte_size(Ack_bin),
    if Len < 64 ->
      find_acks(SM, Pid, Tuple, Q_Tail, <<Data_bin/binary, Ack_bin/binary>>, [Q_Tuple | Acks], false);
    true ->
      find_acks(SM, Pid, Tuple, Q_Tail, Ack_bin, Acks, true)
    end;
  true ->
    find_acks(SM, Pid, Tuple, Q_Tail, Ack_bin, Acks, true)
  end;
find_acks(SM, Pid, Tuple, Q, Data, Acks, false) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  [QPkgID, QFlag, QMType] = getv([id, flag, mtype], Q_Tuple),
  PkgID = getv(id, Tuple),
  Member = lists:member(Q_Tuple, Acks),
  Same = Tuple == Q_Tuple,

  if not Member and not Same and
     ((QFlag == ack) or (QFlag == dst_reached)) and
     ((QMType == data) or (QMType == path_data)) ->
    [Ack_bin, _] = create_payload_nl_header(SM, Pid, false, Q_Tuple),
    ?INFO(?ID, "find_acks ~p ~p~n", [byte_size(Ack_bin), byte_size(Data)]),
    Len = byte_size(Ack_bin) + byte_size(Data),
    if Len < 64 ->
      ?INFO(?ID, "Combined ~p ~p ~p ~p~n", [QPkgID, PkgID, Data, Ack_bin]),
      find_acks(SM, Pid, Tuple, Q_Tail, <<Data/binary, Ack_bin/binary>>, [Q_Tuple | Acks], false);
    true ->
      find_acks(SM, Pid, Tuple, Q_Tail, Data, Acks, false)
    end;
  true ->
    find_acks(SM, Pid, Tuple, Q_Tail, Data, Acks, false)
  end.

%%----------------NL functions create/extract protocol header-------------------
%-------> path_data
%   3b        6b            6b        LenPath * 6b   REST till / 8
%   TYPEMSG   MAX_DATA_LEN  LenPath   Path           ADD
fill_path_data_header(Path, TransmitLen, Data) ->
  LenPath = length(Path),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  TypeNum = ?TYPEMSG2NUM(path_data),

  BLenData = <<TransmitLen:CBitsMaxLenData>>,
  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = code_header(path, Path),
  BHeader = <<BType/bitstring, BLenData/bitstring, BLenPath/bitstring, BPath/bitstring>>,
  Add = add_bits(BHeader),
  <<BHeader/bitstring, 0:Add, Data/binary>>.

%-------> data
% 3b        6b
%   TYPEMSG   MAX_DATA_LEN
fill_data_header(Type, TransmitLen, Data) ->
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  TypeNum = ?TYPEMSG2NUM(Type),

  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenData = <<TransmitLen:CBitsMaxLenData>>,

  BHeader = <<BType/bitstring, BLenData/bitstring>>,
  Add = add_bits(BHeader),
  <<BHeader/bitstring, 0:Add, Data/binary>>.

%%--------------- path_addit -------------------
%-------> path_addit
%   3b        6b        LenPath * 6b    2b        LenAdd * 8b       REST till / 8
%   TYPEMSG   LenPath   Path            LenAdd    Addtional Info     ADD
fill_path_evo_header(Tuple) ->
  {Path, Rssi, Integrity, Min_integrity, _, TransmitLen, Data} = Tuple,
  LenPath = length(Path),
  LenAdd = length([Rssi, Integrity, Min_integrity]),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?LEN_ADD),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  TypeNum = ?TYPEMSG2NUM(path_addit),

  BType = <<TypeNum:CBitsTypeMsg>>,

  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = code_header(path, Path),

  BLenAdd = <<LenAdd:CBitsLenAdd>>,
  BAdd = code_header(add, [Rssi, Integrity, Min_integrity]),
  BLenData = <<TransmitLen:CBitsMaxLenData>>,

  TmpData =
  <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
  BLenAdd/bitstring, BAdd/bitstring, BLenData/bitstring>>,
  Is_binary = check_binary(TmpData),

  Header =
  if not Is_binary ->
     Add = add_bits(TmpData),
     <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
       BLenAdd/bitstring, BAdd/bitstring, BLenData/bitstring, 0:Add>>;
   true ->
     TmpData
  end,
  if (TransmitLen > 0) ->
      <<Header/bitstring, Data/binary>>;
    true -> Header
  end.

%%--------------- neighbour_path -------------------
%-------> neighbour_path
%   3b        6b        LenPath * 6b    6b                LenNeighbours * 6b          REST till / 8
%   TYPEMSG   LenPath   Path            LenNeighbours     Neighbours                  ADD

fill_path_neighbours_header(Tuple) ->
  {Path, _, Integrity, Min_integrity, Neighbours, TransmitLen, Data} = Tuple,
  LenNeighbours = length(Neighbours),
  LenPath = length(Path),
  LenAdd = length([Integrity, Min_integrity]),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?MAX_LEN_NEIGBOURS),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsLenAdd = count_flag_bits(?LEN_ADD),
  TypeNum = ?TYPEMSG2NUM(path_neighbours),

  BType = <<TypeNum:CBitsTypeMsg>>,

  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = code_header(path, Path),

  BLenNeigbours = <<LenNeighbours:CBitsLenNeigbours>>,
  BNeighbours = code_header(neighbours, Neighbours),
  BLenData = <<TransmitLen:CBitsMaxLenData>>,

  BLenAdd = <<LenAdd:CBitsLenAdd>>,
  BAdd = code_header(add, [Integrity, Min_integrity]),

  TmpData = <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
              BLenNeigbours/bitstring, BNeighbours/bitstring,
              BLenAdd/bitstring, BAdd/bitstring, BLenData/bitstring>>,
  Is_binary = check_binary(TmpData),
  Header =
  if not Is_binary ->
     Add = add_bits(TmpData),
     <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
       BLenNeigbours/bitstring, BNeighbours/bitstring,
       BLenAdd/bitstring, BAdd/bitstring, BLenData/bitstring, 0:Add>>;
   true ->
     TmpData
  end,
  if (TransmitLen > 0) ->
      <<Header/bitstring, Data/binary>>;
    true -> Header
  end.

extract_path_neighbours_header(SM, Payload) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsLenNeigbours = count_flag_bits(?MAX_LEN_NEIGBOURS),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsLenAdd = count_flag_bits(?LEN_ADD),
  CBitsAdd = count_flag_bits(?ADD_INFO_MAX),
  <<BType:CBitsTypeMsg, PathRest/bitstring>> = Payload,

  {Path, Neighbours_rest} = extract_header(path, CBitsLenPath, CBitsLenPath, PathRest),
  {Neighbours, Add_rest} = extract_header(neighbours, CBitsLenNeigbours, CBitsLenNeigbours, Neighbours_rest),
  {Additional, Data_rest} = extract_header(add, CBitsLenAdd, CBitsAdd, Add_rest),
  [Integrity, Min_integrity] = Additional,

  path_neighbours = ?NUM2TYPEMSG(BType),

  <<Len:CBitsMaxLenData, Rest/bitstring>> = Data_rest,
  ?TRACE(?ID, "extract path neighbours BType ~p  Path ~p Neighbours ~p Len ~p Rest ~p Additional ~p~n",
        [BType, Path, Neighbours, Len, Rest, Additional]),
  Rest_payload = cut_add_bits(Rest),
  ?TRACE(?ID, "extract path neighbours Rest_payload ~p~n", [Rest_payload]),

  if Len > 0 ->
    <<Path_payload:Len/binary, Other_msg/binary>> = Rest_payload,
    [Path, 0, Integrity, Min_integrity, Neighbours, Path_payload, Other_msg];
  true ->
    [Path, 0, Integrity, Min_integrity, Neighbours, <<"">>, Rest_payload]
  end.

extract_path_evo_header(SM, Payload) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?LEN_ADD),
  CBitsAdd = count_flag_bits(?ADD_INFO_MAX),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),

  <<BType:CBitsTypeMsg, PathRest/bitstring>> = Payload,
  {Path, Add_rest} = extract_header(path, CBitsLenPath, CBitsLenPath, PathRest),
  {Additional, Data_rest} = extract_header(add, CBitsLenAdd, CBitsAdd, Add_rest),

  path_addit = ?NUM2TYPEMSG(BType),
  [Rssi, Integrity, Min_integrity] = Additional,

  ?TRACE(?ID, "extract path addit BType ~p  Path ~p Additonal ~p~n",
        [BType, Path, Additional]),

  <<Len:CBitsMaxLenData, Rest/bitstring>> = Data_rest,
  Rest_payload = cut_add_bits(Rest),

  if Len > 0 ->
    <<Path_payload:Len/binary, Other_msg/binary>> = Rest_payload,
    [Path, Rssi, Integrity, Min_integrity, [], Path_payload, Other_msg];
  true ->
    [Path, Rssi, Integrity, Min_integrity, [], <<"">>, Rest_payload]
end.

extract_payload(SM, Payload) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),

  ?TRACE(?ID, "extract_payload message type ~p ~p ~p~n", [bit_size(Payload), CBitsTypeMsg, CBitsMaxLenData]),

  <<Type:CBitsTypeMsg, Len:CBitsMaxLenData, Rest/bitstring>> = Payload,

  MType = ?NUM2TYPEMSG(Type),
  ?TRACE(?ID, "extract_payload message type ~p ~n", [MType]),
  [Path, Rssi, Integrity, Min_integrity, Neighbours, Parsed_data, Other_msg] =
  case MType of
    path_neighbours ->
      extract_path_neighbours_header(SM, Payload);
    path_addit ->
      extract_path_evo_header(SM, Payload);
    path_data ->
      {P, Path_payload} = extract_header(path, CBitsLenPath, CBitsLenPath, Rest),
      ?TRACE(?ID, "extract_payload message type ~p ~p ~n", [P, Path_payload]),
      [Data, Rest_payload] = decode_payload(SM, MType, Len, 0, Path_payload),
      [P, 0, 0, 0, [], Data, Rest_payload];
    data ->
      Cut_len = CBitsTypeMsg + CBitsMaxLenData,
      [Data, Rest_payload] = decode_payload(SM, MType, Len, Cut_len, Payload),
      [[], 0, 0, 0, [], Data, Rest_payload]
  end,

  [MType, Path, Rssi, Integrity, Min_integrity, Neighbours, Parsed_data, Other_msg].

decode_payload(SM, path_data, Len, _, Payload) ->
  Data = cut_add_bits(Payload),
  <<Path_payload:Len/binary, Rest_payload/binary>> = Data,
  ?TRACE(?ID, "decode_payload ~p ~p~n", [Path_payload, Rest_payload]),
  [Path_payload, Rest_payload];
decode_payload(SM, data, Len, Cut_len, Payload) ->
  Is_binary = (Cut_len rem 8) == 0,
  Data =
  if not Is_binary ->
    cut_add_bits(Cut_len, Payload);
  true -> Payload
  end,

  <<Path_payload:Len/binary, Rest_payload/binary>> = Data,
  ?TRACE(?ID, "decode_payload ~p ~p~n", [Path_payload, Rest_payload]),
  [Path_payload, Rest_payload].

decode_header(neighbours, Neighbours) ->
  W = count_flag_bits(?MAX_LEN_NEIGBOURS),
  [N || <<N:W>> <= Neighbours];
decode_header(path, Paths) ->
  W = count_flag_bits(?MAX_LEN_PATH),
  [P || <<P:W>> <= Paths];
decode_header(add, AddInfos) ->
  W = count_flag_bits(?ADD_INFO_MAX),
  [N || <<N:W>> <= AddInfos].

extract_header(Id, LenWidth, FieldWidth, Input) ->
  <<Len:LenWidth, _/bitstring>> = Input,
  Width = Len * FieldWidth,
  <<_:LenWidth, BField:Width/bitstring, Rest/bitstring>> = Input,
  {decode_header(Id, BField), Rest}.

code_header(neighbours, Neighbours) ->
  W = count_flag_bits(?MAX_LEN_NEIGBOURS),
  << <<N:W>> || N <- Neighbours>>;
code_header(path, Paths) ->
  W = count_flag_bits(?MAX_LEN_PATH),
  << <<N:W>> || N <- Paths>>;
code_header(add, AddInfos) ->
  W = count_flag_bits(?ADD_INFO_MAX),
  Saturated_integrities = lists:map(fun(S) when S > 255 -> 255; (S) -> S end, AddInfos),
  << <<N:W>> || N <- Saturated_integrities>>.
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

get_average(Val1, 0) ->
  round(Val1);
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
  Neighbours = share:get(SM, nothing, current_neighbours, []),

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
                            ({From, To}) -> {From, To, 0}
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
                  {_, Address, _} -> false;
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
        ?INFO(?ID, "delete_neighbour ~p ~p~n", [PNeighbours, Address]),
        [share:put(__, current_neighbours, PNeighbours),
         Routing_handler(__, share:get(SM, routing_table)),
         Channel_handler(__, lists:keyfind(Address, 1, N_Channel))
        ] (LSM);
       (LSM, false) ->
        LSM
    end,

  Neighbour_handler(SM, lists:member(Address, Neighbours)).

get_prev_neighbour(SM, Routing) ->
  Local_address = share:get(SM, local_address),
  {Slist, _} = lists:splitwith(fun(A) -> A =/= Local_address end, Routing),
  Reverse = lists:reverse(Slist),
  if Reverse =/= [] ->
    [Neighbour | _] = Reverse, Neighbour;
  true -> nothing
  end.

update_routing(_SM, []) -> [];
update_routing(SM, Routing) ->
  Local_address = share:get(SM, local_address),
  {Slist, Dlist} = lists:splitwith(fun(A) -> A =/= Local_address end, Routing),
  ?TRACE(?ID, "update_routing ~p ~p~n", [Slist, Dlist]),
  [fill_statistics(__, paths, Routing),
   update_routing(__, source, Slist),
   update_routing(__, destination, Dlist)
  ](SM).

update_routing(SM, source, []) -> SM;
update_routing(SM, source, L) ->
  Reverse = lists:reverse(L),
  [Neighbour | T] = Reverse,
  ?TRACE(?ID, "update source ~p ~p~n", [Neighbour, T]),
  [add_to_routing(__, {Neighbour, Neighbour, 1}),
   update_routing_helper(__, Neighbour, T, 1)
  ](SM);
update_routing(SM, destination, []) -> SM;
update_routing(SM, destination, [H | T]) ->
  Local_address = share:get(SM, local_address),
  ?TRACE(?ID, "update destination ~p ~p~n", [H, T]),
  if Local_address == H ->
    update_routing(SM, destination, T);
  true ->
    [add_to_routing(__, {H, H, 1}),
     update_routing_helper(__, H, T, 1)
    ](SM)
  end.

update_routing_helper(SM, _, [], _) ->
  SM;
update_routing_helper(SM, Neighbour, L = [H | T], Hops) ->
  ?TRACE(?ID, "update_routing_helper ~p in ~p~n", [Neighbour, L]),
  [add_to_routing(__, {H, Neighbour, Hops + 1}),
   update_routing_helper(__, Neighbour, T, Hops + 1)
  ](SM).

replace_rotuing(Tuple = {From, _, Hops}, Routing_table) ->
  lists:foldr(
    fun ({XFrom, _, XHops}, A) when XFrom == From, Hops =< XHops ->
          [Tuple | A];
        (X, A) ->
          [X | A]
    end, [], Routing_table).

add_to_routing(SM, Tuple = {From, _, _}) ->
  Routing_table = share:get(SM, routing_table),
  ?TRACE(?ID, "add_to_routing ~p to ~p ~n", [Tuple, Routing_table]),
  Updated =
  case Routing_table of
    ?ADDRESS_MAX ->
      [Tuple];
    _ ->
      case lists:keyfind(From, 1, Routing_table) of
        false -> [Tuple | Routing_table];
        _ -> replace_rotuing(Tuple, Routing_table)
      end
  end,

  ?INFO(?ID, "Updated routing ~p~n", [Updated]),
  share:put(SM, routing_table, Updated).

routing_to_list(SM) ->
  Routing_table = share:get(SM, routing_table),
  Local_address = share:get(SM, local_address),
  case Routing_table of
    ?ADDRESS_MAX ->
      [{default,?ADDRESS_MAX}];
    _ ->
      lists:filtermap(
        fun({From, To, _}) when From =/= Local_address -> {true, {From, To}};
           ({_,_,_}) -> false;
           (To) -> {true, {default, To}}
        end, Routing_table)
  end.
%-------------------------- Statistics helper functions---------------------------
fill_statistics(SM, paths, Routing) ->
  Total = share:get(SM, nothing, paths_total_count, 0),
  Path_count = share:get(SM, nothing, Routing, 0),
  [share:put(__, paths_total_count, Total + 1),
   list_push(__, paths, Routing, 100),
   share:put(__, Routing, Path_count + 1)
  ](SM);
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

fill_statistics(SM, Tuple) ->
  fill_statistics(SM, data, getv(flag, Tuple), Tuple).

fill_statistics(SM, data, dst_reached, _) ->
  SM;
fill_statistics(SM, data, ack, Tuple) ->
  [Src, Dst, Payload] = getv([src, dst, payload], Tuple),
  [Hops, Ack_Pkg_ID] = extract_response([hops, id], Payload),
  Ack_tuple = {Ack_Pkg_ID, Dst, Src},
  fill_statistics(SM, ack, delivered, Hops, Ack_tuple);
fill_statistics(SM, data, _, Tuple) ->
  Local_Address = share:get(SM, local_address),
  Q = share:get(SM, statistics_queue),
  [Src, Dst] = getv([src, dst], Tuple),

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

fill_sq_ack(SM, _, _, _, _, not_inside,  {[],[]}, _NQ) ->
  SM;
fill_sq_ack(SM, _, _, _, _, inside,  {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
fill_sq_ack(SM, State, Hops, Time, Ack_tuple, Inside, Q, NQ) ->
  {PkgID, Src, Dst} = Ack_tuple,
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Delivered_handler =
  fun (LSM, STime, RTime, Role, QState, Tuple) ->
      [QPkgID, QSrc, QDst] = getv([id, src, dst], Tuple),
      if QPkgID == PkgID, QSrc == Src, QDst == Dst ->
        PQ = queue_push(NQ, {STime, RTime, Role, Time, QState, Hops, Tuple}, ?Q_STATISTICS_SIZE),
        fill_sq_ack(LSM, State, Hops, Time, Ack_tuple, inside, Q_Tail, PQ);
      true ->
        PQ = queue_push(NQ, Q_Tuple, ?Q_STATISTICS_SIZE),
        fill_sq_ack(LSM, State, Hops, Time, Ack_tuple, Inside, Q_Tail, PQ)
      end
  end,
  case Q_Tuple of
    {STime, RTime, Role, _, _, _, Tuple} when State == delivered_on_src ->
      Delivered_handler(SM, STime, RTime, Role, delivered, Tuple);
    {STime, RTime, Role, _, no_info, 0, Tuple} ->
      Delivered_handler(SM, STime, RTime, Role, State, Tuple);
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
  [Flag, PkgID, TTL, Src, Dst, Payload] = getv([flag, id, ttl, src, dst, payload], Tuple),
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  {_, _, _, _, _, _, STuple} = Q_Tuple,
  [QFlag, QPkgID, QTTL, QSrc, QDst, QPayload] = getv([flag, id, ttl, src, dst, payload], STuple),
  if QFlag == Flag, QPkgID == PkgID, QSrc == Src,
     QDst == Dst, QPayload == Payload, TTL < QTTL ->
      PQ = queue_push(NQ, {empty, empty, Role, 0, no_info, 0, Tuple}, ?Q_STATISTICS_SIZE),
      fill_sq_helper(SM, Role, Tuple, inside, Q_Tail, PQ);
  true ->
      PQ = queue_push(NQ, Q_Tuple, ?Q_STATISTICS_SIZE),
      fill_sq_helper(SM, Role, Tuple, Inside, Q_Tail, PQ)
  end.

set_processing_time(SM, Type, Tuple) ->
  Q = share:get(SM, statistics_queue),
  set_pt_helper(SM, Type, Tuple, Q, queue:new()).

set_pt_helper(SM, _Type, _Tuple, {[],[]}, NQ) ->
  share:put(SM, statistics_queue, NQ);
set_pt_helper(SM, Type, Tuple, Q, NQ) ->
  [Flag, PkgID, Src, Dst, Payload] = getv([flag, id, src, dst, payload], Tuple),
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Current_Time = erlang:monotonic_time(milli_seconds),

  Push_queue =
  fun (LSM, PTuple) ->
      PQ = queue_push(NQ, PTuple, ?Q_STATISTICS_SIZE),
      set_pt_helper(LSM, Type, Tuple, Q_Tail, PQ)
  end,

  {Send_Time, Recv_Time, Role, Duration, State, Hops, STuple} = Q_Tuple,
  [QFlag, QPkgID, QSrc, QDst, QPayload] = getv([flag, id, src, dst, payload], STuple),

  Time_handler =
  fun (LSM, transmitted, dst_reached) when QSrc == Dst, QDst == Src ->
          PkgID_handler =
          fun (Id) when QPkgID == Id ->
                Recv_Tuple = replace([src, dst], [Dst, Src], STuple),
                Statistic = {Current_Time, Recv_Time, destination, Duration, State, Hops, Recv_Tuple},
                Push_queue(LSM, Statistic);
              (_) ->
                Push_queue(LSM, Q_Tuple)
          end,
          PkgID_handler(extract_response(id, Payload));
        (LSM, transmitted, _) when QPkgID == PkgID, QSrc == Src, QDst == Dst,
                                   QFlag == Flag, QPayload == Payload ->
            Statistic = {Current_Time, Recv_Time, Role, Duration, State, Hops, Tuple},
            Push_queue(LSM, Statistic);
        (LSM, received, F) when F =/= dst_reached, QPkgID == PkgID, QSrc == Src,
                                QDst == Dst, QFlag == Flag, QPayload == Payload ->
            Statistic = {Send_Time, Current_Time, Role, Duration, State, Hops, Tuple},
            Push_queue(LSM, Statistic);
        (LSM, _, _) ->
            Push_queue(LSM, Q_Tuple)
  end,

  Time_handler(SM, Type, Flag).

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
      Total = share:get(SM, nothing, paths_total_count, 0),
      Paths =
        lists:map(fun(Path) ->
                    Count = share:get(SM, nothing, Path, 0),
                    {Path, Count, Total}
                  end, share:get(SM, nothing, paths, [])),
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
                      [Src, Dst, Payload] = getv([src, dst, payload], Tuple),
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
                      [TTL, Src, Dst, Payload] = getv([ttl, src, dst, payload], Tuple),
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
%-------------------------------------------------------------
process_async_status({status, Status, Reason}) ->
  case Status of
    'INITIATION' when Reason == 'LISTEN'-> initiation_listen;
    'INITIATION' -> busy_online;
    'ONLINE'-> busy_online;
    'OFFLINE' -> busy_online;
    'BACKOFF' -> busy_backoff;
    'BUSY' when Reason == 'BACKOFF' -> busy_backoff;
    'BUSY' -> busy_online
  end.