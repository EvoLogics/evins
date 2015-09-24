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
-module(nl_mac_hf). % network and mac layer helper functions

-import(lists, [filter/2, foldl/3, map/2, member/2]).

-include("fsm.hrl").
-include("nl.hrl").

%% Convert types functions
-export([convert_to_binary/1, covert_type_to_bin/1, convert_t/2, convert_la/3]).
%% ETS functions
-export([insertETS/3, readETS/2, cleanETS/2, init_dets/1, fill_dets/1]).
%% handle events
-export([event_params/3, clear_spec_timeout/2]).
%% Math functions
-export([rand_float/2, lerp/3]).
%% Addressing functions
-export([init_nl_addrs/1, add_to_table/3, get_dst_addr/1, set_dst_addr/2]).
-export([addr_nl2mac/2, addr_mac2nl/2, get_routing_addr/3, num2flag/2, flag2num/1]).
%% Send NL functions
-export([send_nl_command/4, send_ack/3, send_path/2, send_helpers/4, send_cts/6, send_mac/4, fill_msg/2]).
%% Parse NL functions
-export([prepare_send_path/3, parse_path/4, save_path/3]).
%% Process NL functions
-export([add_neighbours/4, process_pkg_id/3, proccess_relay/2, process_path_life/2, neighbours_to_bin/2, routing_to_bin/1, check_dubl_in_path/2]).
%% RTT functions
-export([getRTT/2, smooth_RTT/3]).
%% command functions
-export([process_command/2, save_stat/2, update_states_list/1]).
%% Only MAC functions
-export([process_rcv_payload/3, parse_paylod/1, process_send_payload/2, process_retransmit/3]).
%% Other functions
-export([bin_to_num/1, increase_pkgid/1, add_item_to_queue/4, analyse/4]).
%%--------------------------------------------------- Convert types functions -----------------------------------------------
convert_to_binary([])     -> nothing;
convert_to_binary([H])    -> list_to_binary(string:to_upper(atom_to_list(H)));
convert_to_binary([H|T])  ->
  Header =
  case H of
    at    -> list_to_binary(["AT"]);
    nl    -> list_to_binary(["NL,"]);
    error -> list_to_binary(["ERROR "]);
    busy  -> list_to_binary(["BUSY "]);
    _     -> list_to_binary([string:to_upper(atom_to_list(H)), ","])
  end,
  Last_el = hd(lists:reverse(T)),
  list_to_binary([Header,
                  lists:foldr(fun(X, A) ->
                                  Bin = covert_type_to_bin(X),
                                  Sign = if X =:= Last_el -> ""; true -> "," end,
                                  [list_to_binary([Bin, Sign]) | A]
                              end, [], T)]).

covert_type_to_bin(X) ->
  case X of
    X when is_integer(X)   -> integer_to_binary(X);
    X when is_float(X)     -> list_to_binary(lists:flatten(io_lib:format("~.1f",[X])));
    X when is_bitstring(X) -> X;
    X when is_binary(X)    -> X;
    X when is_atom(X)      -> list_to_binary(atom_to_list(X));
    X when is_list(X)      -> list_to_binary(X);
    _            -> error_convert
  end.

convert_t(Val, T) ->
  case T of
    {us, s} -> Val / 1000000;
    {s, us} -> Val * 1000000
  end.

