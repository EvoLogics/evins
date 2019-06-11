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

-module(burst_nl_hf). % additional network layer helper functions for burst data
-compile({parse_transform, pipeline}).

-import(lists, [filter/2, foldl/3, map/2, member/2]).

-include("fsm.hrl").
-include("nl.hrl").

-export([create_nl_burst_header/2, extract_nl_burst_header/2]).
-export([geta/1, getv/2, create_default/0, replace/3]).
-export([check_routing_existance/1]).
-export([update_statistics_tolerant/3, get_statistics_data/1]).
-export([burst_len/1, increase_local_pc/2]).
-export([get_packets/1, pop_delivered/2, failed_pc/2, remove_packet/2, remove_packet/4]).
-export([bind_pc/3, check_dublicated/2, encode_ack/2, try_extract_ack/2]).

%----------------------------- Get from tuple ----------------------------------
geta(Tuple) ->
  getv([flag, id_at, id_local, id_remote, src, dst, len, whole_len, payload], Tuple).
getv(_, empty) -> nothing;
getv(Types, Tuple) when is_list(Types) ->
  lists:foldr(fun(Type, L) -> [getv(Type, Tuple) | L] end, [], Types);
getv(Type, Tuple) when is_atom(Type) ->
  PT =
  case Tuple of {_Retries, T} -> T; _-> Tuple end,
  {Flag, PkgID, PkgIDLocal, PkgIDRemote, Src, Dst, Len, Whole_len, Payload} = PT,

  Structure =
  [{flag, Flag}, {id_at, PkgID}, {id_local, PkgIDLocal}, {id_remote, PkgIDRemote},
   {src, Src}, {dst, Dst},
   {len, Len}, {whole_len, Whole_len}, {payload, Payload}
  ],
  Map = maps:from_list(Structure),
  {ok, Val} = maps:find(Type, Map),
  Val.

create_default() ->
  {data, unknown, 0, 0, 0, 0, 0, 0, <<"">>}.

replace(Types, Values, Tuple) when is_list(Types) ->
  replace_helper(Types, Values, Tuple);
replace(Type, Value, Tuple) when is_atom(Type) ->
  {Flag, PkgID, PkgIDLocal, PkgIDRemote, Src, Dst, Len, Whole_len, Payload} = Tuple,
  Structure =
  [{flag, Flag}, {id_at, PkgID}, {id_local, PkgIDLocal}, {id_remote, PkgIDRemote},
   {src, Src}, {dst, Dst},
   {len, Len}, {whole_len, Whole_len}, {payload, Payload}
  ],
  list_to_tuple(lists:foldr(
  fun({X, _V}, L) when X == Type -> [Value | L];
     ({_X, V}, L) ->  [V | L]
  end, [], Structure)).

replace_helper([], _, Tuple) -> Tuple;
replace_helper([Type | Types], [Value | Values], Tuple) ->
  replace_helper(Types, Values, replace(Type, Value, Tuple)).

%-------------------- Encoding / Decoding data --------------------------------
encode_ack(SM, Acks) ->
  C_Bits_Flag = nl_hf:count_flag_bits(?FLAG_MAX),
  Flag_Num = ?FLAG2NUM(ack),
  B_Flag = <<Flag_Num:C_Bits_Flag>>,

  Len = length(Acks),
  Max_addr = lists:max(Acks),

  B_Len_Burst = <<Len:8>>,
  Max_addr_len = nl_hf:count_flag_bits(?PKG_ID_MAX),
  B_Max_addr = <<Max_addr:Max_addr_len>>,

  Bitmask_default = <<0:Max_addr>>,
  Bitmask_coded =
  lists:foldr(fun(X, A) ->
    Len_mask = bit_size(Bitmask_default),
    Before = Len_mask - X,
    After = Len_mask - Before - 1,
    if Before == 0 -> <<_:1,BN2:After>> = A, <<1:1, BN2:After>>;
      true -> <<BN1:Before,_:1,BN2:After>> = A, <<BN1:Before, 1:1, BN2:After>>
    end
  end, Bitmask_default, Acks),
  Tmp_Data = <<B_Flag/bitstring, B_Len_Burst/bitstring, B_Max_addr/bitstring, Bitmask_coded/bitstring>>,
  ?INFO(?ID, "encode_ack ~p ~w encoded len ~p~n", [Len, Acks, byte_size(Bitmask_coded)]),
  Is_binary = nl_hf:check_binary(Tmp_Data),
  if not Is_binary ->
    Add = nl_hf:add_bits(Tmp_Data),
    <<B_Flag/bitstring, B_Len_Burst/bitstring, B_Max_addr/bitstring, 0:Add, Bitmask_coded/bitstring>>;
  true ->
    Tmp_Data
  end.

