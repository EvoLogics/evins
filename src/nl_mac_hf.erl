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
-export([convert_to_binary/1, convert_type_to_bin/1, convert_t/2, convert_la/3, count_flag_bits/1]).
%% DETS functions
-export([init_dets/1, fill_dets/1]).
%% handle events
-export([event_params/3, clear_spec_timeout/2]).
%% Math functions
-export([rand_float/2, lerp/3]).
%% Addressing functions
-export([init_nl_addrs/1, get_dst_addr/1, set_dst_addr/2]).
-export([addr_nl2mac/2, addr_mac2nl/2, get_routing_addr/3, num2flag/2, flag2num/1]).
%% NL header functions
-export([parse_path_data/2]).
%% Extract functions
-export([extract_payload_mac_flag/1, extract_payload_nl_flag/1, create_ack/1, extract_ack/2]).
%% Extract/create header functions
-export([extract_neighbours_path/2]).
%% Send NL functions
-export([send_nl_command/4, send_ack/3, send_path/2, send_helpers/4, send_cts/6, send_mac/4, fill_msg/2]).
%% Parse NL functions
-export([prepare_send_path/3, parse_path/3, save_path/3]).
%% Process NL functions
-export([add_neighbours/5, process_pkg_id/3, process_relay/2, process_path_life/2, routing_to_bin/1, check_dubl_in_path/2]).
%% RTT functions
-export([getRTT/2, smooth_RTT/3]).
%% command functions
-export([process_command/3, save_stat_time/3, update_states_list/1, save_stat_total/2]).
%% Only MAC functions
-export([process_rcv_payload/3, process_send_payload/2, process_retransmit/3]).
%% Other functions
-export([bin_to_num/1, increase_pkgid/1, add_item_to_queue/4, analyse/4]).
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
  list_to_binary([Header | lists:join(",", [convert_type_to_bin(X) || X <- T])]).

convert_type_to_bin(X) ->
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
  {Start, End} = share:get(SM, Random_interval),
  (Start + rand:uniform() * (End - Start)) * 1000.

lerp(A, B, F) -> A + F * (B - A).

%%-------------------------------------------------- Send NL functions -------------------------------------------
send_helpers(SM, Interface, MACP, Flag) ->
  {at, PID, SENDFLAG, IDst, TFlag, _} = MACP,
  Data=
  case Flag of
    tone -> <<"t">>;
    rts   ->
      C = share:get(SM, sound_speed),
      % max distance between nodes in the network, in m
      U = share:get(SM, u, IDst, share:get(SM, u)),
      T_us = erlang:round( convert_t( (U / C), {s, us}) ), % to us
      integer_to_binary(T_us);
    warn ->
      <<"w">>
  end,
  Tuple = {at, PID, SENDFLAG, IDst, TFlag, Data},
  send_mac(SM, Interface, Flag, Tuple).

send_cts(SM, Interface, MACP, Timestamp, USEC, Dur) ->
  {at, PID, _, IDst, _, _} = MACP,
  Tuple = {at, PID,"*SENDIMS", IDst, Timestamp + USEC, convert_type_to_bin(Dur + USEC)},
  send_mac(SM, Interface, cts, Tuple).

send_mac(SM, _Interface, Flag, MACP) ->
  AT = mac2at(Flag, MACP),
  fsm:send_at_command(SM, AT).

send_ack(SM,  {send_ack, {_, [Packet_id, _, _PAdditional]}, {async, {nl, recv, Real_dst, Real_src, _}}}, Count_hops) ->
  BCount_hops = create_ack(Count_hops),
  send_nl_command(SM, alh, {ack, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BCount_hops}).

send_path(SM, {send_path, {Flag, [Packet_id, _, _PAdditional]}, {async, {nl, recv, Real_dst, Real_src, Payload}}}) ->
  MAC_addr  = convert_la(SM, integer, mac),
  case share:get(SM, current_neighbours) of
    nothing -> error;
    Neighbours ->
      BCN = neighbours_to_list(SM,Neighbours, mac),
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

          % FIXME: below lost updated SM value
          SM1 = process_and_update_path(SMNTmp, {Real_src, Real_dst, RCheckDblPath} ),
          analyse(SMNTmp, paths, RCheckDblPath, {Real_src, Real_dst}),
          [SM1, fill_msg(neighbours_path, {BCN, RCheckDblPath})]
      end,
      send_nl_command(SMN, alh, {path, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BMsg})
  end.