%%--------------------------------------------------- ETS functions -----------------------------------------------
insertETS(SM, Term, Value) ->
  cleanETS(SM, Term),
  case ets:insert(SM#sm.share, [{Term, Value}]) of
    true  -> SM;
    false -> insertETS(SM, Term, Value)
  end.

readETS(SM, Term) ->
  case ets:lookup(SM#sm.share, Term) of
    [{Term, Value}] -> Value;
    _     -> not_inside
  end.

cleanETS(SM, Term) -> ets:match_delete(SM#sm.share, {Term, '_'}).

%%--------------------------------------------------- Handle events functions -----------------------------------------------
event_params(SM, Term, Event) ->
  if SM#sm.event_params =:= [] ->
       [Term, SM];
     true ->
       EventP = hd(tuple_to_list(SM#sm.event_params)),
       if EventP =:= Event -> [SM#sm.event_params, SM#sm{event_params = []}];
          true -> [Term, SM]
       end
  end.

clear_spec_timeout(SM, Spec) ->
  TRefList = filter(
               fun({E, TRef}) ->
                   case E of
                     {Spec, _} -> timer:cancel(TRef), false;
                     _  -> true
                   end
               end, SM#sm.timeouts),
  SM#sm{timeouts = TRefList}.

%%--------------------------------------------------- Math functions -----------------------------------------------
rand_float(SM, Random_interval) ->
  {Start, End} = readETS(SM, Random_interval),
  (Start + random:uniform() * (End - Start)) * 1000.

lerp(A, B, F) -> A + F * (B - A).

%%-------------------------------------------------- Send NL functions -------------------------------------------
send_helpers(SM, Interface, MACP, Flag) ->
  {at, PID, SENDFLAG, IDst, TFlag, _} = MACP,
  Data=
  case Flag of
    tone -> <<"t">>;
    rts   ->
      C = readETS(SM, sound_speed),
      U =
      case Val = readETS(SM, {u, IDst}) of
        % max distance between nodes in the network, in m
        not_inside -> readETS(SM, u);
        _      -> Val
      end,
      T_us = erlang:round( convert_t( (U / C), {s, us}) ), % to us
      integer_to_binary(T_us);
    warn ->
      <<"w">>
  end,
  Tuple = {at, PID, SENDFLAG, IDst, TFlag, Data},
  send_mac(SM, Interface, Flag, Tuple).

send_cts(SM, Interface, MACP, Timestamp, USEC, Dur) ->
  {at, PID, _, IDst, _, _} = MACP,
  Tuple = {at, PID,"*SENDIMS", IDst, Timestamp + USEC, covert_type_to_bin(Dur + USEC)},
  send_mac(SM, Interface, cts, Tuple).

send_mac(SM, _Interface, Flag, MACP) ->
  AT = mac2at(Flag, MACP),
  fsm:send_at_command(SM, AT).
  %SM1 = fsm:cast(SM, Interface, {send, AT}),
  %fsm:set_event(SM1, eps).

send_ack(SM,  {send_ack, {_, [Packet_id, _, _PAdditional]}, {async, {nl, recv, Real_dst, Real_src, _}}}, Count_hops) ->
  send_nl_command(SM, alh, {ack, [Packet_id, Real_src, []]}, {nl, send, Real_dst, integer_to_binary(Count_hops)}).

send_path(SM, {send_path, {Flag, [Packet_id, _, _PAdditional]}, {async, {nl, recv, Real_dst, Real_src, Payload}}}) ->
  BMAC_addr  = convert_la(SM, bin, mac),
  case readETS(SM, current_neighbours) of
    not_inside -> error;
    _ ->
      BCN = neighbours_to_bin(SM, mac),
      [SMN, BMsg] =
      case Flag of
        neighbours ->
          [SM, fill_msg(?NEIGHBOUR_PATH, {BCN, BMAC_addr})];
        Flag ->
          [SMNTmp,BPath] =
          case Flag of
            path_addit -> parse_path(SM, Flag, ?PATH_ADDIT,  {Real_src, Real_dst, Payload});
            path     -> parse_path(SM, Flag, ?NEIGHBOUR_PATH, {Real_src, Real_dst, Payload})
          end,
          CheckL = lists:foldr(fun(X, A)-> [bin_to_num(X) | A] end, [], split_bin_comma(BPath)),
          NBPath =
          case lists:member(BMAC_addr, CheckL) of
            true  -> path_to_bin_comma(lists:reverse(split_bin_comma(check_dubl_in_path(BPath, BMAC_addr))));
            false -> path_to_bin_comma(lists:reverse(split_bin_comma(check_dubl_in_path(BPath, BMAC_addr))))
          end,
          analyse(SM, paths, NBPath, {Real_src, Real_dst}),
          ListPath = lists:foldr(fun(X,A)-> [bin_to_num(X)| A] end, [], split_bin_comma(NBPath)),
          proccess_and_update_path(SM, NBPath, {Real_src, Real_dst, ListPath} ),
          [SMNTmp, fill_msg(?NEIGHBOUR_PATH, {BCN, NBPath})]
      end,
      send_nl_command(SMN, alh, {path, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BMsg})
  end.

path_to_bin_comma(LPath) ->
  lists:foldr(
    fun(X, A) ->
        Sign =
        if byte_size(A) =:= 0 -> <<"">>; true-> <<",">> end,
        <<X/binary, Sign/binary, A/binary>>
    end, <<"">>, LPath).

send_nl_command(SM, Interface, {Flag, [IPacket_id, Real_src, _PAdditional]}, NL) ->
  Real_dst = get_dst_addr(NL),
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  if Real_dst =:= wrong_format -> error;
     true ->
       Rout_addr = get_routing_addr(SM, Flag, Real_dst),
       [MAC_addr, MAC_real_src, MAC_real_dst] = addr_nl2mac(SM, [Rout_addr, Real_src, Real_dst]),
       ?TRACE(?ID, "Rout_addr ~p, MAC_addrm ~p, MAC_real_src ~p, MAC_real_dst ~p~n", [Rout_addr, MAC_addr, MAC_real_src, MAC_real_dst]),
       if ((MAC_addr =:= error) or (MAC_real_src =:= error) or (MAC_real_dst =:= error)
           or ((MAC_real_dst =:= 255) and Protocol#pr_conf.br_na)) ->
            error;
          true ->
            NLarp = set_dst_addr(NL, MAC_addr),
            AT = nl2at(SM, {Flag, integer_to_binary(IPacket_id), integer_to_binary(MAC_real_src), integer_to_binary(MAC_real_dst), NLarp}),
            if NLarp =:= wrong_format -> error;
               true ->
                 ?TRACE(?ID, "Send AT command ~p~n", [AT]),
                 Local_address = readETS(SM, local_address),
                 CurrentRTT = {rtt, Local_address, Real_dst},
                 ?TRACE(?ID, "CurrentRTT sending AT command ~p~n", [CurrentRTT]),
                 insertETS(SM, {last_nl_sent_time, CurrentRTT}, erlang:now()),
                 insertETS(SM, last_nl_sent, {Flag, Real_src, NLarp}),
                 insertETS(SM, ack_last_nl_sent, {IPacket_id, Real_src, Real_dst}),
                 SM1 = fsm:cast(SM, Interface, {send, AT}),
                 %!!!!
                 fsm:cast(SM, nl, {send, AT}),
                 fill_dets(SM),
                 fsm:set_event(SM1, eps)
            end
       end
  end.

mac2at(Flag, Tuple) when is_tuple(Tuple)->
  case Tuple of
    {at, PID, SENDFLAG, IDst, TFlag, Data} ->
      NewData = list_to_binary([flag2num(Flag), ",", Data]),
      {at, PID, SENDFLAG, IDst, TFlag, NewData};
    _ ->
      error
  end.
nl2at (SM, Tuple) when is_tuple(Tuple)->
  ETSPID =  list_to_binary(["p", integer_to_binary(readETS(SM, pid))]),
  case Tuple of
    {Flag, BPacket_id, MAC_real_src, MAC_real_dst, {nl, send, IDst, Data}}  ->
      NewData = list_to_binary([flag2num(Flag), ",", BPacket_id, ",", MAC_real_src, ",", MAC_real_dst, ",", Data]),
      {at,"*SENDIM", ETSPID, byte_size(NewData), IDst, noack, NewData};
    _ ->
      error
  end.

check_dubl_in_path(BPath, BMAC_addr) ->
  CheckL = lists:foldr(fun(X, A)-> [bin_to_num(X) | A] end, [], split_bin_comma(BPath)),
  case lists:member(binary_to_integer(BMAC_addr), CheckL) of
    true  -> BPath;
    false -> list_to_binary([BPath, ",", BMAC_addr])
  end.

%%-------------------------------------------------- Addressing functions -------------------------------------------
flag2num(Flag) when is_atom(Flag)->
  integer_to_binary(?FRAG2NUM(Flag)).

num2flag(Num, Layer) when is_integer(Num)->
  ?NUM2FLAG(Num, Layer);
num2flag(Num, Layer) when is_binary(Num)->
  ?NUM2FLAG(binary_to_integer(Num), Layer).

init_nl_addrs(SM) ->
  lists:map(fun(X)-> add_to_table(SM, table_nl_mac_addrs, X) end, ?TABLE_LADDR_MACADDR).

add_to_table(SM, Table_name, El) ->
  Table = readETS(SM, Table_name),
  if Table =:= not_inside -> insertETS(SM, Table_name, []); true -> nothing end,
  insertETS(SM, Table_name, [El | readETS(SM, Table_name)]).

get_dst_addr(NL) ->
  case NL of
    {nl, send, IDst,_}  -> IDst;
    {at, _, _, IDst, _, _}  -> IDst;
    _   -> wrong_format
  end.

set_dst_addr(NL, Addr) ->
  case NL of
    {nl, send,_, Data} -> {nl, send, Addr, Data};
    _   -> wrong_format
  end.

addr_nl2mac(SM, ListAddr) when is_list(ListAddr) ->
  lists:foldr(fun(X, A) -> [addr_nl2mac(SM, X) | A] end, [], ListAddr);
addr_nl2mac(SM, SAddr) ->
  F = fun(Elem, Acc) ->
          {NL_addr, Mac_addr} = Elem,
          if SAddr =:= NL_addr -> [Mac_addr | Acc]; true -> Acc end
      end,
  MAC_addr = lists:foldr(F, [], readETS(SM, table_nl_mac_addrs)),
  if MAC_addr =:= [] -> error;
     true -> [Addr] = MAC_addr, Addr
  end.

addr_mac2nl(SM, ListAddr) when is_list(ListAddr) ->
  lists:foldr(fun(X, A) -> [addr_mac2nl(SM, X) | A] end, [], ListAddr);
addr_mac2nl(SM, SAddr) ->
  F = fun(Elem, Acc) ->
          {Nl_addr, Mac_addr} = Elem,
          if SAddr =:= Mac_addr -> [Nl_addr | Acc]; true -> Acc end
      end,
  NL_addr = lists:foldr(F, [], readETS(SM, table_nl_mac_addrs)),
  if NL_addr =:= [] -> error; true -> [Addr] = NL_addr, Addr end.

get_routing_addr(SM, Flag, AddrSrc) ->
  NProtocol = readETS(SM, np),
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  Routing_table = readETS(SM, routing_table),
  case NProtocol of
    NProtocol when ((NProtocol =:= staticr) or (NProtocol =:= staticrack)
                    or (Protocol#pr_conf.pf and ((Flag =:= data) or (Flag =:= ack)))
                    or ( (Protocol#pr_conf.lo or Protocol#pr_conf.dbl) and (Flag =:= path)) ) ->
      find_in_routing_table(Routing_table, AddrSrc);
    _ ->  255
  end.

find_in_routing_table(255, _) -> 255;
find_in_routing_table([], _) -> no_routing_table;
find_in_routing_table(Routing_table, AddrSrc) ->
  lists:foldr(
    fun(X, El) ->
      if is_tuple(X) -> case X of {AddrSrc, To} -> To; _-> El end;
         true -> X
      end
    end, no_routing_table, Routing_table).

convert_la(SM, Type, Format) ->
  LAddr  = readETS(SM, local_address),
  CLAddr =
  case Format of
    nl -> LAddr;
    mac -> addr_nl2mac(SM, LAddr)
  end,
  case Type of
    bin -> integer_to_binary(CLAddr);
    integer -> CLAddr
  end.

%%-------------------------------------------------- Parse NL functions -------------------------------------------
fill_msg(Format, Tuple) ->
  case Format of
    ?NEIGHBOURS ->
      list_to_binary(["n:", Tuple]);
    ?NEIGHBOUR_PATH ->
      {Neighbours, Path} = Tuple,
      list_to_binary(["n:", Neighbours, ",p:", Path]);
    ?PATH_DATA ->
      {Path, Data} = Tuple,
      list_to_binary(["p:", Path, ",d:", Data]);
    ?PATH_ADDIT ->
      {Path, Additional} = Tuple,
      list_to_binary(["p:", Path, ",a:", Additional])
  end.

prepare_send_path(SM, [_ , _, PAdditional], {async,{nl,recv, Real_dst, Real_src, Payload}}) ->
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  BMAC_addr = convert_la(SM, bin, mac),
  {nl,send, IDst, Msg} = readETS(SM, current_pkg),

  [SM1, BPath] = parse_path(SM, path, ?NEIGHBOUR_PATH, {Real_src, Real_dst, Payload}),
  NPath =
  if Protocol#pr_conf.br_na ->
       NPayl = fill_msg(?NEIGHBOUR_PATH, {get_current_neighbours(SM), check_dubl_in_path(BPath, BMAC_addr)}),
       [_, NPTmp] = parse_path(SM, path, ?NEIGHBOUR_PATH, {Real_src, Real_dst, NPayl}),
       NPTmp;
     true -> BPath end,
  case get_routing_addr(SM, path, Real_dst) of
    255 -> nothing;
    _ -> analyse(SM1, paths, NPath, {Real_src, Real_dst})
  end,
  SDParams = {data, [increase_pkgid(SM), readETS(SM, local_address), PAdditional]},
  SDTuple = {nl,send, IDst, fill_msg(?PATH_DATA, {NPath, Msg})},
  case check_path(SM1, Real_src, Real_dst, NPath) of
    true  -> [SM1, SDParams, SDTuple];
    false -> [SM1, path_not_completed]
  end.

%% check path if it is completed, Src and Dst exist
check_path(SM, Real_src, Real_dst, BPath) ->
  IDst = addr_nl2mac(SM, Real_dst),
  ISrc = addr_nl2mac(SM, Real_src),
  ListPath  = lists:foldr(fun(X, A)-> [binary_to_integer(X) | A] end, [], split_bin_comma(BPath)),
  (lists:member(IDst, ListPath) and lists:member(ISrc, ListPath)).

parse_path(SM, Flag, Temp, {ISrc, IDst, Payload}) ->
  BPath =
  case Flag of
    Flag when ((Flag =:= path) or (Flag =:= path_addit)) ->
      case re:run(Payload, Temp, [dotall,{capture,[1,2],binary}]) of
        {match, Bin} ->
          case Temp of
            ?NEIGHBOUR_PATH -> [_, P] = Bin, P;
            ?PATH_ADDIT -> [P, _] = Bin, P
          end;
        nomatch -> nothing
      end;
    data ->
      case re:run(Payload,?PATH_DATA,[dotall,{capture,[1,2],binary}]) of
        {match, [PPath, _]} ->
          ?INFO(?ID, "+++ Got data with path: ~p~n", [PPath]), PPath;
        nomatch ->
          nothing
      end
  end,
  if BPath =:= nothing -> [SM, nothing];
     true ->
       MacLAddr = convert_la(SM, integer, mac),
       ListPath = lists:foldr(fun(X, A)-> [bin_to_num(X) | A] end, [], split_bin_comma(BPath)),
       case lists:member(MacLAddr, ListPath) of
         true  -> proccess_and_update_path(SM, BPath, {ISrc, IDst, ListPath});
         false -> [SM, BPath]
       end
  end.

add_neighbours(SM, Flag, NLSrcAT, {RealSrc, Real_dst}) ->
  ?INFO(?ID, "+++ Flag ~p, NLSrcAT ~p, RealSrc ~p~n", [Flag, NLSrcAT, RealSrc]),
  Current_neighbours = readETS(SM, current_neighbours),
  SM1 = fsm:set_timeout(SM, {s, readETS(SM, neighbour_life)}, {neighbour_life, NLSrcAT}),
  analyse(SM1, st_neighbours, NLSrcAT, {RealSrc, Real_dst}),
  case Current_neighbours of
    not_inside -> insertETS(SM1, current_neighbours, [NLSrcAT]);
    _ ->
      case lists:member(NLSrcAT, Current_neighbours) of
        true -> SM1;
        false -> insertETS(SM1, current_neighbours, [NLSrcAT | Current_neighbours])
      end
  end.

%%-------------------------------------------------- Proccess NL functions -------------------------------------------
proccess_relay(SM, Tuple = {send, Params = {Flag,[_,ISrc,PAdditional]}, {nl, send, IDst, Payload}}) ->
  BMAC_addr = convert_la(SM, bin, mac),
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  case Flag of
    data when (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) ->
      {match, [BPath, BData]} = re:run(Payload, ?PATH_DATA, [dotall,{capture, [1, 2], binary}]),
      NPayload = fill_msg(?PATH_DATA, {check_dubl_in_path(BPath, BMAC_addr), BData}),
      [SMN1, _] = parse_path(SM, Flag, ?PATH_DATA, {ISrc, IDst, NPayload}),
      [SMN1, {send, Params, {nl, send, IDst, NPayload}}];
    data ->
      [SMN, _] = parse_path(SM, Flag, ?PATH_DATA, {ISrc, IDst, Payload}),
      [SMN, Tuple];
    neighbours ->
      case LNeighbours = get_current_neighbours(SM) of
        no_neighbours ->
          [SM, not_relay];
        _ ->
          [SM, {send, Params, {nl, send, IDst, fill_msg(?NEIGHBOURS, LNeighbours)}}]
      end;
    path_addit when Protocol#pr_conf.evo ->
      {match, [BPath, AParams]} = re:run(Payload, ?PATH_ADDIT, [dotall, {capture, [1, 2], binary}]),
      [BRssi, BIntegr] = split_bin_comma(AParams),
      DIRssi = bin_to_num(BRssi),
      DIIntegr = bin_to_num(BIntegr),
      [IRcvRssi, IRcvIntegr] = PAdditional,
      ?INFO(?ID, "+++ IRcvRssi ~p, IRcvIntegr ~p ~n", [IRcvRssi, IRcvIntegr]),
      RcvRssi = (-1) * IRcvRssi,
      %% if ((IRcvIntegr < 100) or (RcvRssi < 30)) -> [SM, not_relay]; % add to weak signals
      if (IRcvIntegr < 90) ->
           [SM, not_relay]; % add to weak signals
         true ->
           AvRssi = if DIRssi =:= 0 -> RcvRssi; true -> (DIRssi + RcvRssi) / 2 end,
           AvIntegr = if DIIntegr =:= 0 -> IRcvIntegr; true -> (DIIntegr + IRcvIntegr) / 2 end,
           RssiIntegrParams = list_to_binary([covert_type_to_bin(AvRssi), ",", covert_type_to_bin(AvIntegr)]),
           [SM, {send, Params, {nl, send, IDst, fill_msg(?PATH_ADDIT, {check_dubl_in_path(BPath, BMAC_addr), RssiIntegrParams})}}]
      end;
    path_addit ->
      {match, [BPath,_]} = re:run(Payload,?PATH_ADDIT,[dotall,{capture,[1,2],binary}]),
      [SM, {send, Params, {nl, send, IDst, fill_msg(?PATH_ADDIT, {check_dubl_in_path(BPath, BMAC_addr), ""})}}];
    path ->
      case LNeighbours = get_current_neighbours(SM) of
        no_neighbours -> [SM, not_relay];
        _ ->
          Local_address = readETS(SM, local_address),
          MAC_addr = convert_la(SM, integer, mac),
          {match, [RNeighbours, BPath]} = re:run(Payload, ?NEIGHBOUR_PATH, [dotall, {capture, [1, 2], binary}]),
          ListNeighbours = lists:foldr(fun(X,A)-> [binary_to_integer(X)| A] end, [], split_bin_comma(RNeighbours)),
          ListPath  = lists:foldr(fun(X,A)-> [binary_to_integer(X)| A] end, [], split_bin_comma(BPath)),
          %% save path and set path life
          [SMN, _] = parse_path(SM, Flag, ?NEIGHBOUR_PATH, {ISrc, IDst, Payload}),
          %% check path, because of loopings (no dublicated addrs)
          Check_path = check_path(SM, ISrc, IDst, BPath),
          case (lists:member(MAC_addr, ListNeighbours)) of
            true when ((ISrc =/= Local_address) and (Protocol#pr_conf.lo or Protocol#pr_conf.dbl) and Check_path) ->
              [SMN, {send, Params, {nl, send, IDst, fill_msg(?NEIGHBOUR_PATH, {LNeighbours, BPath})}}];
            _ ->
              case (lists:member(MAC_addr, ListNeighbours) and not(lists:member(MAC_addr, ListPath ))) of
                true  when (ISrc =/= Local_address) ->
                  [SMN, {send, Params, {nl, send, IDst, fill_msg(?NEIGHBOUR_PATH, {LNeighbours, check_dubl_in_path(BPath, BMAC_addr)})}}];
                _ -> [SMN, not_relay]
              end
          end
      end;
    _ -> [SM, Tuple]
  end.

proccess_and_update_path(SM, BPath, {ISrc, IDst, ListPath}) ->
  LAddr = readETS(SM, local_address),
  NLListPath = lists:foldr(fun(X,A) -> [ addr_mac2nl(SM, X) | A] end, [], ListPath),
  MemberSrcL = lists:member(ISrc, NLListPath),
  MemberDstL = lists:member(IDst, NLListPath),
  NLSortListPath =
  case (MemberSrcL and MemberDstL) of
    true ->
      case lists:nth(1, NLListPath) of ISrc -> NLListPath; IDst -> lists:reverse(NLListPath) end;
    false when MemberSrcL ->
      NLListPath;
    false when MemberDstL ->
      lists:reverse(NLListPath)
  end,
  {LSrc, LDst} = lists:splitwith(fun(A) -> A =/= LAddr end, NLSortListPath),
  LengthLSrc  = length(LSrc),
  LengthLDst  = length(LDst),
  LRevSrc = lists:reverse(LSrc),
  SMN =
  case lists:member(LAddr, NLSortListPath) of
    true  when (( LengthLSrc =:= 1 ) and (LengthLDst =:= 1)) ->
      [SM1, NList] =
      if (ISrc =:= LAddr) -> proccess_rout_table(SM, LDst, IDst, []);
        true -> proccess_rout_table(SM, LSrc, ISrc, [])
      end,
      update_rout_table(SM1, NList);
    true  when ( LengthLSrc =< 1 ) ->
      proccess_rout_table_helper(SM, lists:nth(2, LDst), LDst);
    true  when ( LengthLDst =< 1 ) ->
      proccess_rout_table_helper(SM, lists:nth(1, LRevSrc), LRevSrc);
    true ->
      SM1 = proccess_rout_table_helper(SM, lists:nth(1, LRevSrc), LRevSrc),
      proccess_rout_table_helper(SM1, lists:nth(2, LDst), LDst);
    false ->
      SM
  end,
  [SMN, BPath].

proccess_rout_table_helper(SM, FromAddr, NListPath) ->
  case readETS(SM, current_neighbours) of
    not_inside -> SM;
    _ ->
      case lists:member(FromAddr, readETS(SM, current_neighbours)) of
        true  ->
          [SM1, NList] = proccess_rout_table(SM, NListPath, FromAddr, []),
          update_rout_table(SM1, NList);
        false ->
          SM
      end
  end.
proccess_rout_table(SM, [],_, Routing_table) ->
  [SM, lists:reverse([255 | Routing_table]) ];
proccess_rout_table(SM, [H | T], NLFrom, Routing_table) ->
  proccess_rout_table(fsm:set_timeout(SM, {s, readETS(SM, path_life)}, {path_life, {H, NLFrom}}), T, NLFrom, [ {H, NLFrom} | Routing_table]).

process_path_life(SM, Tuple) ->
  NRouting_table =
  lists:foldr(
    fun(X,A) ->
       if (is_tuple(X) and (X =:= Tuple)) -> A;
        true-> [X|A]
       end
    end,[], readETS(SM, routing_table)),
  insertETS(SM, routing_table, NRouting_table).

save_path(SM, {Flag,_} = Params, Tuple) ->
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  case Flag of
    path_addit when Protocol#pr_conf.evo ->
      {async,{nl,recv,_,_,Payload}} = Tuple,
      {match, [_, AParams]} = re:run(Payload, ?PATH_ADDIT, [dotall, {capture, [1, 2], binary}]),
      [BRssi, BIntegr] = split_bin_comma(AParams),
      El = { bin_to_num(BRssi), bin_to_num(BIntegr), {Params, Tuple} },
      insertETS(SM, list_current_wvp, readETS(SM, list_current_wvp) ++ [El]);
    _ -> SM
  end.

update_rout_table(SM, NRouting_table) ->
  ORouting_table = readETS(SM, routing_table),
  LRouting_table = if ORouting_table =:= 255 -> [255]; true -> ORouting_table end,
  SMN1 =
  lists:foldr(
     fun(X, SMTmp) ->
       if is_tuple(X) -> fsm:set_timeout(SMTmp, {s, readETS(SMTmp, path_life)}, {path_life, X});
          true-> SMTmp
       end
     end, SM, NRouting_table),
  {SMN2, FL} =
  lists:foldr(
     fun(X, {SMTmp, A}) ->
       case X of
         {From, _} ->
           case lists:keyfind(From, 1, NRouting_table) of
             false -> {SMTmp, [X | A]};
             Key ->
               SMTmp1 = if (X =:= Key) -> SMTmp; true -> fsm:clear_timeout(SMTmp, X) end,
               % new element, have to set new timeout, clear old
               {SMTmp1, [Key | A]} end;
         _ -> {SMTmp, A}
       end
     end, {SMN1, []}, LRouting_table),
  % sort and delete dublicated
  Routing_table = lists:reverse(lists:usort(sets:to_list(sets:from_list(FL ++ NRouting_table)))),
  ?INFO(?ID, "+++ Updated routing table ~w ~n", [Routing_table]),
  insertETS(SMN2, routing_table, Routing_table),
  SMN2.

get_current_neighbours(SM) ->
  case readETS(SM, current_neighbours) of
    not_inside -> no_neighbours;
    _ -> neighbours_to_bin(SM, mac)
  end.

process_pkg_id(SM, ATParams, Tuple = {RemotePkgID, RecvNLSrc, RecvNLDst, _}) ->
  %{ATSrc, ATDst} = ATParams,
  Local_address = readETS(SM, local_address),
  LocalPkgID = readETS(SM, packet_id),
  MoreRecent = sequence_more_recent(RemotePkgID, LocalPkgID, readETS(SM, max_pkg_id)),
  PkgIDOld =
  if MoreRecent -> insertETS(SM, packet_id, RemotePkgID), false;
    true -> true
  end,
  %% not to relay packets with older ids
  case PkgIDOld of
    true when ((RecvNLDst =/= Local_address) and
              (RecvNLSrc =/= Local_address)) -> old_id;
    true when (RecvNLSrc =:= Local_address) -> proccessed;
    _ ->
      Queue_ids = readETS(SM, queue_ids),
      NewQ =
      case queue:len(Queue_ids) of
        Len when Len >= 10 ->
          {_, Queue_out} = queue:out(Queue_ids),
          Queue_out;
        _ ->
          Queue_ids
      end,
      NTuple = {ATParams, Tuple},
      case queue:member(NTuple, NewQ) of
        true  ->
          insertETS(SM, queue_ids, NewQ),
          not_proccessed;
        false ->
          % check if same package was received from other src dst,
          % if yes  -> insertETS(SM, queue_ids, NewQ), proccessed
          % if no -> insertETS(SM, queue_ids, queue:in(NTuple, NewQ)), not_proccessed
          Skey = searchKey(NTuple, NewQ, not_found),
          if Skey == found ->
            insertETS(SM, queue_ids, NewQ),
            proccessed;
          true ->
            insertETS(SM, queue_ids, queue:in(NTuple, NewQ)),
            not_proccessed
          end
      end
  end.

searchKey(_, _, found) ->
  found;
searchKey(_, {[],[]}, not_found) ->
  not_found;
searchKey({ATParams, Tuple}, Q, not_found) ->
  {{value, { _, CTuple}}, Q1} = queue:out(Q),
  if CTuple =:= Tuple ->
    searchKey({ATParams, Tuple}, Q1, found);
  true ->
    searchKey({ATParams, Tuple}, Q1, not_found)
  end.

%%--------------------------------------------------  RTT functions -------------------------------------------
getRTT(SM, RTTTuple) ->
  CurrentRTT  = readETS(SM, RTTTuple),
  if CurrentRTT =:= not_inside -> readETS(SM, rtt);
    true -> CurrentRTT
  end.

smooth_RTT(SM, Flag, RTTTuple={_,_,Dst}) ->
  ?TRACE(?ID, "RTT receiving AT command ~p~n", [RTTTuple]),
  Time_send_msg = readETS(SM, {last_nl_sent_time, RTTTuple}),
  if Time_send_msg =:= not_inside -> nothing;
     true ->
       EndValMicro = timer:now_diff(erlang:now(), Time_send_msg),
       CurrentRTT = getRTT(SM, RTTTuple),
       Smooth_RTT =
       if Flag =:= direct -> lerp( CurrentRTT, convert_t(EndValMicro, {us, s}), 0.05);
        true -> lerp(CurrentRTT, readETS(SM, rtt), 0.05)
       end,
       Max_rtt = readETS(SM, max_rtt),
       cleanETS(SM, {last_nl_sent_time, RTTTuple}),
       Val =
       if Smooth_RTT > Max_rtt -> insertETS(SM, RTTTuple, Max_rtt), Max_rtt;
        true -> insertETS(SM, RTTTuple, Smooth_RTT),
                Smooth_RTT
       end,
       ?TRACE(?ID, "Smooth_RTT for Src ~p and Dst ~p is ~120p~n", [readETS(SM, local_address), Dst, Val])
  end.
%%--------------------------------------------------  Other functions -------------------------------------------
sequence_more_recent(S1, S2, Max) ->
  if ((( S1 >= S2 ) and ( S1 - S2 =< Max / 2 )) or (( S2 >= S1 ) and ( S2 - S1  > Max / 2 ))) -> true;
    true -> false
  end.

bin_to_num(Bin) ->
  N = binary_to_list(Bin),
  case string:to_float(N) of
    {error, no_float} -> list_to_integer(N);
    {F, _Rest} -> F
  end.

increase_pkgid(SM) ->
  Max_pkg_id = readETS(SM, max_pkg_id),
  PkgID =
  case TmpPId = readETS(SM, packet_id) of
    _ when TmpPId >= Max_pkg_id -> -1;
    _ -> TmpPId
  end,
  insertETS(SM, packet_id, PkgID + 1),
  PkgID.

init_dets(SM) ->
  LA  = readETS(SM, local_address),
  Ref = SM#sm.dets_share,
  NL_protocol = readETS(SM, nl_protocol),
  B = dets:lookup(Ref, NL_protocol),
  SM1=
  case B of
    []  -> insertETS(SM, packet_id, 0);
    [{NL_protocol, PkgID}] ->
      dets:insert(Ref, {NL_protocol, PkgID + 1}),
      insertETS(SM, packet_id, PkgID + 1);
    _ -> dets:insert(Ref, {NL_protocol, 0}),
         insertETS(SM, packet_id, 0)
  end,
  B1 = dets:lookup(Ref, NL_protocol),
  ?INFO(?ID, "Init dets LA ~p ~p~n", [LA, B1]),
  SM1#sm{dets_share = Ref}.

fill_dets(SM) ->
  LA  = readETS(SM, local_address),
  Ref = SM#sm.dets_share,
  NL_protocol = readETS(SM, nl_protocol),
  Packet_id = readETS(SM, packet_id),
  dets:insert(Ref, {NL_protocol, Packet_id}),
  B = dets:lookup(Ref, NL_protocol),
  ?INFO(?ID, "Fill_dets LA ~p ~p~n", [LA, B] ),
  SM#sm{dets_share = Ref}.

split_bin_comma(Bin) when is_binary(Bin) ->
  binary:split(Bin, <<",">>,[global]).

neighbours_to_bin(SM, Type) ->
  Current_neighbours = readETS(SM, current_neighbours),
  lists:foldr(fun(X, A) ->
                  Sign =
                  if byte_size(A) =:= 0-> "";
                    true-> ","
                  end,
                  case Type of
                    mac -> list_to_binary([integer_to_binary(addr_nl2mac(SM, X)), Sign, A]);
                    nl  -> list_to_binary([integer_to_binary(X), Sign, A])
                  end
              end, <<>>, Current_neighbours).

routing_to_bin(SM) ->
  Routing_table = readETS(SM, routing_table),
  Local_address = readETS(SM, local_address),
  case Routing_table of
    255 ->
      list_to_binary(["default->",integer_to_binary(255)]);
    _ ->
      lists:foldr(
        fun(X,A) ->
            Sign = if byte_size(A) =:= 0-> ""; true -> "," end,
            case X of
              {From, To} ->
                if (From =/= Local_address) -> list_to_binary([integer_to_binary(From),"->",integer_to_binary(To), Sign, A]);
                   true -> A
                end;
              _ ->
                list_to_binary(["default->",integer_to_binary(X), Sign, A])
            end
        end, <<>>, Routing_table)
  end.

add_item_to_queue(SM, Qname, Item, Max) ->
  Q = readETS(SM, Qname),
  NewQ=
  case queue:len(Q) of
    Len when Len >= Max ->  {_, Queue_out} = queue:out(Q), Queue_out;
    _ ->  Q
  end,
  insertETS(SM, Qname, queue:in(Item, NewQ)).

%%--------------------------------------------------  Only MAC functions -------------------------------------------
process_rcv_payload(SM, not_inside, _Payload) ->
  SM;
process_rcv_payload(SM, {_State, Current_msg}, RcvPayload) ->
  [SM1, HRcvPayload] =
  case parse_paylod(RcvPayload) of
    [relay, Payload] ->
      [SM, Payload];
    [Flag, Payload] when Flag == ack; Flag == dst ->
      [clear_spec_timeout(SM, retransmit), Payload]
  end,

  {at, _PID, _, _, _, CurrentPayload} = Current_msg,
  [_CRole, HCurrentPayload] = parse_paylod(CurrentPayload),
  check_payload(SM1, HRcvPayload, HCurrentPayload, Current_msg).

parse_paylod(Payload) ->
  DstReachedPatt = "([^,]*),([^,]*),([^,]*),([^,]*),(.*)",
  case re:run(Payload, DstReachedPatt, [dotall, {capture,[1, 2, 3, 4, 5], binary}]) of
    {match, [BFlag, BPkgID, BDst, BSrc, _RPayload]} ->
      Flag = binary_to_integer(BFlag),
      PkgID = binary_to_integer(BPkgID),
      Dst = binary_to_integer(BDst),
      Src = binary_to_integer(BSrc),
      [check_dst(Flag), {PkgID, Dst, Src}];
    nomatch ->
      [relay, Payload]
  end.

check_payload(SM, HRcvPayload, {PkgID, Dst, Src}, Current_msg) ->
  HCurrentPayload = {PkgID, Dst, Src},
  HNextIDPayload = {PkgID + 1, Dst, Src},
  RevCurrentPayload = {PkgID, Src, Dst},
  RevHCurrentPayload = {PkgID + 1, Src, Dst},
  if ((HCurrentPayload == HRcvPayload) or (HNextIDPayload == HRcvPayload) or
      (RevCurrentPayload == HRcvPayload) or (RevHCurrentPayload == HRcvPayload) ) ->
      insertETS(SM, current_msg, {delivered, Current_msg}),
      clear_spec_timeout(SM, retransmit);
    true ->
      SM
  end;
check_payload(SM, _, _, _) ->
  SM.

check_dst(Flag) ->
  case num2flag(Flag, nl) of
    dst_reached -> dst;
    ack -> ack;
    _ -> relay
  end.

process_send_payload(SM, Msg) ->
  {at, _PID, _, _, _, Payload} = Msg,
  case parse_paylod(Payload) of
    [Flag, _P] when Flag == ack; Flag == relay ->
      SM1 = clear_spec_timeout(SM, retransmit),
      Tmo_retransmit = readETS(SM1, tmo_retransmit),
      fsm:set_timeout(SM1, {s, Tmo_retransmit}, {retransmit, {not_delivered, Msg}});
    [dst, _P] ->
      SM;
    _ ->
      SM
  end.

process_retransmit(SM, Msg, Ev) ->
  Retransmit_count = readETS(SM, retransmit_count),
  Max_retransmit_count = readETS(SM, max_retransmit_count),

  ?TRACE(?ID, "Retransmit Tuple ~p Retransmit_count ~p ~n ", [Msg, Retransmit_count]),
  if (Retransmit_count < Max_retransmit_count) ->
    insertETS(SM, retransmit_count, Retransmit_count + 1),
    SM1 = process_send_payload(SM, Msg),
    [SM1#sm{event = Ev}, {Ev, Msg}];
  true ->
    [SM, {}]
  end.
%%--------------------------------------------------  command functions -------------------------------------------
process_command(SM, Command) ->
  Protocol   = readETS(SM, {protocol_config, readETS(SM, np)}),
  [Req, Asw] =
  case Command of
    {fsm, state} ->
      [fsm_state, state];
    {fsm, states} ->
      Last_states = readETS(SM, last_states),
      [queue:to_list(Last_states), states];
    protocols ->
      [?PROTOCOL_DESCR, protocols];
    {statistics,_,paths} when Protocol#pr_conf.pf ->
      [readETS(SM, paths), paths];
    {statistics,_,neighbours} ->
      [readETS(SM, st_neighbours), neighbours];
    {statistics,_,data} when Protocol#pr_conf.ack ->
      [readETS(SM, st_data), data];
    {protocol, _,info} ->
      [readETS(SM, np), protocol_info];
    {protocol, _,state} ->
      [readETS(SM, pr_state), protocol_state];  % check if needed
    {protocol, _,states} ->
      Pr_states = readETS(SM, pr_states),
      [queue:to_list(Pr_states), protocols_state]; % check if needed
    {protocol, _,neighbours} ->
      [readETS(SM, current_neighbours), neighbours];
    {protocol, _,routing} ->
      [readETS(SM, routing_table), routing];
    _ -> [error, nothing]
  end,
  case Req of
    error ->
      fsm:cast(SM, nl, {send, {sync, {nl, error}} });
    Req when Req =:= not_inside; Req =:= []; Req =:= {[],[]} ->
      fsm:cast(SM, nl, {send, {sync, {nl, Asw, empty}} });
    _ ->
      case Command of
        {fsm,_} ->
          if Asw =:= state ->
               L = list_to_binary([atom_to_binary(SM#sm.state,utf8), "(", atom_to_binary(SM#sm.event,utf8), ")"]),
               fsm:cast(SM, nl, {send, {sync, {nl, fsm, Asw, L}} });
             true -> fsm:cast(SM, nl, {send, {sync, {nl, fsm, Asw, list_to_binary(Req)}} })
          end;
        {statistics,_,paths} when Protocol#pr_conf.pf ->
          fsm:cast(SM, nl, {send, {sync, {nl, statistics, paths, get_stat(SM, paths) }} });
        {statistics, _,neighbours} ->
          fsm:cast(SM, nl, {send, {sync, {nl, statistics, neighbours, get_stat(SM, st_neighbours) }} });
        {statistics, _,data} when Protocol#pr_conf.ack ->
          fsm:cast(SM, nl, {send, {sync, {nl, statistics, data, get_stat_data(SM, st_data) }} });
        protocols ->
          fsm:cast(SM, nl, {send, {sync, {nl, Command, Req}} });
        {protocol, Name, info} ->
          fsm:cast(SM, nl, {send, {sync, {nl, protocol, Asw, get_protocol_info(SM, Name)}} });
        {protocol, _, neighbours} ->
          fsm:cast(SM, nl, {send, {sync, {nl, protocol, Asw, neighbours_to_bin(SM, nl)} }});
        {protocol, _, routing} ->
          fsm:cast(SM, nl, {send, {sync, {nl, protocol, Asw, routing_to_bin(SM)} }});
        {protocol, Name, state} ->
          L = list_to_binary([atom_to_binary(Name,utf8), ",", Req]),
          fsm:cast(SM, nl, {send, {sync, {nl, protocol, state, L}} });
        {protocol, Name, states} ->
          L = list_to_binary([atom_to_binary(Name,utf8), "\n", Req]),
          fsm:cast(SM, nl, {send, {sync, {nl, protocol, states, L}} });
        _ ->
          fsm:cast(SM, nl, {send, {sync, {nl, error}} })
      end
  end,
  SM.

save_stat(SM, Role)->
  if Role =:= source ->
       insertETS(SM, s_send_time, erlang:now()), insertETS(SM, s_total_sent, readETS(SM, s_total_sent) + 1);
     true ->
       insertETS(SM, r_send_time, erlang:now()), insertETS(SM, r_total_sent, readETS(SM, r_total_sent) + 1)
  end.

update_states_list(SM) ->
  [{_, Msg}] =
  lists:filter(fun({St, _Descr}) -> St =:= SM#sm.state end, ?STATE_DESCR),
  insertETS(SM, pr_state, Msg),
  add_item_to_queue(SM, pr_states, Msg, 50),
  add_item_to_queue(SM, last_states, list_to_binary([atom_to_binary(SM#sm.state,utf8), "(", atom_to_binary(SM#sm.event,utf8), ")\n"]), 50).

get_protocol_info(SM, Name) ->
  BName = atom_to_binary(Name, utf8),
  Conf  = readETS(SM, {protocol_config, Name}),
  list_to_binary(["\nName\t\t: ", BName,"\n", ?PROTOCOL_SPEC(Conf)]).

get_stat_data(SM, Qname) ->
  PT = readETS(SM, Qname),
  lists:foldr(
    fun(X,A) ->
      {Role, Payload, Time, Length, State, TS, Dst, Count_hops} = X,
      TRole = if Role =:= source -> "Source"; true -> "Relay" end,
      BTime = list_to_binary(lists:flatten(io_lib:format("~.1f",[Time]))),
      [list_to_binary(
        ["\n ", TRole, " Data:",Payload, " Len:", covert_type_to_bin(Length),
         " Duration:", BTime, " State:", State, " Total:", integer_to_binary(TS),
         " Dst:", integer_to_binary(Dst), " Hops:", integer_to_binary(Count_hops)]) | A]
    end,[],queue:to_list(PT)).

get_stat(SM, Qname) ->
  PT = readETS(SM, Qname),
  lists:foldr(
    fun(X,A) ->
      {Role, Val, Time, Count, TS}=X,
      TRole = if Role =:= source -> "Source"; true -> "Relay" end,
      BTime = list_to_binary(lists:flatten(io_lib:format("~.1f", [Time]))),
      TVal =
      case Qname of
        paths -> "Path:";
        st_neighbours -> "Neighbour:"
      end,
      [list_to_binary(
        ["\n ", TRole, " ", TVal, covert_type_to_bin(Val),
         " Time:", BTime, " Count:", integer_to_binary(Count),
         " Total:", integer_to_binary(TS)]) | A]
    end, [], queue:to_list(PT)).

analyse(SM, QName, BPath, {Real_src, Real_dst}) ->
  Local_address = readETS(SM, local_address),
  {T, Role, TSC}=
  if Local_address =:= Real_src; Local_address =:= Real_dst ->
       {readETS(SM, s_send_time), source, readETS(SM, s_total_sent)};
     true ->
       {readETS(SM, r_send_time), relay, readETS(SM, r_total_sent)}
  end,
  NBPath =
  case QName of
    paths ->
      if BPath =:= nothing -> <<>>;
         true ->
           SPath = lists:foldr(
                     fun(X, A) ->
                         [binary_to_integer(X)| A]
                     end, [], split_bin_comma(BPath)),
           lists:foldr(
             fun(X, A) ->
                 Sign =
                 if byte_size(A) =:= 0 -> "";
                  true -> ","
                 end,
                 list_to_binary([ integer_to_binary(addr_mac2nl(SM, X)), Sign, A])
             end, <<>>, lists:reverse(SPath))
      end;
    st_neighbours -> BPath;
    st_data -> BPath
  end,
  case T of
    not_inside  when QName =/= st_data ->
      add_item_to_queue_nd(SM, QName, {Role, NBPath, 0.0, 1, TSC}, 100);
    _ when QName =/= st_data ->
      add_item_to_queue_nd(SM, QName, {Role, NBPath, convert_t(timer:now_diff(erlang:now(), T), {us, s}), 1, TSC}, 100);
    not_inside  when QName =:= st_data ->
      {P, Dst, Count_hops, St} = NBPath,
      add_item_to_queue_nd(SM, QName, {Role, P, 0.0, byte_size(P), St, TSC, Dst, Count_hops}, 100);
    _ when QName =:= st_data ->
      {P, Dst, Count_hops, St} = NBPath,
      add_item_to_queue_nd(SM, QName, {Role, P, convert_t(timer:now_diff(erlang:now(), T), {us, s}), byte_size(P), St, TSC, Dst, Count_hops}, 100)
  end.

add_item_to_queue_nd(SM, Qname, Item, Max) ->
  Q = readETS(SM, Qname),
  NewQ=
  case queue:len(Q) of
    Len when Len >= Max ->
      {_, Queue_out} = queue:out(Q), Queue_out;
    _ -> Q
  end,
  case Qname of
    st_data ->
      insertETS(SM, Qname, queue:in(Item, NewQ));
    _ ->
      {R, NP, NT, _, NewTS} = Item,
      L =
      lists:foldr(
        fun({Role, P, T, Count, TS},A)->
          if R =:= Role ->
               case P of
                 NP when T > 0 -> [{Role, P, (T + NT) / 2, Count + 1, TS} | A];
                 NP when T =:= 0.0 -> [{Role, P, T, Count + 1, TS} | A];
                 _  when T >= 0 -> [{Role, P, T, Count, TS} | A]
               end;
             true -> [{Role, P, T, Count, TS} | A]
          end
        end,[],queue:to_list(NewQ)),
      QQ =
      case L =:= queue:to_list(NewQ) of
        true  -> queue:in(Item, NewQ);
        false -> queue:from_list(L)
      end,
      NUQ = lists:foldr(
              fun({Role, P, T, Count, TS},A) ->
                  if R =:= Role -> [{Role, P, T, Count, NewTS} | A];
                     true -> [{Role, P, T, Count, TS} | A]
                  end
              end,[],queue:to_list(QQ)),
      insertETS(SM, Qname, queue:from_list(NUQ))
  end.