try_extract_ack(SM, Payload) ->
  try
    C_Bits_Flag = nl_hf:count_flag_bits(?FLAG_MAX),
    C_Bits_PkgId = nl_hf:count_flag_bits(?PKG_ID_MAX),

    <<Flag_Num:C_Bits_Flag, Count:8, _B_Max_addr:C_Bits_PkgId, Rest/bitstring>> = Payload,
    ?INFO(?ID, "try_extract_ack ~p ~p ~p~n", [Flag_Num, Count, Rest]),
    L_bits = [N || <<N:1>> <= Rest],
    {_, Acks} = lists:foldr( fun(X, {I, A}) -> NA = if X =/= 0 -> [ I + 1| A]; true -> A end, {I + 1, NA}  end, {0, []}, L_bits),

    ?INFO(?ID, "extracted acks ~w ~n", [Acks]),
    ack = nl_hf:num2flag(Flag_Num, nl),
    Count = length(Acks),
    [Count, lists:reverse(Acks)]
  catch error: _Reason ->
    []
  end.

create_nl_burst_header(SM, T) ->
  [Flag, RPkgID, Src, Dst, Len, Whole_len, Payload] =
    getv([flag, id_remote, src, dst, len, whole_len, payload], T),

  Flag_Num = ?FLAG2NUM(Flag),
  Max = share:get(SM, max_burst_len),
  C_Bits_PkgID = nl_hf:count_flag_bits(?PKG_ID_MAX),
  C_Bits_Addr = nl_hf:count_flag_bits(?ADDRESS_MAX),
  C_Bits_Len = nl_hf:count_flag_bits(Max),
  C_Bits_Flag = nl_hf:count_flag_bits(?FLAG_MAX),

  B_RPkgID = <<RPkgID:C_Bits_PkgID>>,
  B_Len_Burst = <<Len:C_Bits_Len>>,
  B_Whole_Len_Burst = <<Whole_len:C_Bits_Len>>,
  B_Src = <<Src:C_Bits_Addr>>,
  B_Dst = <<Dst:C_Bits_Addr>>,
  B_Flag = <<Flag_Num:C_Bits_Flag>>,

  Tmp_Data = << B_Flag/bitstring, B_RPkgID/bitstring,
                B_Src/bitstring,
                B_Dst/bitstring, B_Len_Burst/bitstring,
                B_Whole_Len_Burst/bitstring, Payload/binary>>,

  Is_binary = nl_hf:check_binary(Tmp_Data),
  if not Is_binary ->
    Add = nl_hf:add_bits(Tmp_Data),
    ?INFO(?ID, "Add ~p~n", [Add]),

    <<B_Flag/bitstring, B_RPkgID/bitstring,
      B_Src/bitstring, B_Dst/bitstring,
      B_Len_Burst/bitstring,
      B_Whole_Len_Burst/bitstring, 0:Add, Payload/binary>>;
  true ->
    Tmp_Data
  end.

