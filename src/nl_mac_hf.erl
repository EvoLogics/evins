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
-export([convert_to_binary/1, covert_type_to_bin/1, convert_t/2, convert_la/3, count_flag_bits/1]).
%% ETS functions
-export([insertETS/3, readETS/2, cleanETS/2, init_dets/1, fill_dets/1]).
%% handle events
-export([event_params/3, clear_spec_timeout/2]).
%% Math functions
-export([rand_float/2, lerp/3]).
%% Addressing functions
-export([init_nl_addrs/1, add_to_table/3, get_dst_addr/1, set_dst_addr/2]).
-export([addr_nl2mac/2, addr_mac2nl/2, get_routing_addr/3, num2flag/2, flag2num/1]).
%% NL header functions
-export([fill_bin_addrs/1, parse_path_data/2]).
%% Extract functions
-export([extract_payload_mac_flag/1, extract_payload_nl_flag/1, create_ack/1, extract_ack/2]).
%% Extract/create header functions
-export([extract_neighbours_path/2]).
%% Send NL functions
-export([send_nl_command/4, send_ack/3, send_path/2, send_helpers/4, send_cts/6, send_mac/4, fill_msg/2]).
%% Parse NL functions
-export([prepare_send_path/3, parse_path/3, save_path/3]).
%% Process NL functions
-export([add_neighbours/4, process_pkg_id/3, proccess_relay/2, process_path_life/2, neighbours_to_list/2, routing_to_bin/1, check_dubl_in_path/2]).
%% RTT functions
-export([getRTT/2, smooth_RTT/3]).
%% command functions
-export([process_command/3, save_stat/3, update_states_list/1]).
%% Only MAC functions
-export([process_rcv_payload/3, process_send_payload/2, process_retransmit/3]).
%% Other functions
-export([bin_to_num/1, increase_pkgid/1, add_item_to_queue/4, analyse/4, logs_additional/2]).
%%--------------------------------------------------- Convert types functions -----------------------------------------------
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

send_ack(SM,  {send_ack, {_, [Packet_id, _, _PAdditional]}, {async, {nl, recv, Real_dst, Real_src, _}}}, Count_hops) ->
  BCount_hops = create_ack(Count_hops),
  send_nl_command(SM, alh, {ack, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BCount_hops}).

send_path(SM, {send_path, {Flag, [Packet_id, _, _PAdditional]}, {async, {nl, recv, Real_dst, Real_src, Payload}}}) ->
  MAC_addr  = convert_la(SM, integer, mac),
  case readETS(SM, current_neighbours) of
    not_inside -> error;
    _ ->
      BCN = neighbours_to_list(SM, mac),
      [SMN, BMsg] =
      case Flag of
        neighbours ->
          [SM, fill_msg(neighbours_path, {BCN, [MAC_addr]})];
        Flag ->
          [SMNTmp, ExtrListPath] =
          case Flag of
            path_addit ->
              [ListPath, [DIRssi, DIIntegr]] = extract_path_addit(SM, Payload),
              NPathTuple = {[DIRssi, DIIntegr], ListPath},
              parse_path(SM,  NPathTuple, {Real_src, Real_dst});
            path     ->
              [ListNeighbours, ListPath] = extract_neighbours_path(SM, Payload),
              NPathTuple = {ListNeighbours, ListPath},
              parse_path(SM, NPathTuple, {Real_src, Real_dst})
          end,

          CheckDblPath = check_dubl_in_path(ExtrListPath, MAC_addr),
          RCheckDblPath = lists:reverse(CheckDblPath),

          analyse(SM, paths, ExtrListPath, {Real_src, Real_dst}),
          proccess_and_update_path(SM, {Real_src, Real_dst, RCheckDblPath} ),
          [SMNTmp, fill_msg(neighbours_path, {BCN, RCheckDblPath})]
      end,
      send_nl_command(SMN, alh, {path, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BMsg})
  end.