send_nl_command(SM, Interface, {Flag, [IPacket_id, Real_src, _PAdditional]}, NL) ->
  Real_dst = get_dst_addr(NL),
  Protocol = share:get(SM, protocol_config, share:get(SM, np)),
  if Real_dst =:= wrong_format -> error;
     true ->
       Route_addr = get_routing_addr(SM, Flag, Real_dst),
       [MAC_addr, MAC_real_src, MAC_real_dst] = addr_nl2mac(SM, [Route_addr, Real_src, Real_dst]),
       if(Route_addr =:= no_routing_table) ->
        ?ERROR(?ID, "~s: Wrong Route_addr:~p, check config file ~n", [?MODULE, Route_addr]);
        true -> nothing
       end,

       ?TRACE(?ID, "Route_addr ~p, MAC_addrm ~p, MAC_real_src ~p, MAC_real_dst ~p~n", [Route_addr, MAC_addr, MAC_real_src, MAC_real_dst]),
       if ((MAC_addr =:= error) or (MAC_real_src =:= error) or (MAC_real_dst =:= error)
           or ((MAC_real_dst =:= ?BITS_ADDRESS_MAX) and Protocol#pr_conf.br_na)) ->
            error;
          true ->
            NLarp = set_dst_addr(NL, MAC_addr),
            AT = nl2at(SM, {Flag, IPacket_id, MAC_real_src, MAC_real_dst, NLarp}),
            if NLarp =:= wrong_format -> error;
               true ->
                 ?TRACE(?ID, "Send AT command ~p~n", [AT]),
                 Local_address = share:get(SM, local_address),
                 CurrentRTT = {rtt, Local_address, Real_dst},
                 ?TRACE(?ID, "CurrentRTT sending AT command ~p~n", [CurrentRTT]),
                 share:put(SM, [{{last_nl_sent_time, CurrentRTT}, erlang:monotonic_time(micro_seconds)},
                                {last_nl_sent, {Flag, Real_src, NLarp}},
                                {ack_last_nl_sent, {IPacket_id, Real_src, Real_dst}}]),
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
  ETSPID =  list_to_binary(["p", integer_to_binary(share:get(SM, pid))]),
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
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
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
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
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


%-------> data
% 3b        6b
%   TYPEMSG   MAX_DATA_LEN
create_data(TransmitLen, Data) ->
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  TypeNum = ?TYPEMSG2NUM(data),

  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenData = <<TransmitLen:CBitsMaxLenData>>,

  BHeader = <<BType/bitstring, BLenData/bitstring>>,
  Add = (8 - (bit_size(BHeader)) rem 8) rem 8,
  <<BHeader/bitstring, 0:Add, Data/binary>>.

%%----------------NL functions create/extract protocol header-------------------
%-------> path_data
%   3b        6b            6b        LenPath * 6b   REST till / 8
%   TYPEMSG   MAX_DATA_LEN  LenPath   Path           ADD
create_path_data(Path, TransmitLen, Data) ->
  LenPath = length(Path),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  TypeNum = ?TYPEMSG2NUM(path_data),

  BLenData = <<TransmitLen:CBitsMaxLenData>>,
  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = code_header(path, Path),

  BHeader = <<BType/bitstring, BLenData/bitstring, BLenPath/bitstring, BPath/bitstring>>,
  Add = (8 - (bit_size(BHeader)) rem 8) rem 8,
  <<BHeader/bitstring, 0:Add, Data/binary>>.

extract_path_data(SM, Payl) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  CBitsMaxLenData = count_flag_bits(?MAX_DATA_LEN),

  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  <<BType:CBitsTypeMsg, BLenData:CBitsMaxLenData, PathRest/bitstring>> = Payl,

  {Path, Rest} =
  case ?NUM2TYPEMSG(BType) of
    path_data ->
      extract_header(path, CBitsLenPath, CBitsLenPath, PathRest);
    data ->
      {nothing, PathRest}
  end,

  ?TRACE(?ID, "extract path data BType ~p ~n", [BType]),
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [Path, BLenData, Data];
  true ->
    [Path, BLenData, Rest]
  end.

decode_header(neighbours, Neighbours) ->
  W = count_flag_bits(?BITS_LEN_NEIGBOURS),
  [N || <<N:W>> <= Neighbours];

decode_header(path, Paths) ->
  W = count_flag_bits(?BITS_LEN_PATH),
  [P || <<P:W>> <= Paths];

decode_header(add, AddInfos) ->
  W = count_flag_bits(?BITS_ADD),
  [N || <<N:W>> <= AddInfos].

extract_header(Id, LenWidth, FieldWidth, Input) ->
  <<Len:LenWidth, _/bitstring>> = Input,
  Width = Len * FieldWidth,
  <<_:LenWidth, BField:Width/bitstring, Rest/bitstring>> = Input,
  {decode_header(Id, BField), Rest}.

code_header(neighbours, Neighbours) ->
  W = count_flag_bits(?BITS_LEN_NEIGBOURS),
  << <<N:W>> || N <- Neighbours>>;

code_header(path, Paths) ->
  W = count_flag_bits(?BITS_LEN_PATH),
  << <<N:W>> || N <- Paths>>;

code_header(add, AddInfos) ->
  W = count_flag_bits(?BITS_ADD),
  Saturated_integrities = lists:map(fun(S) when S > 255 -> 255; (S) -> S end, AddInfos),
  << <<N:W>> || N <- Saturated_integrities>>.

parse_path_data(SM, Payl) ->
  try
    MAC_addr = convert_la(SM, integer, mac),
    %[Path, LenData, BData] = extract_path_data(SM, Payl),
    case extract_path_data(SM, Payl) of
      [nothing, LenData, BData] ->
        {LenData, BData, nothing};
      [Path, LenData, BData] ->
        CheckedDblPath = check_dubl_in_path(Path, MAC_addr),
        ?TRACE(?ID, "recv parse path data ~p Data ~p~n", [CheckedDblPath, BData]),
        {LenData, BData, CheckedDblPath}
    end
  catch error: Reason ->
    ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
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
     Add = (8 - bit_size(BCountHops) rem 8) rem 8,
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
create_neighbours(Neighbours) ->
  LenNeighbours = length(Neighbours),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?BITS_LEN_NEIGBOURS),
  TypeNum = ?TYPEMSG2NUM(neighbours),

  BType = <<TypeNum:CBitsTypeMsg>>,
  BLenNeigbours = <<LenNeighbours:CBitsLenNeigbours>>,
  BNeighbours = code_header(neighbours, Neighbours),

  TmpData = <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = (8 - bit_size(TmpData) rem 8) rem 8,
     <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring, 0:Add>>;
   true ->
     TmpData
  end.

create_neighbours_path(Neighbours, Path) ->
  LenNeighbours = length(Neighbours),
  LenPath = length(Path),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?BITS_LEN_NEIGBOURS),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  TypeNum = ?TYPEMSG2NUM(neighbours_path),

  BType = <<TypeNum:CBitsTypeMsg>>,

  BLenNeigbours = <<LenNeighbours:CBitsLenNeigbours>>,
  BNeighbours = code_header(neighbours, Neighbours),

  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = code_header(path, Path),

  TmpData = <<BType/bitstring, BLenNeigbours/bitstring, BNeighbours/bitstring,
              BLenPath/bitstring, BPath/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = (8 - bit_size(TmpData) rem 8) rem 8,
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

    <<BType:CBitsTypeMsg, NeighboursRest/bitstring>> = Payl,

    neighbours_path = ?NUM2TYPEMSG(BType),

    {Neighbours, PathRest} = extract_header(neighbours, CBitsLenNeigbours, CBitsLenNeigbours, NeighboursRest),
    {Path, _} = extract_header(path, CBitsLenPath, CBitsLenPath, PathRest),

    ?TRACE(?ID, "Extract neighbours path BType ~pNeighbours ~p Path ~p~n",
          [BType, Neighbours, Path]),

    [Neighbours, Path]
   catch error: Reason ->
     ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
     [[], nothing]
   end.