extract_nl_burst_header(SM, Payload) ->
  Max = share:get(SM, max_burst_len),
  C_Bits_Flag = nl_hf:count_flag_bits(?FLAG_MAX),
  C_Bits_PkgID = nl_hf:count_flag_bits(?PKG_ID_MAX),
  C_Bits_Addr = nl_hf:count_flag_bits(?ADDRESS_MAX),
  C_Bits_Len = nl_hf:count_flag_bits(Max),

  <<Flag_Num:C_Bits_Flag, RPkgID:C_Bits_PkgID,
    Src:C_Bits_Addr, Dst:C_Bits_Addr,
    Len:C_Bits_Len, Whole_len:C_Bits_Len, _Rest/bitstring>> = Payload,

    Flag = nl_hf:num2flag(Flag_Num, nl),
    Bits_header = C_Bits_Flag + C_Bits_PkgID + 2 * C_Bits_Addr +
                  2 * C_Bits_Len,
    Data = nl_hf:cut_add_bits(Bits_header, Payload),
    Tuple = create_default(),
    LocalPC = share:get(SM, local_pc),
    replace(
    [flag, id_local, id_remote, src, dst, len, whole_len, payload],
    [Flag, LocalPC, RPkgID, Src, Dst, Len, Whole_len, Data], Tuple).
%--------------------------------- Routing -------------------------------------
check_routing_existance(SM) ->
  Q_data = share:get(SM, nothing, burst_data_buffer, queue:new()),
  if Q_data == {[],[]} ->
    ?TRACE(?ID, "check_routing_existance : buffer empty ~n", []),
    false;
  true ->
    {{value, Q_Tuple}, _} = queue:out(Q_data),
    Dst = getv(dst, Q_Tuple),
    ?TRACE(?ID, "check_routing_existance to dst ~p~n", [Dst]),
    Exist = nl_hf:routing_exist(SM, Dst),
    {Exist, Dst}
  end.
%---------------------- Burst package handling ---------------------------------
bind_pc(SM, PC, Packet) ->
  [LocalPC, Dst, Payload] = getv([id_local, dst, payload], Packet),
  Q_data = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  NQ =
  lists:foldl(
  fun(X, Q) ->
    [XPC, XLocalPC, XDst, XPayload] = getv([id_at, id_local, dst, payload], X),
    NT = replace([id_at, payload], [PC, Payload], X),
    if XPC == unknown, LocalPC == XLocalPC, Dst == XDst, Payload == XPayload ->
      queue:in(NT, Q);
    true ->
      queue:in(X, Q)
    end
  end, queue:new(), Q_data),

  share:put(SM, burst_data_buffer, NQ).

pop_delivered(SM, PC) ->
  ?TRACE(?ID, "pop_delivered PC=~p ~n", [PC]),

  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  QL = queue:to_list(Q),

  NL =
  lists:filtermap(fun(X) ->
    XPC = getv(id_at, X),
    if XPC == PC -> false; true -> {true, X} end
  end, QL),

  NQ = queue:from_list(NL),
  [process_asyncs(__, PC),
    share:put(__, burst_data_buffer, NQ)
  ](SM).

failed_pc(SM, PC) ->
  Local_address = share:get(SM, local_address),
  QL = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  NQ =
  lists:foldl(
  fun(X, Q) ->
    [XPC, XLocalPC, XRemotePC, XSrc, XDst, XLen, XPayload] =
      getv([id_at, id_local, id_remote, src, dst, len, payload], X),

    RemotePC =
    if XSrc == Local_address -> XLocalPC; true -> XRemotePC end,
    Tuple =
    replace([id_local, id_remote, src, dst, len, payload],
            [XLocalPC, RemotePC, XSrc, XDst, XLen, XPayload],
    create_default()),

    if XPC == PC -> queue:in(Tuple, Q);
    true -> queue:in(X, Q)
    end
  end, queue:new(), QL),
  ?TRACE(?ID, "Failed PC ~p~n", [PC]),
  [process_asyncs(__, PC),
   share:put(__, burst_data_buffer, NQ)
  ](SM).