send_nl_command(SM, Interface, {Flag, [IPacket_id, Real_src, _PAdditional]}, NL) ->
  Real_dst = get_dst_addr(NL),
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  if Real_dst =:= wrong_format -> error;
     true ->
       Rout_addr = get_routing_addr(SM, Flag, Real_dst),
       [MAC_addr, MAC_real_src, MAC_real_dst] = addr_nl2mac(SM, [Rout_addr, Real_src, Real_dst]),
       if(Rout_addr =:= no_routing_table) ->
        ?ERROR(?ID, "~s: Wrong Rout_addr:~p, check config file ~n", [?MODULE, Rout_addr]);
        true -> nothing
       end,
       ?TRACE(?ID, "Rout_addr ~p, MAC_addrm ~p, MAC_real_src ~p, MAC_real_dst ~p~n", [Rout_addr, MAC_addr, MAC_real_src, MAC_real_dst]),
       if ((MAC_addr =:= error) or (MAC_real_src =:= error) or (MAC_real_dst =:= error)
           or ((MAC_real_dst =:= 255) and Protocol#pr_conf.br_na)) ->
            error;
          true ->
            NLarp = set_dst_addr(NL, MAC_addr),
            AT = nl2at(SM, {Flag, IPacket_id, MAC_real_src, MAC_real_dst, NLarp}),
            if NLarp =:= wrong_format -> error;
               true ->
                 ?TRACE(?ID, "Send AT command ~p~n", [AT]),
                 Local_address = readETS(SM, local_address),
                 CurrentRTT = {rtt, Local_address, Real_dst},
                 ?TRACE(?ID, "CurrentRTT sending AT command ~p~n", [CurrentRTT]),
                 insertETS(SM, {last_nl_sent_time, CurrentRTT}, os:timestamp()),
                 insertETS(SM, last_nl_sent, {Flag, Real_src, NLarp}),
                 insertETS(SM, ack_last_nl_sent, {IPacket_id, Real_src, Real_dst}),
                 SM1 = fsm:cast(SM, Interface, {send, AT}),
                 %!!!!
                 %fsm:cast(SM, nl, {send, AT}),
                 fill_dets(SM),
                 fsm:set_event(SM1, eps)
            end
       end
  end.

mac2at(Flag, Tuple) when is_tuple(Tuple)->
  case Tuple of
    {at, PID, SENDFLAG, IDst, TFlag, Data} ->
      NewData = create_payload_mac_flag(Flag, Data),
      {at, PID, SENDFLAG, IDst, TFlag, NewData};
    _ ->
      error
  end.

nl2at (SM, Tuple) when is_tuple(Tuple)->
  ETSPID =  list_to_binary(["p", integer_to_binary(readETS(SM, pid))]),
  case Tuple of
    {Flag, BPacket_id, MAC_real_src, MAC_real_dst, {nl, send, IDst, Data}}  ->
      NewData = create_payload_nl_flag(Flag, BPacket_id, MAC_real_src, MAC_real_dst, Data),
      {at,"*SENDIM", ETSPID, byte_size(NewData), IDst, noack, NewData};
    _ ->
      error
  end.

%%------------------------- Extract functions ----------------------------------
create_payload_nl_flag(Flag, PkgID, Src, Dst, Data) ->
  % 3 first bits Flag (if max Flag vbalue is 5)
  % 8 bits PkgID
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 1)
  CBitsFlag = count_flag_bits(?FLAG_MAX),
  CBitsPkgID = count_flag_bits(?BITS_PKG_ID_MAX),
  CBitsAddr = count_flag_bits(?BITS_ADDRESS_MAX),

  FlagNum = ?FLAG2NUM(Flag),
  BFlag = <<FlagNum:CBitsFlag>>,

  BPkgID = <<PkgID:CBitsPkgID>>,
  BSrc = <<Src:CBitsAddr>>,
  BDst = <<Dst:CBitsAddr>>,

  TmpData = <<BFlag/bitstring, BPkgID/bitstring, BSrc/bitstring, BDst/bitstring, Data/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),

  if Data_bin =:= false ->
    Add = 8 - bit_size(TmpData) rem 8,
    <<BFlag/bitstring, BPkgID/bitstring, BSrc/bitstring, BDst/bitstring, 0:Add, Data/binary>>;
  true ->
    TmpData
  end.

create_payload_mac_flag(Flag, Data) ->
  % 3 first bits Flag (if max Flag vbalue is 5)
  % rest bits reserved for later (+5)
  C = count_flag_bits(?FLAG_MAX),
  FlagNum = ?FLAG2NUM(Flag),
  BFlag = <<FlagNum:C>>,
  TmpData = <<BFlag/bitstring, Data/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = 8 - bit_size(TmpData) rem 8,
    <<BFlag/bitstring, 0:Add, Data/binary>>;
  true ->
    TmpData
  end.

extract_payload_nl_flag(Payl) ->
  CBitsFlag = count_flag_bits(?FLAG_MAX),
  CBitsPkgID = count_flag_bits(?BITS_PKG_ID_MAX),
  CBitsAddr = count_flag_bits(?BITS_ADDRESS_MAX),
  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  <<BFlag:CBitsFlag, BPkgID:CBitsPkgID, BSrc:CBitsAddr, BDst:CBitsAddr, Rest/bitstring>> = Payl,
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [BFlag, BPkgID, BSrc, BDst, Data];
  true ->
    [BFlag, BPkgID, BSrc, BDst, Rest]
  end.

extract_payload_mac_flag(Payl) ->
  C = count_flag_bits(?FLAG_MAX),
  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  if Data_bin =:= false ->
    <<BFlag:C, Rest/bitstring>> = Payl,
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [BFlag, Data, round((Add + C) / 8)];
  true ->
    <<BFlag:C, Data/binary>> = Payl,
    [BFlag, Data, round(C / 8)]
  end.

check_dubl_in_path(Path, MAC_addr) ->
  case lists:member(MAC_addr, Path) of
    true  -> Path;
    false -> [MAC_addr | Path]
  end.

remove_dubl_in_path([])    -> [];
remove_dubl_in_path([H|T]) -> [H | [X || X <- remove_dubl_in_path(T), X /= H]].

