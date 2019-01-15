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
-export([burst_len/1, increase_local_pc/2]).
-export([get_packets/1, pop_delivered/2, failed_pc/2]).
-export([bind_pc/3, check_dublicated/2]).

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

%-------------------- Encodeing / Decodinf data --------------------------------
create_nl_burst_header(SM, T) ->
  ?TRACE(?ID, "create_payload_nl_burst_header ~p~n", [T]),
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

    %[flag, id_local, src, dst, len, whole_len, payload],
    %[Flag, LPkgID, Src, Dst, Len, Whole_len, Data], Tuple).
%--------------------------------- Routing -------------------------------------
check_routing_existance(SM) ->
  Routing_table = share:get(SM, routing_table),
  Local_address = share:get(SM, local_address),
  Q_data = share:get(SM, nothing, burst_data_buffer, queue:new()),
  case Routing_table of
    ?ADDRESS_MAX -> [];
    _ ->
      lists:filtermap(
        fun({?ADDRESS_MAX, ?ADDRESS_MAX, _}) -> false;
           ({From, _, _}) when From =/= Local_address ->
              exist_data(Q_data, From);
           ({_ ,_ ,_}) -> false;
           (To) -> {true, {default, To}}
        end, Routing_table)
  end =/= [].

exist_data(Q, A) -> exist_data(Q, A, 0).
exist_data({[],[]}, _, 0) -> false;
exist_data({[],[]}, A, _) -> {true, A};
exist_data(Q, A, C) ->
  {{value, Q_Tuple}, Q_Tail} = queue:out(Q),
  Dst = getv(dst, Q_Tuple),
  if Dst == A -> exist_data(Q_Tail, A, C + 1);
    true -> exist_data(Q_Tail, A, C)
  end.

%---------------------- Burst package handling ---------------------------------
bind_pc(SM, PC, Packet) ->
  [LocalPC, Dst, Payload] = getv([id_local, dst, payload], Packet),
  Q_data = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  NQ =
  lists:foldl(
  fun(X, Q) ->
    [XPC, XLocalPC, XDst] = getv([id_at, id_local, dst], X),
    NT = replace([id_at, payload], [PC, Payload], X),
    if XPC == unknown, LocalPC == XLocalPC, Dst == XDst ->
      queue:in(NT, Q);
    true ->
      queue:in(X, Q)
    end
  end, queue:new(), Q_data),

  ?TRACE(?ID, "bind pc ~p~n", [NQ]),
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

  ?TRACE(?ID, "Pop delivered ~p ~p~n", [QL, NL]),
  [process_asyncs(__, PC),
    share:put(__, burst_data_buffer, NQ)
  ](SM).

failed_pc(SM, PC) ->
  QL = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  NQ =
  lists:foldl(
  fun(X, Q) ->
    [XPC, XLocalPC, XSrc, XDst, XLen, XPayload] =
      getv([id_at, id_local, src, dst, len, payload], X),
    Tuple =
    replace([id_local, src, dst, len, payload],
            [XLocalPC, XSrc, XDst, XLen, XPayload],
    create_default()),

    if XPC == PC -> queue:in(Tuple, Q);
    true -> queue:in(X, Q)
    end
  end, queue:new(), QL),
  ?TRACE(?ID, "Update failed ~p~n", [NQ]),
  [process_asyncs(__, PC),
   share:put(__, burst_data_buffer, NQ)
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
      ?TRACE(?ID, "Burst data Whole len ~p ~p~n", [Whole_len, NPackets]),
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
  Dst = getv(dst, Q_Tuple),

  Packet_handler =
  fun (LSM, A, L) when A == Dst, L < Max_queue ->
        get_packets(LSM, Q_Tail, A, [Q_Tuple | Packets]);
      (LSM, A, _L) when A == Dst ->
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
  if PC > 127 ->
    share:put(SM, Name, 1);
  true ->
    share:put(SM, Name, PC + 1)
  end.