%%--------------- path_addit -------------------
%-------> path_addit
%   3b        6b        LenPath * 6b    2b        LenAdd * 8b       REST till / 8
%   TYPEMSG   LenPath   Path            LenAdd    Addtional Info     ADD
create_path_addit(Path, Additional) ->
  LenPath = length(Path),
  LenAdd = length(Additional),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?BITS_LEN_ADD),
  TypeNum = ?TYPEMSG2NUM(path_addit),

  BType = <<TypeNum:CBitsTypeMsg>>,

  BLenPath = <<LenPath:CBitsLenPath>>,
  BPath = code_header(path, Path),

  BLenAdd = <<LenAdd:CBitsLenAdd>>,
  BAdd = code_header(add, Additional),
  TmpData = <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
            BLenAdd/bitstring, BAdd/bitstring>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = (8 - bit_size(TmpData) rem 8) rem 8,
     <<BType/bitstring, BLenPath/bitstring, BPath/bitstring,
            BLenAdd/bitstring, BAdd/bitstring, 0:Add>>;
   true ->
     TmpData
  end.

extract_path_addit(SM, Payl) ->
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenPath = count_flag_bits(?BITS_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?BITS_LEN_ADD),
  CBitsAdd = count_flag_bits(?BITS_ADD),

  <<BType:CBitsTypeMsg, PathRest/bitstring>> = Payl,
  {Path, AddRest} = extract_header(path, CBitsLenPath, CBitsLenPath, PathRest),
  {Additional, _} = extract_header(add, CBitsLenAdd, CBitsAdd, AddRest),

  path_addit = ?NUM2TYPEMSG(BType),

  ?TRACE(?ID, "extract path addit BType ~p  Path ~p Additonal ~p~n",
        [BType, Path, Additional]),

  [Path, Additional].

%%-------------------------Addressing functions --------------------------------
flag2num(Flag) when is_atom(Flag)->
  integer_to_binary(?FLAG2NUM(Flag)).

num2flag(Num, Layer) when is_integer(Num)->
  ?NUM2FLAG(Num, Layer);
num2flag(Num, Layer) when is_binary(Num)->
  ?NUM2FLAG(binary_to_integer(Num), Layer).

init_nl_addrs(SM) ->
  share:put(SM, table_nl_mac_addrs, ?TABLE_LADDR_MACADDR).

get_dst_addr({nl, send, IDst,_}) -> IDst;
get_dst_addr({at, _, _, IDst, _, _}) -> IDst.

set_dst_addr({nl, send, _, Data}, Addr) -> {nl, send, Addr, Data}.

addr_nl2mac(SM, ListAddr) when is_list(ListAddr) ->
  lists:map(fun(Addr) -> addr_nl2mac(SM, Addr) end, ListAddr);
addr_nl2mac(SM, NLAddr) ->
  case lists:keyfind(NLAddr, 1, share:get(SM, table_nl_mac_addrs)) of
    {_, MACAddr} -> MACAddr;
    _ -> error
  end.

addr_mac2nl(SM, ListAddr) when is_list(ListAddr) ->
  lists:map(fun(Addr) -> addr_mac2nl(SM, Addr) end, ListAddr);
addr_mac2nl(SM, MACAddr) when is_integer(MACAddr) ->
  case lists:keyfind(MACAddr, 2, share:get(SM, table_nl_mac_addrs)) of
    {NLAddr, _} -> NLAddr;
    false -> error
  end.