%%----------------NL functions create/extract protocol header-------------------
%%--------------- path_data -------------------
%   3b        6b        LenPath * 6b   REST till / 8
%   TYPEMSG   LenPath   Path           ADD
create_path_data(Type, Path, Data) ->
  LenPath = length(Path),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  TypeNum = ?TYPEMSG2NUM(Type),

  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = fill_bin_addrs(Path),

  TmpData = <<BType/bitstring, BLenPath/bitstring, BPath/bitstring, Data/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = 8 - bit_size(TmpData) rem 8,
     <<BType/bitstring, BLenPath/bitstring, BPath/bitstring, 0:Add, Data/binary>>;
   true ->
     TmpData
   end.

extract_path_data(SM, Payl) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),

  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  <<BType:CBitsTypeMsg, BLenPath:CBitsLenPath, PTail/bitstring>> = Payl,

  [Path, Rest] = bin_addrs_to_list(PTail, BLenPath),
  path_data = ?NUM2TYPEMSG(BType),
  true = BLenPath > 0,
  ?TRACE(?ID, "extract path data BType ~p BLenPath ~p~n", [BType, BLenPath]),
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [Path, Data];
  true ->
    [Path, Rest]
  end.

bin_addrs_to_list(BPath, Len) ->
  bin_addrs_to_list_helper(BPath, Len, [], <<>>).

bin_addrs_to_list_helper(_, 0, Path, Data) ->
  [Path, Data];
bin_addrs_to_list_helper(BPath, Len, Path, _Data) ->
  CBitsAddr = count_flag_bits(?BITS_ADDRESS_MAX),
  <<BHop:CBitsAddr, Rest/bitstring>> = BPath,
  bin_addrs_to_list_helper(Rest, Len - 1, [BHop | Path], Rest).

fill_bin_addrs(Addrs) ->
  LenPath = length(Addrs),
  fill_bin_addrs_helper(Addrs, LenPath, <<>>).

fill_bin_addrs_helper(_, 0, BAddrs) -> BAddrs;
fill_bin_addrs_helper([HPath | TPath], LenPath, BAddrs) ->
  CBitsAddr = count_flag_bits(?BITS_ADDRESS_MAX),
  fill_bin_addrs_helper(TPath, LenPath - 1, <<HPath:CBitsAddr, BAddrs/bitstring>>).

parse_path_data(SM, Payl) ->
  try
    MAC_addr = convert_la(SM, integer, mac),
    [Path, BData] = extract_path_data(SM, Payl),
    CheckedDblPath = check_dubl_in_path(Path, MAC_addr),
    ?TRACE(?ID, "recv parse path data ~p Data ~p~n", [CheckedDblPath, BData]),
    {BData, CheckedDblPath}
  catch error: _Reason ->
    {Payl, nothing}
  end.
%%--------------- ack -------------------
%   6b            REST till / 8
%   Counthops     ADD
create_ack(CountHops) ->
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  BCountHops = <<CountHops:CBitsLenPath>>,
  Data_bin = is_binary(BCountHops) =:= false or ( (bit_size(BCountHops) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = 8 - bit_size(BCountHops) rem 8,
     <<BCountHops/bitstring, 0:Add>>;
   true ->
     BCountHops
   end.

extract_ack(SM, Payl) ->
   CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
   <<CountHops:CBitsLenPath, _Rest/bitstring>> = Payl,
   ?TRACE(?ID, "extract_ack CountHops ~p ~n", [CountHops]),
   CountHops.

%%--------------- neighbours -------------------
%   3b        6b                LenNeighbours * 6b    REST till / 8
%   TYPEMSG   LenNeighbours     Neighbours            ADD
create_neighbours(Type, Neighbours) ->
  LenNeighbours = length(Neighbours),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?BITS_LEN_NEIGBOURS),
  TypeNum = ?TYPEMSG2NUM(Type),

  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenNeigbours = <<LenNeighbours:CBitsLenNeigbours>>,
  BNeighbours = fill_bin_addrs(Neighbours),

  TmpData = <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = 8 - bit_size(TmpData) rem 8,
     <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring, 0:Add>>;
   true ->
     TmpData
  end.

create_neighbours_path(Type, Neighbours, Path) ->
  LenNeighbours = length(Neighbours),
  LenPath = length(Path),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?BITS_LEN_NEIGBOURS),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  TypeNum = ?TYPEMSG2NUM(Type),

  BType = <<TypeNum:CBitsTypeMsg>>,

  BLenNeigbours = <<LenNeighbours:CBitsLenNeigbours>>,
  BNeighbours = fill_bin_addrs(Neighbours),

  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = fill_bin_addrs(Path),

  TmpData = <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring,
              BLenPath/bitstring, BPath/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = 8 - bit_size(TmpData) rem 8,
     <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring,
       BLenPath/bitstring, BPath/bitstring, 0:Add>>;
   true ->
     TmpData
  end.