remove_packet(SM, Dst) ->
  QL = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  Local_address = share:get(SM, local_address),
  {NQ, Failed} =
  lists:foldl(
  fun(X, {Q, LF}) ->
    [PC, Src, D] = getv([id_local, src, dst], X),
    if Dst == D ->
      ?INFO(?ID, "Removed packet ~p to dst ~p LF ~p ~n", [PC, D, LF]),
      L = if Local_address == Src -> [PC | LF]; true -> LF end,
      {Q, L};
    true -> {queue:in(X, Q), LF}
    end
  end, {queue:new(), []}, QL),
  [cast_failed(__, Dst, Failed),
   share:put(__, burst_data_buffer, NQ)
  ](SM).

remove_packet(SM, Src, Dst, PC) ->
  QL = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  NQ =
  lists:foldl(
  fun(X, Q) ->
    [XPC, XSrc, XD] = getv([id_local, src, dst], X),
    if XPC == PC, XD == Dst, XSrc == Src ->
      ?INFO(?ID, "Removed packet PC ~p : ~p, ~p~n", [PC, XSrc, XD]),
      Q;
    true -> queue:in(X, Q)
    end
  end, queue:new(), QL),
  share:put(SM, burst_data_buffer, NQ).

cast_failed(SM, _, []) -> SM;
cast_failed(SM, Dst, [PC | T]) ->
  Local_address = share:get(SM, local_address),
  [burst_nl_hf:update_statistics_tolerant(__, state, {PC, src, failed}),
   fsm:cast(__, nl_impl, {send, {nl, failed, PC, Local_address, Dst}}),
   cast_failed(__, Dst, T)
  ](SM).

get_packets(SM) ->
  Routing_table = share:get(SM, routing_table),
  Q_data = share:get(SM, nothing, burst_data_buffer, queue:new()),
  Addr = get_first_addr(SM, Routing_table, Q_data),
  Packets = get_packets(SM, Q_data, Addr, []),
  if Packets == [] -> [0, nothing, []];
    true ->
      Whole_len = burst_len(Packets),
      NPackets =
      lists:foldl(fun(X, A) ->
                      P = replace(whole_len, Whole_len, X),
                      [P | A]
                  end, [], Packets),
      ?TRACE(?ID, "Burst data Whole len ~p~n", [Whole_len]),
      [H | T] = NPackets,
      [Whole_len, H, T]
  end.

check_dublicated(SM, Tuple) ->
  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  Dublicated = check_helper(Q, Tuple),
  ?INFO(?ID, "check_dublicated Tuple ~w - dublicated: ~w~n", [Tuple, Dublicated]),
  if not Dublicated ->
    share:put(SM, burst_data_buffer, queue:in(Tuple, Q));
  true -> SM
  end.

check_helper(inside) -> true.
check_helper({[],[]}, _Tuple) -> false;
check_helper(Q, Tuple) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  [Id, Src, Dst, Payload] = getv([id_remote, src, dst, payload], Tuple),
  [QId, QSrc, QDst, QPayload] = getv([id_remote, src, dst, payload], Q_Tuple),
  if Id == QId, Src == QSrc,
     Dst == QDst, Payload == QPayload ->
      check_helper(inside);
  true -> check_helper(Q_Tail, Tuple)
 end.

process_asyncs(SM, PC) ->
  PCS = share:get(SM, nothing, wait_async_pcs, []),
  ?INFO(?ID, ">>> delete PC ~w from ~w~n", [PC, PCS]),
  share:put(SM, wait_async_pcs, lists:delete(PC, PCS)).

get_first_addr(routing, T) -> getv(dst, T).
get_first_addr(_, _, {[],[]}) -> nothing;
get_first_addr(SM, Routing_table, Q) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Dst = getv(dst, Q_Tuple),
  Exist = nl_hf:routing_exist(SM, Dst),
  if Exist -> get_first_addr(routing, Q_Tuple);
     true ->  get_first_addr(SM, Routing_table, Q_Tail)
  end.