required_routing(_,_,staticr) -> true;
required_routing(_,_,staticrack) -> true;
required_routing(Flag,#pr_conf{pf = true},_) when Flag =:= data; Flag =:= ack -> true;
required_routing(path,#pr_conf{lo = LO, dbl = DBL},_) when LO; DBL -> true;
required_routing(_,_,_) -> false.

get_routing_addr(SM, Flag, AddrSrc) ->
  NProtocol = share:get(SM, np),
  Protocol = share:get(SM, protocol_config, NProtocol),
  case required_routing(Flag, Protocol, NProtocol) of
    true -> find_in_routing_table(share:get(SM, routing_table), AddrSrc);
    false -> ?BITS_ADDRESS_MAX
  end.

find_in_routing_table(?BITS_ADDRESS_MAX, _) -> ?BITS_ADDRESS_MAX;
find_in_routing_table([], _) -> no_routing_table;
find_in_routing_table(Routing_table, AddrSrc) ->
  case lists:keyfind(AddrSrc, 1, Routing_table) of
    {_, To} -> To;
    false -> ?BITS_ADDRESS_MAX
  end.

convert_la(SM, Type, Format) ->
  LAddr  = share:get(SM, local_address),
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
fill_msg(data, {TransmitLen, Data}) ->
  create_data(TransmitLen, Data);
fill_msg(neighbours, Tuple) ->
  create_neighbours(Tuple);
fill_msg(neighbours_path, {Neighbours, Path}) ->
  create_neighbours_path(Neighbours, Path);
fill_msg(path_data, {TransmitLen, Data, Path}) ->
  create_path_data(Path, TransmitLen, Data);
fill_msg(path_addit, {Path, Additional}) ->
  create_path_addit(Path, Additional).

prepare_send_path(SM, [_ , _, PAdditional], {async,{nl, recv, Real_dst, Real_src, Payload}}) ->
  MAC_addr = convert_la(SM, integer, mac),
  {nl, send, CurrentLen, IDst, Data} = share:get(SM, current_pkg),

  [ListNeighbours, ListPath] = extract_neighbours_path(SM, Payload),
  NPathTuple = {ListNeighbours, ListPath},
  [SM1, BPath] = parse_path(SM, NPathTuple, {Real_src, Real_dst}),
  NPath = [MAC_addr | BPath],

  case get_routing_addr(SM, path, Real_dst) of
    ?BITS_ADDRESS_MAX -> nothing;
    _ -> analyse(SM1, paths, NPath, {Real_src, Real_dst})
  end,

  SDParams = {data, [increase_pkgid(SM), share:get(SM, local_address), PAdditional]},
  SDTuple = {nl, send, IDst, fill_msg(path_data, {CurrentLen, Data, NPath})},

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
        SMN = process_and_update_path(SM, {ISrc, IDst, ListPath}),
        [SMN, ListPath];
       false ->
        [SM, ListPath]
     end
  end.

add_neighbours(SM, Flag, NLSrcAT, {RealSrc, Real_dst}, {IRssi, IIntegrity}) ->
  ?INFO(?ID, "+++ Flag ~p, NLSrcAT ~p, RealSrc ~p~n", [Flag, NLSrcAT, RealSrc]),
  Neighbours_channel = share:get(SM, neighbours_channel),
  SM1 = fsm:set_timeout(SM, {s, share:get(SM, neighbour_life)}, {neighbour_life, NLSrcAT}),
  analyse(SM1, st_neighbours, NLSrcAT, {RealSrc, Real_dst}),
  Add_neighbours =
  fun(Neighbours) ->
       case lists:member(NLSrcAT, Neighbours) of
         _ when Neighbours_channel == nothing ->
            share:put(SM1, neighbours_channel, [ {NLSrcAT, IRssi, IIntegrity}]),
            [NLSrcAT];
         true ->
            El = {_, ETSrssi, ETSintegrity} = lists:keyfind(NLSrcAT, 1, Neighbours_channel),
            NewRssi = (IRssi + ETSrssi) / 2,
            NewIntegrity = (ETSintegrity + IIntegrity) / 2,
            Updated_neighbours_channel = lists:delete(El, Neighbours_channel),
            share:put(SM1, neighbours_channel, [ {NLSrcAT, NewRssi, NewIntegrity} | Updated_neighbours_channel]),
            Neighbours;
         false ->
            share:put(SM1, neighbours_channel, [ {NLSrcAT, IRssi, IIntegrity} | Neighbours_channel]),
            [NLSrcAT | Neighbours]
       end
    end,

  share:update_with(SM1, current_neighbours, Add_neighbours, []).
%%-------------------------------------------------- Process NL functions -------------------------------------------
get_aver_value(0, Val2) ->
  round(Val2);
get_aver_value(Val1, Val2) ->
  round((Val1 + Val2) / 2).

process_relay(SM, Tuple = {send, Params, {nl, send, IDst, Payload}}) ->
  {Flag, [_, ISrc, PAdditional]} = Params,
  MAC_addr = convert_la(SM, integer, mac),
  Protocol = share:get(SM, protocol_config, share:get(SM, np)), 
  case Flag of
    data when (Protocol#pr_conf.pf and Protocol#pr_conf.ry_only) ->
      CheckedTuple = parse_path_data(SM, Payload),
      {_, Add, Path} = CheckedTuple,
      NewPayload = fill_msg(path_data, CheckedTuple),
      [SMN1, _]  = parse_path(SM, {Add, Path}, {ISrc, IDst}),
      [SMN1, {send, Params, {nl, send, IDst, NewPayload}}];
    data when Protocol#pr_conf.pf ->
      CheckedTuple = parse_path_data(SM, Payload),
      {_, Add, Path} = CheckedTuple,
      [SMN, _] = parse_path(SM, {Add, Path}, {ISrc, IDst}),
      [SMN, Tuple];
    data ->
      [SM, Tuple];
    neighbours ->
      case LNeighbours = neighbours_to_list(SM, share:get(SM, current_neighbours), mac) of
        [] ->
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
      case LNeighbours = neighbours_to_list(SM, share:get(SM, current_neighbours), mac) of
        [] -> [SM, not_relay];
        _ ->
          Local_address = share:get(SM, local_address),
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

process_and_update_path(SM, {ISrc, IDst, ListPath}) ->
  LAddr = share:get(SM, local_address),
  NLListPath = [addr_mac2nl(SM, X) || X <- ListPath],
  MemberSrcL = lists:member(ISrc, NLListPath),
  MemberDstL = lists:member(IDst, NLListPath),
  NLOrderListPath =
    case {MemberSrcL, MemberDstL, hd(NLListPath)} of
      {true, true, ISrc} -> NLListPath;
      {true, false, _} -> NLListPath;
      {true, true, IDst} -> lists:reverse(NLListPath);
      {false, true, _} -> lists:reverse(NLListPath)
    end,

  {LSrc, LDst} = lists:splitwith(fun(A) -> A =/= LAddr end, NLOrderListPath),
  LRevSrc = lists:reverse(LSrc),
  case {LSrc, LDst} of
    {_,[]} ->
      SM;
    {[_],[_]} ->
      {PSrc, Pdst} =
      if (ISrc =:= LAddr) -> {LDst, IDst};
        true -> {LSrc, ISrc}
      end,
      [SM1, NList] = process_route_table(SM, PSrc, Pdst, []),
      update_route_table(SM1, NList);
    {_, _} when length(LSrc) =< 1 -> % FIXME: suspicious condition
      process_route_table_helper(SM, lists:nth(2, LDst), LDst);
    {_, [_]} ->
      process_route_table_helper(SM, hd(LRevSrc), LRevSrc);
    _ ->
      SM1 = process_route_table_helper(SM, hd(LRevSrc), LRevSrc),
      process_route_table_helper(SM1, lists:nth(2, LDst), LDst)
  end.

process_route_table_helper(SM, FromAddr, NListPath) ->
  case share:get(SM, current_neighbours) of
    nothing -> SM;
    _ ->
      case lists:member(FromAddr, share:get(SM, current_neighbours)) of
        true  ->
          [SM1, NList] = process_route_table(SM, NListPath, FromAddr, []),
          update_route_table(SM1, NList);
        false ->
          SM
      end
  end.
process_route_table(SM, [],_, Routing_table) ->
  [SM, lists:reverse([?BITS_ADDRESS_MAX | Routing_table]) ];
process_route_table(SM, [H | T], NLFrom, Routing_table) ->
  SM1 = fsm:set_timeout(SM, {s, share:get(SM, path_life)}, {path_life, {H, NLFrom}}),
  process_route_table(SM1, T, NLFrom, [ {H, NLFrom} | Routing_table]).

process_path_life(SM, Tuple) ->
  share:update_with(SM, routing_table, fun(T) -> lists:delete(Tuple, T) end).

% FIXME: better to store protocol_config at env
save_path(SM, {Flag,_} = Params, Tuple) ->
  Protocol = share:get(SM, protocol_config, share:get(SM, np)),
  case Flag of
    data when Protocol#pr_conf.ry_only and Protocol#pr_conf.pf ->
      {async,{nl,recv, Real_src, Real_dst, Payload}} = Tuple,
      {_, _, Path} = parse_path_data(SM, Payload),
      analyse(SM, paths, Path, {Real_src, Real_dst});
    path_addit when Protocol#pr_conf.evo ->
      {async,{nl,recv, _, _, Payload}} = Tuple,
      [_, [DIRssi, DIIntegr]] = extract_path_addit(SM, Payload),
      El = { DIRssi, DIIntegr, {Params, Tuple} },
      share:update_with(SM, list_current_wvp, fun(L) -> L ++ [El] end);
    _ -> SM
  end.

update_route_table(SM, NRouting_table) ->
  ORouting_table = share:get(SM, routing_table),
  LRouting_table = if ORouting_table =:= ?BITS_ADDRESS_MAX -> [?BITS_ADDRESS_MAX]; true -> ORouting_table end,
  SMN1 =
  lists:foldr(
     fun(X, SMTmp) ->
       if is_tuple(X) -> fsm:set_timeout(SMTmp, {s, share:get(SMTmp, path_life)}, {path_life, X});
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
  share:put(SMN2, routing_table, Routing_table).

process_pkg_id(SM, ATParams, Tuple = {RemotePkgID, RecvNLSrc, RecvNLDst, _}) ->
  %{ATSrc, ATDst} = ATParams,
  Local_address = share:get(SM, local_address),
  LocalPkgID = share:get(SM, packet_id),
  Max_pkg_id = share:get(SM, max_pkg_id),
  MoreRecent = sequence_more_recent(RemotePkgID, LocalPkgID, Max_pkg_id),
  PkgIDOld =
  if MoreRecent -> share:put(SM, packet_id, RemotePkgID), false;
    true -> true
  end,
  %% not to relay packets with older ids
  case PkgIDOld of
    true when ((RecvNLDst =/= Local_address) and
              (RecvNLSrc =/= Local_address)) -> old_id;
    true when (RecvNLSrc =:= Local_address) -> processed;
    _ ->
      Queue_ids = share:get(SM, queue_ids),
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
          share:put(SM, queue_ids, NewQ),
          processed;
        false ->
          % check if same package was received from other src dst,
          % if yes  -> share:put(SM, queue_ids, NewQ), processed
          % if no -> share:put(SM, queue_ids, queue:in(NTuple, NewQ)), not_processed
          Skey = searchKey(NTuple, NewQ, not_found),
          if Skey == found ->
            share:put(SM, queue_ids, NewQ),
            processed;
          true ->
            share:put(SM, queue_ids, queue:in(NTuple, NewQ)),
            not_processed
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
  case share:get(SM, RTTTuple) of
    nothing -> share:get(SM, rtt);
    RTT -> RTT
  end.

smooth_RTT(SM, Flag, RTTTuple={_,_,Dst}) ->
  ?TRACE(?ID, "RTT receiving AT command ~p~n", [RTTTuple]),
  Time_send_msg = share:get(SM, last_nl_sent_time, RTTTuple),
  Max_rtt = share:get(SM, max_rtt),
  Min_rtt = share:get(SM, min_rtt),
  case Time_send_msg of
    nothing -> nothing;
    _ ->
       EndValMicro = erlang:monotonic_time(micro_seconds) - Time_send_msg,
       CurrentRTT = getRTT(SM, RTTTuple),
       Smooth_RTT =
       if Flag =:= direct ->
        lerp( CurrentRTT, convert_t(EndValMicro, {us, s}), 0.05);
       true ->
        lerp(CurrentRTT, share:get(SM, rtt), 0.05)
       end,
       share:clean(SM, last_nl_sent_time),
       Val =
       case Smooth_RTT of
        _ when Smooth_RTT < Min_rtt ->
          share:put(SM, RTTTuple, Min_rtt),
          Min_rtt;
        _ when Smooth_RTT > Max_rtt ->
          share:put(SM, RTTTuple, Max_rtt),
          Max_rtt;
        _ ->
          share:put(SM, RTTTuple, Smooth_RTT),
          Smooth_RTT
       end,

       LA = share:get(SM, local_address),
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
  Max_pkg_id = share:get(SM, max_pkg_id),
  PkgID = case share:get(SM, packet_id) of
            Prev_id when Prev_id >= Max_pkg_id -> 1;
            (Prev_id) -> Prev_id + 1
          end,
  ?TRACE(?ID, "Increase Pkg, Current Pkg id ~p~n", [PkgID]),
  share:put(SM, packet_id, PkgID),
  PkgID - 1.

init_dets(SM) ->
  LA  = share:get(SM, local_address),
  Ref = SM#sm.dets_share,
  NL_protocol = share:get(SM, nl_protocol),
  B = dets:lookup(Ref, NL_protocol),
  SM1=
  case B of
    []  -> share:put(SM, packet_id, 0);
    [{NL_protocol, PkgID}] ->
      dets:insert(Ref, {NL_protocol, PkgID + 1}),
      share:put(SM, packet_id, PkgID + 1);
    _ -> dets:insert(Ref, {NL_protocol, 0}),
         share:put(SM, packet_id, 0)
  end,
  B1 = dets:lookup(Ref, NL_protocol),
  ?INFO(?ID, "Init dets LA ~p ~p~n", [LA, B1]),
  SM1#sm{dets_share = Ref}.

fill_dets(SM) ->
  LA  = share:get(SM, local_address),
  Ref = SM#sm.dets_share,
  NL_protocol = share:get(SM, nl_protocol),
  Packet_id = share:get(SM, packet_id),
  dets:insert(Ref, {NL_protocol, Packet_id}),
  B = dets:lookup(Ref, NL_protocol),
  ?INFO(?ID, "Fill_dets LA ~p ~p~n", [LA, B] ),
  SM#sm{dets_share = Ref}.

% split_bin_comma(Bin) when is_binary(Bin) ->
%   binary:split(Bin, <<",">>,[global]).

neighbours_to_list(SM,Neigbours, mac) ->
  [addr_nl2mac(SM,X) || X <- Neigbours];
neighbours_to_list(_,Neigbours, nl) ->
  Neigbours.

neighbours_to_bin(SM) ->
  F = fun(X) ->
        {Addr, Rssi, Integrity} = X,
        Baddr = convert_type_to_bin(Addr),
        Brssi = convert_type_to_bin(Rssi),
        Bintegrity = convert_type_to_bin(Integrity),
        list_to_binary([Baddr, ":", Brssi, ":", Bintegrity])
      end,

  list_to_binary(lists:join(",", [F(X) || X <- share:get(SM, neighbours_channel)])).

routing_to_bin(SM) ->
  Routing_table = share:get(SM, routing_table),
  Local_address = share:get(SM, local_address),
  case Routing_table of
    ?BITS_ADDRESS_MAX ->
      list_to_binary(["default->",integer_to_binary(?BITS_ADDRESS_MAX)]);
    _ ->
      Path = lists:filtermap(fun({From, To}) when From =/= Local_address ->
                                 {true, [integer_to_binary(From),"->",integer_to_binary(To)]};
                                ({_,_}) -> false;
                                (X) -> {true, ["default->",integer_to_binary(X)]}
                             end, Routing_table),
      list_to_binary(lists:join(",", Path))
  end.

add_item_to_queue(SM, Qname, Item, Max) ->
  Q = share:get(SM, Qname),
  NewQ=
  case queue:len(Q) of
    Len when Len >= Max ->  {_, Queue_out} = queue:out(Q), Queue_out;
    _ ->  Q
  end,
  %% FIXME: use update_with?
  share:put(SM, Qname, queue:in(Item, NewQ)).

%%--------------------------------------------------  Only MAC functions -------------------------------------------
process_rcv_payload(SM, nothing, _Payload) ->
  SM;
process_rcv_payload(SM, CurrentMsg, RcvPayload) ->
  PP = parse_payload(SM, RcvPayload),
  [PFlag, SM1, HRcvPayload] =
  case PP of
    [relay, Payload] ->
      [relay, SM, Payload];
    [reverse, Payload] ->
      [reverse, SM, Payload];
    [ack, Payload] ->
      [ack, SM, Payload];
    [dst, Payload] ->
      [dst, clear_spec_timeout(SM, retransmit), Payload]
  end,

  {at, _PID, _, _, _, CurrentPayload} = CurrentMsg,
  [_CRole, HCurrentPayload] = parse_payload(SM, CurrentPayload),
  check_payload(SM1, PFlag, HRcvPayload, HCurrentPayload).

parse_payload(SM, Payload) ->
  try
    [Flag, PkgID, Dst, Src, _Data] = extract_payload_nl_flag(Payload),
    ?TRACE(?ID, "parse_payload Flag ~p PkgID ~p Dst ~p Src ~p~n",
          [num2flag(Flag, nl), PkgID, Dst, Src]),
    [check_dst(Flag), {PkgID, Dst, Src}]
  catch error: Reason ->
    ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
    [relay, Payload]
  end.

check_payload(SM, _, <<"t">>, _) ->
  SM;
check_payload(SM, Flag, HRcvPayload, {PkgID, Dst, Src}) ->
  HCurrentPayload = {PkgID, Dst, Src},
  RevCurrentPayload = {PkgID, Src, Dst},
  ExactTheSame = (HCurrentPayload == HRcvPayload),
  IfDstReached = (Flag == dst),
  AckReversed = (( Flag == ack ) and (RevCurrentPayload == HRcvPayload)),

  if (ExactTheSame or IfDstReached or AckReversed) ->
       share:clean(SM, current_msg),
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
    path -> reverse;
    path_addit -> reverse;
    _ -> relay
  end.

process_send_payload(SM, Msg) ->
  {at, _PID, _, _, _, Payload} = Msg,
  share:clean(SM, data_to_sent),
  case parse_payload(SM, Payload) of
    [Flag, _P] when Flag == reverse; Flag == relay; Flag =:= ack ->
      SM1 = clear_spec_timeout(SM, retransmit),
      Tmo_retransmit = rand_float(SM, tmo_retransmit),
      fsm:set_timeout(SM1, {ms, Tmo_retransmit}, {retransmit, Msg});
    [dst, _P] ->
      SM;
    _ ->
      SM
  end.

process_retransmit(SM, Msg, Ev) ->
  Retransmit_count = share:get(SM, retransmit_count, Msg),
  Max_retransmit_count = share:get(SM, max_retransmit_count),
  ?TRACE(?ID, "Retransmit Tuple ~p Retransmit_count ~p ~n ", [Msg, Retransmit_count]),

  case Retransmit_count of
    nothing -> 
      share:put(SM, retransmit_count, Msg, 0),
      [SM#sm{event = Ev}, {Ev, Msg}];
    _ when Retransmit_count < Max_retransmit_count - 1 ->
      share:put(SM, retransmit_count, Msg, Retransmit_count + 1),
      SM1 = process_send_payload(SM, Msg),
      [SM1#sm{event = Ev}, {Ev, Msg}];
    _ ->
      [SM, {}]
  end.
%%--------------------------------------------------  command functions -------------------------------------------
process_command(SM, Debug, Command) ->
  Protocol   = share:get(SM, protocol_config, share:get(SM, np)),
  [Req, Asw] =
  case Command of
    protocols ->
      [?PROTOCOL_DESCR, protocols];
    {protocol, _} ->
      [share:get(SM, np), protocol_info];
    {statistics, paths} when Protocol#pr_conf.pf ->
      [share:get(SM, paths), paths];
    {statistics, neighbours} ->
      [share:get(SM, st_neighbours), neighbours];
    {statistics, data} when Protocol#pr_conf.ack ->
      [share:get(SM, st_data), data];
    states ->
      Last_states = share:get(SM, last_states),
      [queue:to_list(Last_states), states];
    state ->
      States = list_to_binary([atom_to_binary(SM#sm.state,utf8), "(", atom_to_binary(SM#sm.event,utf8), ")"]),
      [States, state];
    address ->
      [share:get(SM, local_address), address];
    neighbours ->
      [share:get(SM, current_neighbours), neighbours];
    routing ->
      [share:get(SM, routing_table), routing];
    _ -> [error, nothing]
  end,

  Answer =
  case Req of
    error ->
      {nl, error};
    Req when Req =:= nothing; Req =:= []; Req =:= {[],[]} ->
      {nl, Asw, empty};
    _ ->
      case Command of
        {statistics, paths} when Protocol#pr_conf.pf ->
          {nl, statistics, paths, get_stat(SM, paths) };
        {statistics, neighbours} ->
          {nl, statistics, neighbours, get_stat(SM, st_neighbours) };
        {statistics, data} when Protocol#pr_conf.ack ->
          {nl, statistics, data, get_stat_data(SM, st_data) };
        protocols ->
          {nl, Command, Req};
        {protocol, Name} ->
          {nl, protocol, get_protocol_info(SM, Name)};
        neighbours ->
          {nl, neighbours, neighbours_to_bin(SM)};
        routing ->
          {nl, routing, routing_to_bin(SM)};
        state ->
          {nl, state, Req};
        states ->
          L = list_to_binary(Req),
          {nl, states, L};
        address ->
          L = integer_to_binary(Req),
          {nl, address, L};
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
  share:put(SM, pr_state, Msg),
  add_item_to_queue(SM, pr_states, Msg, 50),
  add_item_to_queue(SM, last_states, list_to_binary([atom_to_binary(SM#sm.state,utf8), "(", atom_to_binary(SM#sm.event,utf8), ")\n"]), 50).

get_protocol_info(SM, Name) ->
  BName = atom_to_binary(Name, utf8),
  Conf  = share:get(SM, protocol_config, Name),
  list_to_binary(["\nName\t\t: ", BName,"\n", ?PROTOCOL_SPEC(Conf)]).

get_stat_data(SM, Qname) ->
  lists:map(fun({ {Role, Payload}, Time, Length, State, TS, Dst, Count_hops}) ->
                TRole = if Role =:= source -> "Source"; true -> "Relay" end,
                BTime = convert_type_to_bin(Time),
                list_to_binary(
                  ["\n ", TRole, " Data:",Payload, " Len:", convert_type_to_bin(Length),
                   " Duration:", BTime, " State:", State, " Total:", integer_to_binary(TS),
                   " Dst:", integer_to_binary(Dst), " Hops:", integer_to_binary(Count_hops)])
            end, queue:to_list(share:get(SM, Qname))).

get_stat(SM, Qname) ->
  lists:map(fun({ {Role, Val}, Time, Count, TS}) ->
                TRole = if Role =:= source -> "Source"; true -> "Relay" end,
                BTime = convert_type_to_bin(Time),
                Specific = case Qname of
                             paths -> ["Path:", convert_type_to_bin(Val), " Time:", BTime];
                             st_neighbours -> ["Neighbour:", convert_type_to_bin(Val)]
                           end,
                list_to_binary(
                  ["\n ", TRole, " ", Specific, 
                   " Count:", integer_to_binary(Count),
                   " Total:", integer_to_binary(TS)])
               end, queue:to_list(share:get(SM, Qname))).

save_stat_total(SM, Role)->
  case Role of
    source ->
      S_total_sent = share:get(SM, s_total_sent),
      share:put(SM, s_total_sent, S_total_sent + 1);
    relay ->
      R_total_sent = share:get(SM, r_total_sent),
      share:put(SM, r_total_sent, R_total_sent + 1);
    _ ->
      nothing
  end.

save_stat_time(SM, {ISrc, IDst}, Role)->
  case Role of
    source ->
      share:put(SM, s_send_time, {{ISrc, IDst}, erlang:monotonic_time(micro_seconds)});
    relay ->
      share:put(SM, r_send_time, {{ISrc, IDst}, erlang:monotonic_time(micro_seconds)});
    _ ->
      nothing
  end.

get_stats_time(SM, Real_src, Real_dst) ->
  Local_address = share:get(SM, local_address),
  if Local_address =:= Real_src;
     Local_address =:= Real_dst ->
     ST_send_time = share:get(SM, s_send_time),
     {Addrs, S_send_time} = parse_tuple(ST_send_time),
     S_total_sent = share:get(SM, s_total_sent),
     {S_send_time, source, S_total_sent, Addrs};
  true ->
     RT_send_time = share:get(SM, r_send_time),
     {Addrs, R_send_time} = parse_tuple(RT_send_time),
     R_total_sent = share:get(SM, r_total_sent),
     {R_send_time, relay, R_total_sent, Addrs}
  end.

parse_tuple(Tuple) ->
  case Tuple of
    nothing ->
      {nothing, nothing};
    _ ->
      Tuple
  end.

path_to_bin(SM, Path) ->
  CheckDblPath = remove_dubl_in_path(lists:reverse(Path)),
  list_to_binary(lists:join(",",[integer_to_binary(addr_mac2nl(SM, X)) || X <- CheckDblPath])).

analyse(SM, QName, Path, {Real_src, Real_dst}) ->
  {Time, Role, TSC, _Addrs} = get_stats_time(SM, Real_src, Real_dst),

  BPath =
  case QName of
    paths when Path =:= nothing ->
      <<>>;
    paths ->
      save_stat_total(SM, Role),
      path_to_bin(SM, Path);
    st_neighbours ->
      Path;
    st_data ->
      Path
  end,

  Tuple = case {QName, Time} of
            {st_data, nothing} ->
              {P, Dst, Count_hops, St} = BPath,
              { {Role, P}, 0.0, byte_size(P), St, TSC, Dst, Count_hops};
            {st_data, _} ->
              {P, Dst, Count_hops, St} = BPath,
              TDiff = erlang:monotonic_time(micro_seconds) - Time,
              CTDiff = convert_t(TDiff, {us, s}),
              { {Role, P}, CTDiff, byte_size(P), St, TSC, Dst, Count_hops};
            {_, nothing} ->
              { {Role, BPath}, 0.0, 1, TSC};
            _ ->
              TDiff = erlang:monotonic_time(micro_seconds) - Time,
              CTDiff = convert_t(TDiff, {us, s}),
              { {Role, BPath}, CTDiff, 1, TSC}
          end,
  add_item_to_queue_nd(SM, QName, Tuple, 300).

queue_limited_push(Q, Item, Max) ->
  case queue:len(Q) of
    Len when Len >= Max ->
      queue:in(Item, queue:drop(Q));
    _ ->
      queue:in(Item, Q)
  end.

add_item_to_queue_nd(SM, st_data, Item, Max) ->
  Q = share:get(SM, st_data),
  share:put(SM, st_data, queue_limited_push(Q, Item, Max));
add_item_to_queue_nd(SM, Qname, {NKey, NT, _, NewTS} = Item, Max) ->
  Q = share:get(SM, Qname),
  LQ = queue:to_list(Q),
  Matched = fun({Key,0.0,_,_}) when Key == NKey, NT == 0.0 -> true;
               ({Key,_,_,_}) when Key == NKey, NT > 0 -> true;
               (_) -> false
            end,
  QQ = 
    case lists:any(Matched, LQ) of
      true ->
        queue:from_list(
          lists:map(fun({Key, 0.0, Count, _TS}) when Key == NKey, NT == 0.0 ->
                        {Key, 0.0, Count + 1, NewTS };
                       ({Key, T, Count, _TS}) when Key == NKey, NT > 0 ->
                        {Key, (T + NT) / 2, Count + 1, NewTS};
                       (Other) -> Other
                    end, LQ));
      false ->
        queue_limited_push(Q, Item, Max)
    end,
  share:put(SM, Qname, QQ).