extract_neighbours_path(SM, Payl) ->
  try
    CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
    CBitsLenNeigbours = count_flag_bits(?BITS_LEN_NEIGBOURS),
    CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),

    <<BType:CBitsTypeMsg, BLenNeighbours:CBitsLenNeigbours, PTailNeighbours/bitstring>> = Payl,

    neighbours_path = ?NUM2TYPEMSG(BType),

    [Neighbours, PTailPath] = bin_addrs_to_list(PTailNeighbours, BLenNeighbours),
    <<BLenPath:CBitsLenPath, Rest/bitstring>> = PTailPath,

    [Path, _] = bin_addrs_to_list(Rest, BLenPath),

    ?TRACE(?ID, "Extract neighbours path BType ~p BLenPath ~p Neighbours ~p Path ~p~n",
          [BType, BLenPath, Neighbours, Path]),

    [Neighbours, Path]
   catch error: _Reason ->
     [[], nothing]
   end.

%%--------------- path_addit -------------------
%-------> path_addit
%   3b        6b        LenPath * 6b    2b        LenAdd * 8b       REST till / 8
%   TYPEMSG   LenPath   Path            LenAdd    Addtional Info     ADD
create_path_addit(Type, Path, Additional) ->
  LenPath = length(Path),
  LenAdd = length(Additional),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?BITS_LEN_ADD),
  TypeNum = ?TYPEMSG2NUM(Type),

  BType = <<TypeNum:CBitsTypeMsg>>,

  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = fill_bin_addrs(Path),

  BLenAdd = <<LenAdd:CBitsLenAdd>>,
  BAdd = fill_bin_addrs(Additional),

  TmpData = <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
            BLenAdd/bitstring, BAdd/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = 8 - bit_size(TmpData) rem 8,
     <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
            BLenAdd/bitstring, BAdd/bitstring, 0:Add>>;
   true ->
     TmpData
  end.

extract_path_addit(SM, Payl) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?BITS_LEN_ADD),

  <<BType:CBitsTypeMsg, BLenPath:CBitsLenPath, PTailPath/bitstring>> = Payl,
  [Path, PTailAdd] = bin_addrs_to_list(PTailPath, BLenPath),
  <<BLenAdd:CBitsLenAdd, Rest/bitstring>> = PTailAdd,

  [Additonal, _] = bin_addrs_to_list(Rest, BLenAdd),
  path_addit = ?NUM2TYPEMSG(BType),

  ?TRACE(?ID, "extract path addit BType ~p BLenPath ~p Path ~p Additonal ~p~n",
        [BType, BLenPath, Path, Additonal]),

  [Path, Additonal].

%%-------------------------Addressing functions --------------------------------
flag2num(Flag) when is_atom(Flag)->
  integer_to_binary(?FLAG2NUM(Flag)).

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

%%----------------------------Parse NL functions -------------------------------
fill_msg(Format, Tuple) ->
  case Format of
    neighbours ->
      create_neighbours(Format, Tuple);
    neighbours_path ->
      {Neighbours, Path} = Tuple,
      create_neighbours_path(Format, Neighbours, Path);
    path_data ->
      {Data, Path} = Tuple,
      create_path_data(Format, Path, Data);
    path_addit ->
      {Path, Additional} = Tuple,
      create_path_addit(Format, Path, Additional)
  end.

prepare_send_path(SM, [_ , _, PAdditional], {async,{nl, recv, Real_dst, Real_src, Payload}}) ->
  MAC_addr = convert_la(SM, integer, mac),
  {nl,send, IDst, Data} = readETS(SM, current_pkg),

  [ListNeighbours, ListPath] = extract_neighbours_path(SM, Payload),
  NPathTuple = {ListNeighbours, ListPath},
  [SM1, BPath] = parse_path(SM, NPathTuple, {Real_src, Real_dst}),
  NPath = [MAC_addr | BPath],

  case get_routing_addr(SM, path, Real_dst) of
    255 -> nothing;
    _ -> analyse(SM1, paths, NPath, {Real_src, Real_dst})
  end,

  SDParams = {data, [increase_pkgid(SM), readETS(SM, local_address), PAdditional]},
  SDTuple = {nl, send, IDst, fill_msg(path_data, {Data, NPath})},

  case check_path(SM1, Real_src, Real_dst, NPath) of
    true  -> [SM1, SDParams, SDTuple];
    false -> [SM1, path_not_completed]
  end.

%% check path if it is completed, Src and Dst exist
check_path(SM, Real_src, Real_dst, ListPath) ->
  IDst = addr_nl2mac(SM, Real_dst),
  ISrc = addr_nl2mac(SM, Real_src),
  (lists:member(IDst, ListPath) and lists:member(ISrc, ListPath)).

parse_path(SM, {_, ListPath}, {ISrc, IDst}) ->
  if ListPath =:= nothing ->
    [SM, nothing];
   true ->
     MacLAddr = convert_la(SM, integer, mac),
     case lists:member(MacLAddr, ListPath) of
       true  ->
        SMN = proccess_and_update_path(SM, {ISrc, IDst, ListPath}),
        [SMN, ListPath];
       false ->
        [SM, ListPath]
     end
  end.