get_packets(_, Packets) -> Packets.
get_packets(_, {[],[]}, _, Packets) -> Packets;
get_packets(SM, Q, Addr, Packets) ->
  Max_queue = share:get(SM, max_queue),
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  [PC, Dst] = getv([id_at, dst], Q_Tuple),
  PCS = share:get(SM, nothing, wait_async_pcs, []),
  Member = lists:member(PC, PCS),
  Packet_handler =
  fun (LSM, A, L) when A == Dst, L =< Max_queue, not Member ->
        get_packets(LSM, Q_Tail, A, [Q_Tuple | Packets]);
      (LSM, A, _L) when A == Dst, not Member ->
        get_packets(LSM, [Q_Tuple | Packets]);
      (LSM, A, _L) ->
        get_packets(LSM, Q_Tail, A, Packets)
  end,
  Packet_handler(SM, Addr, length(Packets)).
%---------------------------- Burst additional ---------------------------------
burst_len(P) ->
    lists:foldr(fun (X, A) -> A + getv(len, X) end, 0, P).

increase_local_pc(SM, Name) ->
  PC = share:get(SM, Name),
  ?INFO(?ID, "Local PC ~p for ~p~n",[PC, Name]),
  if PC > ?PKG_ID_MAX - 1 ->
    share:put(SM, Name, 1);
  true ->
    share:put(SM, Name, PC + 1)
  end.

update_statistics_tolerant(SM, state, {PC, src, State}) ->
  QS = share:get(SM, nothing, statistics_tolerant, queue:new()),
  update_statistics_tolerant(SM, state, State, QS, queue:new(), PC);
update_statistics_tolerant(SM, time, T) ->
  Local_address = share:get(SM, local_address),
  QS = share:get(SM, nothing, statistics_tolerant, queue:new()),
  [PC_local, PC_remote, Src] =
    getv([id_local, id_remote, src], T),
  PC =
  if Local_address == Src -> PC_local; true -> PC_remote end,
  update_statistics_tolerant(SM, time, T, QS, queue:new(), PC).

update_statistics_tolerant(SM, _, _, {[],[]}, Q, _) ->
  share:put(SM, statistics_tolerant, Q);
update_statistics_tolerant(SM, Value, T, QS, Q, PC) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(QS),
  Hash = if Value == time ->
    Payload = getv(payload, T),
    <<H:16, _/binary>> = crypto:hash(md5,Payload),
    H;
  true -> nothing end,
  Time = erlang:monotonic_time(milli_seconds),
  QU =
  case Q_Tuple of
    {Role, PC, QHash, Len, _, unknown, Src, Dst} when Value == time, QHash == Hash->
      NT = {Role, PC, QHash, Len, from_start(SM, Time), sent, Src, Dst},
      queue:in(NT, Q);
    {Role, PC, QHash, Len, QTime, unknown, Src, Dst} when Value == state, T == failed ->
      Ack_time = from_start(SM, Time),
      Duration = (Ack_time - QTime) / 1000,
      NT = {Role, PC, QHash, Len, Duration, T, Src, Dst},
      queue:in(NT, Q);
    {Role, PC, QHash, Len, QTime, sent, Src, Dst} when Value == state ->
      Ack_time = from_start(SM, Time),
      Duration = (Ack_time - QTime) / 1000,
      ?INFO(?ID, "update_state ~p ~p ~p~n", [QTime, Ack_time, Duration]),
      NT = {Role, PC, QHash, Len, Duration, T, Src, Dst},
      queue:in(NT, Q);
    _ ->
      queue:in(Q_Tuple, Q)
  end,
  update_statistics_tolerant(SM, Value, T, Q_Tail, QU, PC).

from_start(_SM, Time) when Time == empty -> 0;
from_start(SM, Time) -> Time - share:get(SM, nl_start_time).

get_statistics_data(Q) when Q == {[],[]} -> empty;
get_statistics_data(Q) ->
  Data =
  lists:map(fun({Role, PC, Hash, Len, Duration, State, Src, Dst}) ->
                {Role, PC, Hash, Len, Duration, State, Src, Dst}
            end, queue:to_list(Q)),
  case Data of []  -> empty; _ -> Data end.