add_neighbours(SM, Flag, NLSrcAT, {RealSrc, Real_dst}) ->
  ?INFO(?ID, "+++ Flag ~p, NLSrcAT ~p, RealSrc ~p~n", [Flag, NLSrcAT, RealSrc]),
  Current_neighbours = readETS(SM, current_neighbours),
  SM1 = fsm:set_timeout(SM, {s, readETS(SM, neighbour_life)}, {neighbour_life, NLSrcAT}),
  analyse(SM1, st_neighbours, NLSrcAT, {RealSrc, Real_dst}),
  case Current_neighbours of
    not_inside ->
      insertETS(SM1, current_neighbours, [NLSrcAT]);
    _ ->
      case lists:member(NLSrcAT, Current_neighbours) of
        true -> SM1;
        false -> insertETS(SM1, current_neighbours, [NLSrcAT | Current_neighbours])
      end
  end.

%%-------------------------------------------------- Proccess NL functions -------------------------------------------
get_aver_value(0, Val2) ->
  round(Val2);
get_aver_value(Val1, Val2) ->
  round((Val1 + Val2) / 2).

proccess_relay(SM, Tuple = {send, Params, {nl, send, IDst, Payload}}) ->
  {Flag, [_, ISrc, PAdditional]} = Params,
  MAC_addr = convert_la(SM, integer, mac),
  Protocol = readETS(SM, {protocol_config, readETS(SM, np)}),
  case Flag of
    data when (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) ->
      CheckedTuple = parse_path_data(SM, Payload),
      NewPayload = fill_msg(path_data, CheckedTuple),
      [SMN1, _]  = parse_path(SM, CheckedTuple, {ISrc, IDst}),
      [SMN1, {send, Params, {nl, send, IDst, NewPayload}}];
    data when Protocol#pr_conf.pf ->
      CheckedTuple = parse_path_data(SM, Payload),
      [SMN, _] = parse_path(SM, CheckedTuple, {ISrc, IDst}),
      [SMN, Tuple];
    data ->
      [SM, Tuple];
    neighbours ->
      case LNeighbours = get_current_neighbours(SM) of
        no_neighbours ->
          [SM, not_relay];
        _ ->
          Payl = fill_msg(neighbours, LNeighbours),
          [SM, {send, Params, {nl, send, IDst, Payl}}]
      end;
    path_addit when Protocol#pr_conf.evo ->
      [Path, [DIRssi, DIIntegr]] = extract_path_addit(SM, Payload),
      [IRcvRssi, IRcvIntegr] = PAdditional,

      ?INFO(?ID, "+++ IRcvRssi ~p, IRcvIntegr ~p ~n", [IRcvRssi, IRcvIntegr]),
      RcvRssi = (-1) * IRcvRssi,
      %% if ((IRcvIntegr < 100) or (RcvRssi < 30)) -> [SM, not_relay]; % add to weak signals
      if (IRcvIntegr < 90) ->
           [SM, not_relay]; % add to weak signals
         true ->
           AvRssi = get_aver_value(DIRssi, RcvRssi),
           AvIntegr = get_aver_value(DIIntegr, IRcvIntegr),
           RssiIntegrParams = [AvRssi, AvIntegr],
           CheckDublPath = check_dubl_in_path(Path, MAC_addr),
           NewPayload = fill_msg(path_addit, {CheckDublPath, RssiIntegrParams}),
           [SM, {send, Params, {nl, send, IDst, NewPayload}}]
      end;
    path_addit ->
      [Path, _] = extract_path_addit(SM, Payload),
      CheckDublPath = check_dubl_in_path(Path, MAC_addr),
      NewPayload = fill_msg(path_addit, {CheckDublPath, []}),
      [SM, {send, Params, {nl, send, IDst, NewPayload}}];
    path ->
      case LNeighbours = get_current_neighbours(SM) of
        no_neighbours -> [SM, not_relay];
        _ ->
          Local_address = readETS(SM, local_address),
          [ListNeighbours, ListPath] = extract_neighbours_path(SM, Payload),
          NPathTuple = {ListNeighbours, ListPath},
          %% save path and set path life
          [SMN, _] = parse_path(SM, NPathTuple, {ISrc, IDst}),
          %% check path, because of loopings (no dublicated addrs)
          Check_path = check_path(SM, ISrc, IDst, ListPath),
          case (lists:member(MAC_addr, ListNeighbours)) of
            true when ((ISrc =/= Local_address) and (Protocol#pr_conf.lo or Protocol#pr_conf.dbl) and Check_path) ->
              NewPayload = fill_msg(neighbours_path, {LNeighbours, ListPath}),
              [SMN, {send, Params, {nl, send, IDst, NewPayload}}];
            _ ->
              case (lists:member(MAC_addr, ListNeighbours) and not(lists:member(MAC_addr, ListPath))) of
                true  when (ISrc =/= Local_address) ->
                  DublListPath = check_dubl_in_path(ListPath, MAC_addr),
                  NewPayload = fill_msg(neighbours_path, {LNeighbours, DublListPath}),
                  [SMN, {send, Params, {nl, send, IDst, NewPayload}}];
                _ -> [SMN, not_relay]
              end
          end
      end;
    _ -> [SM, Tuple]
  end.

proccess_and_update_path(SM, {ISrc, IDst, ListPath}) ->
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
  SMN.

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
  SM1 = fsm:set_timeout(SM, {s, readETS(SM, path_life)}, {path_life, {H, NLFrom}}),
  proccess_rout_table(SM1, T, NLFrom, [ {H, NLFrom} | Routing_table]).

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
    data when Protocol#pr_conf.ry_only and Protocol#pr_conf.pf ->
      {async,{nl,recv, Real_src, Real_dst, Payload}} = Tuple,
      {_, Path} = parse_path_data(SM, Payload),
      analyse(SM, paths, Path, {Real_src, Real_dst});
    path_addit when Protocol#pr_conf.evo ->
      {async,{nl,recv, _, _, Payload}} = Tuple,
      [_, [DIRssi, DIIntegr]] = extract_path_addit(SM, Payload),
      El = { DIRssi, DIIntegr, {Params, Tuple} },
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
    _ -> neighbours_to_list(SM, mac)
  end.

process_pkg_id(SM, ATParams, Tuple = {RemotePkgID, RecvNLSrc, RecvNLDst, _}) ->
  %{ATSrc, ATDst} = ATParams,
  Local_address = readETS(SM, local_address),
  LocalPkgID = readETS(SM, packet_id),
  Max_pkg_id = readETS(SM, max_pkg_id),
  MoreRecent = sequence_more_recent(RemotePkgID, LocalPkgID, Max_pkg_id),
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
  Max_rtt = readETS(SM, max_rtt),
  Min_rtt = readETS(SM, min_rtt),
  if Time_send_msg =:= not_inside -> nothing;
     true ->
       EndValMicro = timer:now_diff(os:timestamp(), Time_send_msg),
       CurrentRTT = getRTT(SM, RTTTuple),
       Smooth_RTT =
       if Flag =:= direct ->
        lerp( CurrentRTT, convert_t(EndValMicro, {us, s}), 0.05);
       true ->
        lerp(CurrentRTT, readETS(SM, rtt), 0.05)
       end,
       cleanETS(SM, {last_nl_sent_time, RTTTuple}),
       Val =
       case Smooth_RTT of
        _ when Smooth_RTT < Min_rtt ->
          insertETS(SM, RTTTuple, Min_rtt),
          Min_rtt;
        _ when Smooth_RTT > Max_rtt ->
          insertETS(SM, RTTTuple, Max_rtt),
          Max_rtt;
        _ ->
          insertETS(SM, RTTTuple, Smooth_RTT),
          Smooth_RTT
       end,

       LA = readETS(SM, local_address),
       ?TRACE(?ID, "Smooth_RTT for Src ~p and Dst ~p is ~120p~n", [LA, Dst, Val])
  end.
%%--------------------------------------------------  Other functions -------------------------------------------
sequence_more_recent(S1, S2, Max) ->
  if ((( S1 >= S2 ) and ( S1 - S2 =< Max / 2 )) or (( S2 >= S1 ) and ( S2 - S1  > Max / 2 ))) -> true;
    true -> false
  end.

bin_to_num(Bin) when is_binary(Bin) ->
  N = binary_to_list(Bin),
  case string:to_float(N) of
    {error, no_float} -> list_to_integer(N);
    {F, _Rest} -> F
  end;
bin_to_num(N) when is_list(N) ->
  case string:to_float(N) of
    {error, no_float} -> list_to_integer(N);
    {F, _Rest} -> F
  end.

increase_pkgid(SM) ->
  Max_pkg_id = readETS(SM, max_pkg_id),
  PkgID =
  case TmpPId = readETS(SM, packet_id) of
    _ when TmpPId >= Max_pkg_id -> 0; %-1;
    _ -> TmpPId
  end,
  ?TRACE(?ID, "Increase Pkg, Current Pkg id ~p~n", [PkgID + 1]),
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

% split_bin_comma(Bin) when is_binary(Bin) ->
%   binary:split(Bin, <<",">>,[global]).

neighbours_to_list(SM, Type) ->
  Current_neighbours = readETS(SM, current_neighbours),
  lists:foldr(fun(X, A) ->
                  case Type of
                    mac -> [addr_nl2mac(SM, X) | A];
                    nl  -> [X | A]
                  end
              end, [], Current_neighbours).

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
  [PFlag, SM1, HRcvPayload] =
  case parse_payload(SM, RcvPayload) of
    [relay, Payload] ->
      [relay, SM, Payload];
    [reverse, Payload] ->
      [reverse, SM, Payload];
    [ack, Payload] ->
      [ack, SM, Payload];
    [dst, Payload] ->
      [dst, clear_spec_timeout(SM, retransmit), Payload]
  end,

  {at, _PID, _, _, _, CurrentPayload} = Current_msg,
  [_CRole, HCurrentPayload] = parse_payload(SM, CurrentPayload),
  check_payload(SM1, PFlag, HRcvPayload, HCurrentPayload, Current_msg).

parse_payload(SM, Payload) ->
  try
    [Flag, PkgID, Dst, Src, _Data] = extract_payload_nl_flag(Payload),
    ?TRACE(?ID, "parse_payload Flag ~p PkgID ~p Dst ~p Src ~p~n",
          [num2flag(Flag, nl), PkgID, Dst, Src]),
    [check_dst(Flag), {PkgID, Dst, Src}]
  catch error: _Reason -> [relay, Payload]
  end.

check_payload(SM, Flag, HRcvPayload, {PkgID, Dst, Src}, Current_msg) ->
  HCurrentPayload = {PkgID, Dst, Src},
  RevCurrentPayload = {PkgID, Src, Dst},
  ExaxtTheSame = (HCurrentPayload == HRcvPayload),
  IfDstReached = (Flag == dst),
  AckReversed = (( Flag == ack ) and (RevCurrentPayload == HRcvPayload)),

  if (ExaxtTheSame or IfDstReached or AckReversed) ->
       insertETS(SM, current_msg, {delivered, Current_msg}),
       clear_spec_timeout(SM, retransmit);
    true ->
       SM
  end;
check_payload(SM, _, _, _, _) ->
  SM.

check_dst(Flag) ->
  case num2flag(Flag, nl) of
    dst_reached -> dst;
    ack -> ack;
    path -> reverse;
    path_addit -> reverse;
    _ -> relay
  end.

process_send_payload(SM, Msg) ->
  {at, _PID, _, _, _, Payload} = Msg,
  case parse_payload(SM, Payload) of
    [Flag, _P] when Flag == reverse; Flag == relay; Flag =:= ack ->
      SM1 = clear_spec_timeout(SM, retransmit),
      Tmo_retransmit = rand_float(SM, tmo_retransmit),
      fsm:set_timeout(SM1, {ms, Tmo_retransmit}, {retransmit, {not_delivered, Msg}});
    [dst, _P] ->
      SM;
    _ ->
      SM
  end.

process_retransmit(SM, Msg, Ev) ->
  Retransmit_count = readETS(SM, {retransmit_count, Msg}),
  Max_retransmit_count = readETS(SM, max_retransmit_count),
  ?TRACE(?ID, "Retransmit Tuple ~p Retransmit_count ~p ~n ", [Msg, Retransmit_count]),

  case Retransmit_count of
    not_inside ->
      insertETS(SM, {retransmit_count, Msg}, 0),
      [SM#sm{event = Ev}, {Ev, Msg}];
    _ when Retransmit_count < Max_retransmit_count - 1 ->
      insertETS(SM, {retransmit_count, Msg}, Retransmit_count + 1),
      SM1 = process_send_payload(SM, Msg),
      [SM1#sm{event = Ev}, {Ev, Msg}];
    _ ->
      [SM, {}]
  end.
%%--------------------------------------------------  command functions -------------------------------------------
process_command(SM, Debug, Command) ->
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
      [readETS(SM, pr_state), protocol_state];
    {protocol, _,states} ->
      Pr_states = readETS(SM, pr_states),
      [queue:to_list(Pr_states), protocols_state];
    {protocol, _,neighbours} ->
      [readETS(SM, current_neighbours), neighbours];
    {protocol, _,routing} ->
      [readETS(SM, routing_table), routing];
    _ -> [error, nothing]
  end,
  Answer =
  case Req of
    error ->
      {nl, error};
    Req when Req =:= not_inside; Req =:= []; Req =:= {[],[]} ->
      {nl, Asw, empty};
    _ ->
      case Command of
        {fsm,_} ->
          if Asw =:= state ->
               L = list_to_binary([atom_to_binary(SM#sm.state,utf8), "(", atom_to_binary(SM#sm.event,utf8), ")"]),
               {nl, fsm, Asw, L};
             true ->
               {nl, fsm, Asw, list_to_binary(Req)}
          end;
        {statistics,_,paths} when Protocol#pr_conf.pf ->
          {nl, statistics, paths, get_stat(SM, paths) };
        {statistics, _,neighbours} ->
          {nl, statistics, neighbours, get_stat(SM, st_neighbours) };
        {statistics, _,data} when Protocol#pr_conf.ack ->
          {nl, statistics, data, get_stat_data(SM, st_data) };
        protocols ->
          {nl, Command, Req};
        {protocol, Name, info} ->
          {nl, protocol, Asw, get_protocol_info(SM, Name)};
        {protocol, _, neighbours} ->
          {nl, protocol, Asw, neighbours_to_bin(SM, nl)};
        {protocol, _, routing} ->
          {nl, protocol, Asw, routing_to_bin(SM)};
        {protocol, Name, state} ->
          L = list_to_binary([atom_to_binary(Name,utf8), ",", Req]),
          {nl, protocol, state, L};
        {protocol, Name, states} ->
          L = list_to_binary([atom_to_binary(Name,utf8), "\n", Req]),
          {nl, protocol, states, L};
        _ ->
          {nl, error}
      end
  end,
  if Debug =:= true ->
    ?TRACE(?ID, "Command answer ~p~n", [Answer]);
  true ->
    fsm:cast(SM, nl, {send, {sync, Answer}})
  end,
  SM.

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
      {Role, Val, Time, Count, TS} = X,
      TRole = if Role =:= source -> "Source"; true -> "Relay" end,
      BTime = list_to_binary(lists:flatten(io_lib:format("~.1f", [Time]))),
      case Qname of
        paths ->
          [list_to_binary(
          ["\n ", TRole, " ", "Path:", covert_type_to_bin(Val),
           " Time:", BTime, " Count:", integer_to_binary(Count),
           " Total:", integer_to_binary(TS)]) | A];
        st_neighbours ->
          [list_to_binary(
          ["\n ", TRole, " ", "Neighbour:", covert_type_to_bin(Val),
           " Count:", integer_to_binary(Count),
           " Total:", integer_to_binary(TS)]) | A]
      end
    end, [], queue:to_list(PT)).

logs_additional(SM, Role) ->
  Protocol   = readETS(SM, {protocol_config, readETS(SM, np)}),

  if(Role =:= source) ->
    if Protocol#pr_conf.pf  ->
      process_command(SM, true, {statistics,"",data}),
      process_command(SM, true, {statistics, "", paths}),
      process_command(SM, false, {statistics, "", data}),
      process_command(SM, false, {statistics, "", paths});
    true -> nothing end,
    process_command(SM, false, {protocol, "", neighbours}),
    process_command(SM, true, {statistics, "", neighbours}),
    process_command(SM, true, {protocol, "", neighbours}),
    if Protocol#pr_conf.pf;
       Protocol#pr_conf.stat->
    process_command(SM, true, {protocol, "", routing}),
    process_command(SM, false, {protocol, "", routing});
    true -> nothing end;
  true ->
    nothing
  end.

save_stat(SM, {ISrc, IDst}, Role)->
  case Role of
    source ->
      S_total_sent = readETS(SM, s_total_sent),
      insertETS(SM, s_send_time, {{ISrc, IDst}, os:timestamp()}),
      insertETS(SM, s_total_sent, S_total_sent + 1);
    relay ->
      R_total_sent = readETS(SM, r_total_sent),
      insertETS(SM, r_send_time, {{ISrc, IDst}, os:timestamp()}),
      insertETS(SM, r_total_sent, R_total_sent + 1);
    _ ->
      nothing
  end.

get_stats_time(SM, Real_src, Real_dst) ->
  Local_address = readETS(SM, local_address),
  if Local_address =:= Real_src;
     Local_address =:= Real_dst ->
     ST_send_time = readETS(SM, s_send_time),
     {Addrs, S_send_time} = parse_tuple(ST_send_time),
     S_total_sent = readETS(SM, s_total_sent),
     {S_send_time, source, S_total_sent, Addrs};
  true ->
     RT_send_time = readETS(SM, r_send_time),
     {Addrs, R_send_time} = parse_tuple(RT_send_time),
     R_total_sent = readETS(SM, r_total_sent),
     {R_send_time, relay, R_total_sent, Addrs}
  end.

parse_tuple(Tuple) ->
  case Tuple of
    not_inside ->
      {not_inside, not_inside};
    _ ->
      Tuple
  end.

path_to_bin(SM, Path) ->
  RevPath = lists:reverse(Path),
  CheckDblPath = remove_dubl_in_path(RevPath),
  lists:foldr(
    fun(X, A) ->
      Sign =
      if byte_size(A) =:= 0 ->"";
       true -> ","
      end,
      list_to_binary([integer_to_binary(addr_mac2nl(SM, X)), Sign, A])
    end, <<>>, CheckDblPath).

analyse(SM, QName, Path, {Real_src, Real_dst}) ->
  {Time, Role, TSC, _Addrs} = get_stats_time(SM, Real_src, Real_dst),

  BPath =
  case QName of
    paths when Path =:= nothing ->
      <<>>;
    paths ->
      path_to_bin(SM, Path);
    st_neighbours ->
      Path;
    st_data ->
      Path
  end,

  case Time of
    not_inside  when QName =/= st_data ->
      Tuple = {Role, BPath, 0.0, 1, TSC},
      add_item_to_queue_nd(SM, QName, Tuple, 300);
    _ when QName =/= st_data ->
      TDiff = timer:now_diff(os:timestamp(), Time),
      CTDiff = convert_t(TDiff, {us, s}),
      Tuple = {Role, BPath, CTDiff, 1, TSC},
      add_item_to_queue_nd(SM, QName, Tuple, 300);
    not_inside  when QName =:= st_data ->
      {P, Dst, Count_hops, St} = BPath,
      Tuple = {Role, P, 0.0, byte_size(P), St, TSC, Dst, Count_hops},
      add_item_to_queue_nd(SM, QName, Tuple, 300);
    _ when QName =:= st_data ->
      {P, Dst, Count_hops, St} = BPath,
      TDiff = timer:now_diff(os:timestamp(), Time),
      CTDiff = convert_t(TDiff, {us, s}),
      Tuple = {Role, P, CTDiff, byte_size(P), St, TSC, Dst, Count_hops},
      add_item_to_queue_nd(SM, QName, Tuple, 300)
  end,
  logs_additional(SM, Role).

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
