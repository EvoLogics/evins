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
-export([init_dets/1]).
%% handle events
-export([event_params/3, clear_spec_timeout/2, get_params_spec_timeout/2]).
%% Math functions
-export([rand_float/2, lerp/3, deleteQKey/3]).
%% Addressing functions
-export([init_nl_addrs/1, get_dst_addr/1, set_dst_addr/2]).
-export([addr_nl2mac/2, addr_mac2nl/2, get_routing_addr/3, find_in_routing_table/2, num2flag/2, flag2num/1]).
%% NL header functions
-export([parse_path_data/2]).
%% Extract functions
-export([extract_payload_mac_flag/1, extract_payload_nl_flag/1, create_ack/1, extract_ack/2]).
%% Extract/create header functions
-export([extract_path_neighbours/2]).
%% Send NL functions
-export([send_nl_command/4, send_ack/3, send_path/2, send_helpers/4, send_cts/6, send_mac/4, fill_msg/2]).
%% Parse NL functions
-export([prepare_send_path/3, parse_path/3, save_path/3]).
%% Process NL functions
-export([add_neighbours/5, process_pkg_id/3, process_relay/2, process_path_life/2, routing_to_list/1, check_dubl_in_path/2]).
%% RTT functions
-export([getRTT/2, smooth_RTT/3, queue_limited_push/3]).
%% command functions
-export([process_command/3, save_stat_time/3, update_states_list/1, save_stat_total/2]).
%% Only MAC functions
-export([process_rcv_payload/2, process_send_payload/2, process_retransmit/3]).
%% Other functions
-export([bin_to_num/1, increase_pkgid/3, add_item_to_queue/4, analyse/4]).
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

get_params_spec_timeout(SM, Spec) ->
  lists:filtermap(
   fun({E, _TRef}) ->
     case E of
       {Spec, P} -> {true, P};
       _  -> false
     end
  end, SM#sm.timeouts).
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
  AT = mac2at(SM, Flag, MACP),
  ?INFO(?ID, ">>>>>>>>>>>>>>>> send_mac ~p~n", [AT]),
  fsm:send_at_command(SM, AT).

send_ack(SM,  {send_ack, {_, [Packet_id, _, _PAdditional]}, {nl, recv, Real_dst, Real_src, _}}, Count_hops) ->
  BCount_hops = create_ack(Count_hops),
  send_nl_command(SM, at, {ack, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BCount_hops}).

send_path(SM, {send_path, {Flag, [Packet_id, _, _PAdditional]}, {nl, recv, Real_dst, Real_src, Payload}}) ->
  MAC_addr  = convert_la(SM, integer, mac),
  case share:get(SM, current_neighbours) of
    nothing -> error;
    Neighbours ->
      BCN = neighbours_to_list(SM,Neighbours, mac),
      [SMN, BMsg] =
      case Flag of
        neighbours ->
          [SM, fill_msg(path_neighbours, {BCN, [MAC_addr]})];
        Flag ->
          [SMNTmp, ExtrListPath] =
          case Flag of
            path_addit ->
              [ListPath, [DIRssi, DIIntegr]] = extract_path_addit(SM, Payload),
              NPathTuple = {[DIRssi, DIIntegr], ListPath},
              parse_path(SM,  NPathTuple, {Real_src, Real_dst});
            path     ->
              [ListNeighbours, ListPath] = extract_path_neighbours(SM, Payload),
              NPathTuple = {ListNeighbours, ListPath},
              parse_path(SM, NPathTuple, {Real_src, Real_dst})
          end,

          CheckDblPath = check_dubl_in_path(ExtrListPath, MAC_addr),
          RCheckDblPath = lists:reverse(CheckDblPath),

          % FIXME: below lost updated SM value
          SM1 = process_and_update_path(SMNTmp, {Real_src, Real_dst, RCheckDblPath} ),
          analyse(SMNTmp, paths, RCheckDblPath, {Real_src, Real_dst}),
          [SM1, fill_msg(path_neighbours, {BCN, RCheckDblPath})]
      end,
      send_nl_command(SMN, at, {path, [Packet_id, Real_src, []]}, {nl, send, Real_dst, BMsg})
  end.

send_nl_command(SM, Interface, {Flag, [IPacket_id, Real_src, _PAdditional]}, NL) ->
  Real_dst = get_dst_addr(NL),
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)),

  if Real_dst =:= wrong_format -> error;
     true ->
       Route_addr = get_routing_addr(SM, Flag, addr_nl2mac(SM, Real_dst) ),

       [MAC_addr, MAC_real_src, MAC_real_dst] = addr_nl2mac(SM, [Route_addr, Real_src, Real_dst]),
       if(Route_addr =:= no_routing_table) ->
        ?ERROR(?ID, "~s: Wrong Route_addr:~p, check config file ~n", [?MODULE, Route_addr]);
        true -> nothing
       end,

       ?TRACE(?ID, "Route_addr ~p, MAC_addrm ~p, MAC_real_src ~p, MAC_real_dst ~p~n", [Route_addr, MAC_addr, MAC_real_src, MAC_real_dst]),
       if ((MAC_addr =:= error) or (MAC_real_src =:= error) or (MAC_real_dst =:= error)
           or ((MAC_real_dst =:= ?ADDRESS_MAX) and Protocol#pr_conf.br_na)) ->
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
                                {last_nl_sent, {send, {Flag, [IPacket_id, Real_src, []]}, NL}},
                                {ack_last_nl_sent, {IPacket_id, Real_src, Real_dst}}]),

                 SM1 = fsm:cast(SM, Interface, {send, AT}),
                 %!!!!
                 %fsm:cast(SM, nl, {send, AT}),
                 fill_dets(SM, IPacket_id, MAC_real_src, MAC_real_dst),
                 fsm:set_event(SM1, eps)
            end
       end
  end.

mac2at(SM, Flag, Tuple) when is_tuple(Tuple)->
  case Tuple of
    {at, PID, SENDFLAG, IDst, Data} ->
      NewData = create_payload_mac_flag(SM, Flag, Data),
      {at, PID, SENDFLAG, IDst, NewData};
    {at, PID, SENDFLAG, IDst, TFlag, Data} ->
      NewData = create_payload_mac_flag(SM, Flag, Data),
      {at, PID, SENDFLAG, IDst, TFlag, NewData};
    _ ->
      error
  end.

nl2at (SM, Tuple) when is_tuple(Tuple)->
  %Queue_ids = share:get(SM, queue_ids),
  PID = share:get(SM, pid),
  NLPPid = ?PROTOCOL_NL_PID(share:get(SM, nlp)),
  ?WARNING(?ID, ">>>>>>>> NLPPid: ~p~n", [NLPPid]),
  case Tuple of
    {Flag, BPacket_id, MAC_real_src, MAC_real_dst, {nl, send, IDst, Data}}  when byte_size(Data) < ?MAX_IM_LEN ->
      %% TTL generated on NL layer is always 0, MAC layer inreases it, due to retransmissions
      NewData = create_payload_nl_flag(SM, NLPPid, Flag, BPacket_id, 0, MAC_real_src, MAC_real_dst, Data),
      {at, {pid,PID}, "*SENDIM", IDst, noack, NewData};
    {Flag, BPacket_id, MAC_real_src, MAC_real_dst, {nl, send, IDst, Data}} ->
      NewData = create_payload_nl_flag(SM, NLPPid, Flag, BPacket_id, 0, MAC_real_src, MAC_real_dst, Data),
      {at, {pid,PID}, "*SEND", IDst, NewData};
    _ ->
      error
  end.

%%------------------------- Extract functions ----------------------------------
create_payload_nl_flag(_SM, NLPPid, Flag, PkgID, TTL, Src, Dst, Data) ->
  % 6 bits NL_Protocol_PID
  % 3 bits Flag
  % 6 bits PkgID
  % 2 bits TTL
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 3)
  CBitsNLPid = count_flag_bits(?NL_PID_MAX),
  CBitsFlag = count_flag_bits(?FLAG_MAX),
  CBitsPkgID = count_flag_bits(?PKG_ID_MAX),
  CBitsTTL = count_flag_bits(?TTL),
  CBitsAddr = count_flag_bits(?ADDRESS_MAX),

  BPid = <<NLPPid:CBitsNLPid>>,

  FlagNum = ?FLAG2NUM(Flag),
  BFlag = <<FlagNum:CBitsFlag>>,

  BPkgID = <<PkgID:CBitsPkgID>>,
  BTTL = <<TTL:CBitsTTL>>,
  BSrc = <<Src:CBitsAddr>>,
  BDst = <<Dst:CBitsAddr>>,

  TmpData = <<BPid/bitstring, BFlag/bitstring, BPkgID/bitstring, BTTL/bitstring, BSrc/bitstring, BDst/bitstring, Data/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),

  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<BPid/bitstring, BFlag/bitstring, BPkgID/bitstring, BTTL/bitstring, BSrc/bitstring, BDst/bitstring, 0:Add, Data/binary>>;
  true ->
    TmpData
  end.

create_payload_mac_flag(SM, Flag, Data) ->
  % 4 bits NL_MAC_PID
  % 3 bits Flag
  % rest bits reserved for later (+1)
  CBitsMACPid = count_flag_bits(?MAC_PID_MAX),
  CBitsFlag = count_flag_bits(?FLAG_MAX),

  CurrentPid = ?PROTOCOL_MAC_PID(share:get(SM, macp)),
  BPid = <<CurrentPid:CBitsMACPid>>,
  FlagNum = ?FLAG2NUM(Flag),
  
  BFlag = <<FlagNum:CBitsFlag>>,
  TmpData = <<BPid/bitstring, BFlag/bitstring, Data/binary>>,

  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<BPid/bitstring, BFlag/bitstring, 0:Add, Data/binary>>;
  true ->
    TmpData
  end.

extract_payload_nl_flag(Payl) ->
  % 6 bits NL_Protocol_PID
  % 3 bits Flag
  % 6 bits PkgID
  % 2 bits TTL
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 3)
  CBitsNLPid = count_flag_bits(?NL_PID_MAX),
  CBitsFlag = count_flag_bits(?FLAG_MAX),
  CBitsPkgID = count_flag_bits(?PKG_ID_MAX),
  CBitsTTL = count_flag_bits(?TTL),
  CBitsAddr = count_flag_bits(?ADDRESS_MAX),

  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  <<BNLPid:CBitsNLPid, BFlag:CBitsFlag, BPkgID:CBitsPkgID, BTTL:CBitsTTL, BSrc:CBitsAddr, BDst:CBitsAddr, Rest/bitstring>> = Payl,
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [BNLPid, BFlag, BPkgID, BTTL, BSrc, BDst, Data];
  true ->
    [BNLPid, BFlag, BPkgID, BTTL, BSrc, BDst, Rest]
  end.

extract_payload_mac_flag(Payl) ->
  % 5 bits NL_MAC_PID
  % 3 bits Flag

  CBitsMACPid = count_flag_bits(?MAC_PID_MAX),
  CBitsFlag = count_flag_bits(?FLAG_MAX),
  
  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  if Data_bin =:= false ->
    <<BPid:CBitsMACPid, BFlag:CBitsFlag, Rest/bitstring>> = Payl,
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [BPid, BFlag, Data, round((CBitsMACPid + CBitsFlag) / 8)];
  true ->
    <<BPid:CBitsMACPid, BFlag:CBitsFlag, Data/binary>> = Payl,
    [BPid, BFlag, Data, round( (CBitsMACPid + CBitsFlag) / 8)]
  end.

check_dubl_in_path(Path, MAC_addr) ->
  NP = remove_dubl_in_path(Path),
  case lists:member(MAC_addr, NP) of
    true  -> NP;
    false -> [MAC_addr | NP]
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
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
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
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
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
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  BCountHops = <<CountHops:CBitsLenPath>>,
  Data_bin = is_binary(BCountHops) =:= false or ( (bit_size(BCountHops) rem 8) =/= 0),
  if Data_bin =:= false ->
     Add = (8 - bit_size(BCountHops) rem 8) rem 8,
     <<BCountHops/bitstring, 0:Add>>;
   true ->
     BCountHops
   end.

extract_ack(SM, Payl) ->
   CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
   <<CountHops:CBitsLenPath, _Rest/bitstring>> = Payl,
   ?TRACE(?ID, "extract_ack CountHops ~p ~n", [CountHops]),
   CountHops.

%%--------------- neighbours -------------------
%   3b        6b                LenNeighbours * 6b    REST till / 8
%   TYPEMSG   LenNeighbours     Neighbours            ADD
create_neighbours(Neighbours) ->
  LenNeighbours = length(Neighbours),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?MAX_LEN_NEIGBOURS),
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

create_path_neighbours(Neighbours, Path) ->
  LenNeighbours = length(Neighbours),
  LenPath = length(Path),
  CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
  CBitsLenNeigbours = count_flag_bits(?MAX_LEN_NEIGBOURS),
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  TypeNum = ?TYPEMSG2NUM(path_neighbours),

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

extract_path_neighbours(SM, Payl) ->
  try
    CBitsTypeMsg = count_flag_bits(?TYPE_MSG_MAX),
    CBitsLenNeigbours = count_flag_bits(?MAX_LEN_NEIGBOURS),
    CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),

    <<BType:CBitsTypeMsg, NeighboursRest/bitstring>> = Payl,

    path_neighbours = ?NUM2TYPEMSG(BType),

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
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?LEN_ADD),
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
  CBitsLenPath = count_flag_bits(?MAX_LEN_PATH),
  CBitsLenAdd = count_flag_bits(?LEN_ADD),
  CBitsAdd = count_flag_bits(?ADD_INFO_MAX),

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
  NProtocol = share:get(SM, nlp),
  Protocol = share:get(SM, protocol_config, NProtocol),
  case required_routing(Flag, Protocol, NProtocol) of
    true  ->
      AddrDst = find_in_routing_table(share:get(SM, routing_table), AddrSrc),
      Static = (NProtocol == staticr) or (NProtocol == staticrack),
      StaticFlags = (Flag == dst_reached) or (Flag == ack),

      case NProtocol of
        _ when  Static,
                AddrDst == ?ADDRESS_MAX,
                StaticFlags ->
          AddrDst;
        _ when  Static,
                AddrDst == ?ADDRESS_MAX,
                AddrSrc =/= ?ADDRESS_MAX ->
          error;
        _ ->
          AddrDst
      end;
    false -> ?ADDRESS_MAX
  end.

% TODO: check
find_in_routing_table(?ADDRESS_MAX, _) -> ?ADDRESS_MAX;
find_in_routing_table(_, ?ADDRESS_MAX) -> ?ADDRESS_MAX;
find_in_routing_table([], _) -> no_routing_table;
find_in_routing_table(Routing_table, AddrSrc) ->
  Res =
  lists:filtermap(fun(X) ->
    case X  of
      {AddrSrc, To} -> {true, To};
      _ -> false
  end end, Routing_table),

  Addr =
  case Res of
    [] ->
      lists:filtermap(fun(X) ->
        if is_tuple(X) == false -> {true, X};
          true -> false
        end end, Routing_table);
    To -> To
  end,

  case Addr of
    [] -> ?ADDRESS_MAX;
    [AddrTo] -> AddrTo
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
fill_msg(path_neighbours, {Neighbours, Path}) ->
  create_path_neighbours(Neighbours, Path);
fill_msg(path_data, {TransmitLen, Data, Path}) ->
  create_path_data(Path, TransmitLen, Data);
fill_msg(path_addit, {Path, Additional}) ->
  create_path_addit(Path, Additional).

prepare_send_path(SM, [_ , _, PAdditional], {nl, recv, Real_dst, Real_src, Payload}) ->
  MAC_addr = convert_la(SM, integer, mac),
  {nl, send, IDst, Data} = share:get(SM, current_pkg),
  CurrentLen = byte_size(Data),
  
  [ListNeighbours, ListPath] = extract_path_neighbours(SM, Payload),
  NPathTuple = {ListNeighbours, ListPath},
  [SM1, BPath] = parse_path(SM, NPathTuple, {Real_src, Real_dst}),
  NPath = [MAC_addr | BPath],

  case get_routing_addr(SM, path, Real_dst) of
    ?ADDRESS_MAX -> nothing;
    _ -> analyse(SM1, paths, NPath, {Real_src, Real_dst})
  end,

  PkgID = increase_pkgid(SM, Real_src, Real_dst),
  SDParams = {data, [PkgID, share:get(SM, local_address), PAdditional]},
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
  try
    Neighbours_channel = share:get(SM, neighbours_channel),
    SM1 = fsm:set_timeout(SM, {s, share:get(SM, neighbour_life)}, {neighbour_life, NLSrcAT}),
    Current_time = erlang:monotonic_time(milli_seconds) - share:get(SM, nl_start_time),
    analyse(SM1, st_neighbours, NLSrcAT, {RealSrc, Real_dst}),
    Add_neighbours =
    fun(Neighbours) ->
         case lists:member(NLSrcAT, Neighbours) of
           _ when Neighbours_channel == nothing ->
              share:put(SM1, neighbours_channel, [ {NLSrcAT, IRssi, IIntegrity, Current_time}]),
              [NLSrcAT];
           true ->
              El = {_, ETSrssi, ETSintegrity, _} = lists:keyfind(NLSrcAT, 1, Neighbours_channel),
              NewRssi = get_aver_value(IRssi, ETSrssi),
              NewIntegrity = get_aver_value(IIntegrity, ETSintegrity),
              Updated_neighbours_channel = lists:delete(El, Neighbours_channel),
              share:put(SM1, neighbours_channel, [ {NLSrcAT, NewRssi, NewIntegrity, Current_time} | Updated_neighbours_channel]),
              Neighbours;
           false ->
              share:put(SM1, neighbours_channel, [ {NLSrcAT, IRssi, IIntegrity, Current_time} | Neighbours_channel]),
              [NLSrcAT | Neighbours]
         end
      end,

    share:update_with(SM1, current_neighbours, Add_neighbours, [])
  catch error: Reason ->
    %% Got a message not for NL layer
    ?ERROR(?ID, "Error: neighbours_other_format, Reason: ~p~n", [Reason]),
    neighbours_other_format
  end.
%%-------------------------------------------------- Process NL functions -------------------------------------------
get_aver_value(0, Val2) ->
  round(Val2);
get_aver_value(Val1, Val2) ->
  round((Val1 + Val2) / 2).

process_relay(SM, Tuple = {send, Params, {nl, send, IDst, Payload}}) ->
  {Flag, [_, ISrc, PAdditional]} = Params,
  MAC_addr = convert_la(SM, integer, mac),
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)), 
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
          [ListNeighbours, ListPath] = extract_path_neighbours(SM, Payload),
          NPathTuple = {ListNeighbours, ListPath},
          %% save path and set path life
          [SMN, _] = parse_path(SM, NPathTuple, {ISrc, IDst}),
          %% check path, because of loopings (no dublicated addrs)
          Check_path = check_path(SM, ISrc, IDst, ListPath),
          case (lists:member(MAC_addr, ListNeighbours)) of
            true when ((ISrc =/= Local_address) and (Protocol#pr_conf.lo or Protocol#pr_conf.dbl) and Check_path) ->
              NewPayload = fill_msg(path_neighbours, {LNeighbours, ListPath}),
              [SMN, {send, Params, {nl, send, IDst, NewPayload}}];
            _ ->
              case (lists:member(MAC_addr, ListNeighbours) and not(lists:member(MAC_addr, ListPath))) of
                true  when (ISrc =/= Local_address) ->
                  DublListPath = check_dubl_in_path(ListPath, MAC_addr),
                  NewPayload = fill_msg(path_neighbours, {LNeighbours, DublListPath}),
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
  [SM, lists:reverse([?ADDRESS_MAX | Routing_table]) ];
process_route_table(SM, [H | T], NLFrom, Routing_table) ->
  SM1 = fsm:set_timeout(SM, {s, share:get(SM, path_life)}, {path_life, {H, NLFrom}}),
  process_route_table(SM1, T, NLFrom, [ {H, NLFrom} | Routing_table]).

process_path_life(SM, Tuple) ->
  share:update_with(SM, routing_table, fun(T) -> lists:delete(Tuple, T) end).

% FIXME: better to store protocol_config at env
save_path(SM, {Flag,_} = Params, Tuple) ->
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)),
  case Flag of
    data when Protocol#pr_conf.ry_only and Protocol#pr_conf.pf ->
      {nl,recv, Real_src, Real_dst, Payload} = Tuple,
      {_, _, Path} = parse_path_data(SM, Payload),
      analyse(SM, paths, Path, {Real_src, Real_dst});
    path_addit when Protocol#pr_conf.evo ->
      {nl,recv, _, _, Payload} = Tuple,
      [_, [DIRssi, DIIntegr]] = extract_path_addit(SM, Payload),
      El = { DIRssi, DIIntegr, {Params, Tuple} },
      share:update_with(SM, list_current_wvp, fun(L) -> L ++ [El] end);
    _ -> SM
  end.

update_route_table(SM, NRouting_table) ->
  ORouting_table = share:get(SM, routing_table),
  LRouting_table = if ORouting_table =:= ?ADDRESS_MAX -> [?ADDRESS_MAX]; true -> ORouting_table end,
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

% check if same package was received from other src dst,
process_pkg_id(SM, TTL, Tuple) ->
  Queue_ids = share:get(SM, queue_ids),
  Pkg_life = share:get(SM, pkg_life),
  QueueLimit = 30,
  [SMN, StoredTTL, NQueue_ids] = searchQKey(SM, Queue_ids, Tuple, queue:new(), nothing, Pkg_life, QueueLimit),
  % if StoredTTL == nothing, it is a new package and does not exist in the queue
  ?INFO(?ID, "process_pkg_id: TTL ~p StoredTTL ~p ~n", [TTL, StoredTTL]),
  case StoredTTL of
    nothing ->
      NewQ = queue_limited_push(NQueue_ids, Tuple, QueueLimit),
      share:put(SMN, queue_ids, NewQ),
      [SMN, not_processed];
    _ when TTL > StoredTTL ->
      share:put(SMN, queue_ids, NQueue_ids),
      [SMN, not_processed];
    _  ->
      share:put(SMN, queue_ids, NQueue_ids),
      [SMN, processed]
  end.

deleteQKey({[],[]}, _Tuple, NQ) ->
  NQ;
deleteQKey(Q, Tuple, NQ) ->
  {{value, CTuple}, Q1} = queue:out(Q),
  case CTuple of
    Tuple ->
      deleteQKey(Q1, Tuple, NQ);
    _ ->
      deleteQKey(Q1, Tuple, queue:in(CTuple, NQ))
  end.

searchQKey(SM, {[],[]}, _Tuple, NQ, TTL, _Pkg_life, _) ->
  [SM, TTL, NQ];
searchQKey(SM, Q, {Flag, CurrentTTL, ID, S, D, Data} = Tuple, NQ, TTL, Pkg_life, QueueLimit) ->
  { {value, CTuple}, Q1 } = queue:out(Q),
  ?INFO(?ID, "searchQKey: Tuple in Q ~p Tuple to find ~p TTL ~p Pkg_life ~p~n", [CTuple, Tuple, TTL, Pkg_life]),
  case CTuple of
    {Flag, CurrentTTL, ID, S, D, Data} ->
      LimQ = queue_limited_push(NQ, CTuple, QueueLimit),
      searchQKey(SM, Q1, Tuple, LimQ, CurrentTTL, Pkg_life, QueueLimit);
    {Flag, StoredTTL, ID, S, D, Data} when StoredTTL > CurrentTTL ->
      searchQKey(SM, Q1, Tuple, NQ, StoredTTL, Pkg_life, QueueLimit);
    {Flag, StoredTTL, ID, S, D, Data} when CurrentTTL > StoredTTL, Pkg_life =/= nothing ->
      SMN = fsm:set_timeout(SM, {s, Pkg_life}, {drop_pkg, Tuple}),
      LimQ = queue_limited_push(NQ, Tuple, QueueLimit),
      searchQKey(SMN, Q1, Tuple, LimQ, StoredTTL, Pkg_life, QueueLimit);
    {Flag, StoredTTL, ID, S, D, Data} when CurrentTTL > StoredTTL ->
      LimQ = queue_limited_push(NQ, Tuple, QueueLimit),
      searchQKey(SM, Q1, Tuple, LimQ, StoredTTL, Pkg_life, QueueLimit);
    _ ->
      LimQ = queue_limited_push(NQ, CTuple, QueueLimit),
      searchQKey(SM, Q1, Tuple, LimQ, TTL, Pkg_life, QueueLimit)
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
% sequence_more_recent(_, nothing, _) ->
%   false;
% sequence_more_recent(S1, S2, Max) ->
%   if ((( S1 >= S2 ) and ( S1 - S2 =< Max / 2 )) or (( S2 >= S1 ) and ( S2 - S1  > Max / 2 ))) -> false;
%     true -> true
%   end.

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

increase_pkgid(SM, MACSrc, MACDst) ->
  Max_pkg_id = share:get(SM, max_pkg_id),
  Src = addr_mac2nl(SM, MACSrc),
  Dst = addr_mac2nl(SM, MACDst),
  PkgID = case share:get(SM, {packet_id, Src, Dst}) of
            nothing -> 0;
            Prev_id when Prev_id >= Max_pkg_id -> 0;
            (Prev_id) -> Prev_id + 1
          end,
  
  ?TRACE(?ID, "Increase Pkg, Current Pkg id ~p~n", [PkgID]),
  share:put(SM, {packet_id, Src, Dst}, PkgID),
  ?TRACE(?ID, "increase_pkgid LA ~p:     ~p~n", [share:get(SM, local_address), share:get(SM, {packet_id, Src, Dst})]),

  PkgID.

init_dets(SM) ->
  LA  = share:get(SM, local_address),
  Ref = SM#sm.dets_share,
  NL_protocol = share:get(SM, nlp),
  
  case B = dets:lookup(Ref, NL_protocol) of
    [{NL_protocol, ListIds}] ->
      [ share:put(SM, {packet_id, S, D}, ID) || {ID, S, D} <- ListIds];
    _ ->
      nothing
  end,

  ?TRACE(?ID,"init_dets LA ~p:   ~p~n", [share:get(SM, local_address), B]),
  ?INFO(?ID, "Init dets LA ~p ~p~n", [LA, B]),
  SM#sm{dets_share = Ref}.

fill_dets(SM, Packet_id, Src, Dst) ->
  LA  = share:get(SM, local_address),
  Ref = SM#sm.dets_share,
  NL_protocol = share:get(SM, nlp),

  case dets:lookup(Ref, NL_protocol) of
    [] ->
      dets:insert(Ref, {NL_protocol, [{Packet_id, Src, Dst}]});
    [{NL_protocol, ListIds}] ->
      Member = lists:filtermap(fun({ID, S, D}) when S == Src, D == Dst ->
                                 {true, ID};
                                (_S) -> false
                               end, ListIds),
      LIds = 
      case Member of
        [] -> [{Packet_id, Src, Dst} | ListIds];
        _  -> ListIds
      end,

      NewListIds = lists:map(fun({_, S, D}) when S == Src, D == Dst -> {Packet_id, S, D}; (T) -> T end, LIds),
      [ share:put(SM, {packet_id, S, D}, ID) || {ID, S, D} <- NewListIds],
      dets:insert(Ref, {NL_protocol, NewListIds});
    _ -> nothing
  end,

  Ref1 = SM#sm.dets_share,
  B = dets:lookup(Ref1, NL_protocol),

  ?INFO(?ID, "Fill_dets LA ~p ~p~n", [LA, B] ),
  ?TRACE(?ID, "fill_dets LA ~p: ~p~n", [share:get(SM, local_address), B]),

  SM#sm{dets_share = Ref1}.

neighbours_to_list(SM,Neigbours, mac) ->
  [addr_nl2mac(SM,X) || X <- Neigbours];
neighbours_to_list(_,Neigbours, nl) ->
  Neigbours.

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
process_rcv_payload(SM, <<"t">>) ->
  SM;
process_rcv_payload(SM, RcvPayload) ->
  % data stored to retransmit
  StoredRetransmit = get_params_spec_timeout(SM, retransmit),
  case StoredRetransmit of
    [] ->
      SM;
    _ ->
      [{at, _PID, _, _, _, StoredRetransmitPayload}] = StoredRetransmit,
      [_BPid, BRetrFlag, RetrPkgID, RetrTTL, RetrSrc, RetrDst, _RetrData] = extract_payload_nl_flag(StoredRetransmitPayload),
      % data received, has to be processed to clear retransmit
      [_BPid, BRecvFlag, RecvPkgID, RecvTTL, RecvSrc, RecvDst, _RecvData] = extract_payload_nl_flag(RcvPayload),

      RetrFlag = num2flag(BRetrFlag, nl),
      RecvFlag = num2flag(BRecvFlag, nl),

      ?TRACE(?ID, "<<<<<<<<<<<<<<<<<<< LA ~p    Flag ~p PkgID ~p RetrTTL ~p Dst ~p Src ~p~n",
              [share:get(SM, local_address), RetrFlag, RetrPkgID, RetrTTL, RetrSrc, RetrDst]),

      ?TRACE(?ID, ">>>>>>>>>>>>>>>>>>> LA ~p    Flag ~p PkgID ~p RetrTTL ~p Dst ~p Src ~p~n",
              [share:get(SM, local_address), RecvFlag, RecvPkgID, RecvTTL, RecvSrc, RecvDst]),

      Pkg_id = sequence_more_recent(RetrPkgID, RecvPkgID, ?PKG_ID_MAX),
      case RetrFlag of
        _ when RecvFlag == dst_reached ->
          clear_spec_timeout(SM, retransmit);
        Flag when Flag =/= dst_reached,
                  RecvFlag == Flag, Pkg_id == new, RetrSrc == RecvSrc, RetrDst == RecvDst ->
          clear_spec_timeout(SM, retransmit);
        Flag when Flag =/= dst_reached, Flag =/= ack, Flag =/= path, RecvFlag == ack, RetrSrc == RecvDst, RetrDst == RecvSrc;
                  Flag =/= dst_reached, Flag =/= ack, Flag =/= path, RecvFlag == dst_reached;
                  Flag =/= dst_reached, Flag =/= ack, Flag =/= path, RecvFlag == path, RetrSrc == RecvDst, RetrDst == RecvSrc ->
          clear_spec_timeout(SM, retransmit);
        dst_reached ->
          clear_spec_timeout(SM, retransmit);
        _ ->
          SM
      end
  end.

sequence_more_recent(S1, S2, Max) ->
  if ( (S1 == S2) or (( S1 >= S2 ) and ( S1 - S2 =< Max / 2 )) or (( S2 >= S1 ) and ( S2 - S1  > Max / 2 ))) -> new;
    true -> old
  end.

process_send_payload(SM, {at, _PID, _, _, _, <<"t">>}) ->
  SM;
process_send_payload(SM, {at, PID, P1, P2, P3, Payload}) ->
  SM1 = clear_spec_timeout(SM, retransmit),
  [BPid, Flag, PkgID, TTL, Src, Dst, Data] = extract_payload_nl_flag(Payload),
  Tuple = {Flag, TTL, PkgID, Src, Dst, Data},
  Ttl_table = share:get(SM, ttl_table),
  NewPayload = check_TTL(SM, Ttl_table, BPid, Tuple, Payload),
  NewMsg = {at, PID, P1, P2, P3, NewPayload},
  Tmo_retransmit = rand_float(SM1, tmo_retransmit),
  ?INFO(?ID, "process_send_payload ~p NewPayload ~p ~n", [num2flag(Flag, nl), NewPayload]),
  case num2flag(Flag, nl) of
    dst_reached when TTL == 1, NewPayload =/= nothing->
      fsm:set_timeout(SM1, {ms, Tmo_retransmit}, {retransmit, NewMsg});
    dst_reached ->
      SM1;
    _ when NewPayload =/= nothing ->
      fsm:set_timeout(SM1, {ms, Tmo_retransmit}, {retransmit, NewMsg});
    _ ->
      SM1
  end.

check_TTL(SM, nothing, _BPid, Tuple, Msg) ->
  Q = queue:new(),
  share:put(SM, ttl_table, queue:in(Tuple, Q)),
  Msg;
check_TTL(SM, Ttl_table, BPid, Tuple = {Flag, CurrentTTL, PkgID, Src, Dst, Data}, Msg) ->
  QueueLimit = 30,
  [_SMN, StoredTTL, NTtl_table] = searchQKey(SM, Ttl_table, Tuple, queue:new(), nothing, nothing, QueueLimit),
  ?INFO(?ID, "Ttl_table ~p CurrentTTL ~p StoredTTL ~p ~n", [Ttl_table, CurrentTTL, StoredTTL]),
  case StoredTTL of
    nothing ->
      share:put(SM, ttl_table, queue:in(Tuple, Ttl_table)),
      Msg;
    _ when CurrentTTL == StoredTTL ->
      nothing;
    _ when CurrentTTL == 0, StoredTTL < ?TTL - 1->
      NTuple = {Flag, StoredTTL + 1, PkgID, Src, Dst, Data},
      [_, _, IncTuple] = searchQKey(SM, Ttl_table, NTuple, queue:new(), nothing, nothing, QueueLimit),
      share:put(SM, ttl_table, IncTuple),
      create_payload_nl_flag(SM, BPid, num2flag(Flag, nl), PkgID, StoredTTL + 1, Src, Dst, Data);
    _ when StoredTTL > CurrentTTL, StoredTTL < ?TTL - 1 ->
      NTuple = {Flag, StoredTTL, PkgID, Src, Dst, Data},
      [_, _, IncTuple] = searchQKey(SM, Ttl_table, NTuple, queue:new(), nothing, nothing, QueueLimit),
      share:put(SM, ttl_table, IncTuple),
      create_payload_nl_flag(SM, BPid, num2flag(Flag, nl), PkgID, StoredTTL, Src, Dst, Data);
    _ when CurrentTTL > StoredTTL, CurrentTTL < ?TTL - 1 ->
      share:put(SM, ttl_table, NTtl_table),
      Msg;
    _ ->
      nothing
  end.

process_retransmit(SM, nothing, _) ->
  [SM, {}];
process_retransmit(SM, Msg, Ev) ->
  Max_retransmit_count = share:get(SM, max_retransmit_count),
  {at, PID, Type, ATDst, FlagAck, Payload} = Msg,
  [BPid, Flag, PkgID, TTL, Src, Dst, Data] = extract_payload_nl_flag(Payload),
  ?TRACE(?ID, "Retransmit Tuple ~p Retransmit_count ~p ~n ", [Msg, TTL]),
  if TTL < Max_retransmit_count ->
      NewMsg = create_payload_nl_flag(SM, BPid, num2flag(Flag, nl), PkgID, increaseTTL(TTL), Src, Dst, Data),
      AT = {at, PID, Type, ATDst, FlagAck, NewMsg},
      SM1 = process_send_payload(SM, AT),
      if Ev == eps ->
        [SM1#sm{event = Ev}, AT];
      true ->
        [SM1#sm{event = Ev}, {Ev, AT}]
      end;
    true ->
      [SM, {}]
  end.

increaseTTL(CurrentTTL) ->
  if(CurrentTTL < ?TTL - 1) ->
      CurrentTTL + 1;
  true ->
    ?TTL
  end.
%%--------------------------------------------------  command functions -------------------------------------------
process_command(SM, Debug, Command) ->
  Protocol = share:get(SM, protocol_config, share:get(SM, nlp)),
  [Req, Asw] =
  case Command of
    protocols ->
      [?LIST_ALL_PROTOCOLS, protocols];
    {protocolinfo, _} ->
      [share:get(SM, nlp), protocol_info];
    {statistics, paths} when Protocol#pr_conf.pf ->
      Paths =
        lists:map(fun({{Role, Path}, Duration, Count, TS}) ->
                      {Role, Path, Duration, Count, TS}
                  end, queue:to_list(share:get(SM, paths))),
      [case Paths of []  -> empty; _ -> Paths end, paths];
    {statistics, paths} ->
      [error, paths];
    {statistics, neighbours} ->
      Neighbours =
        lists:map(fun({{Role, Address}, _Time, Count, TS}) ->
                      {Role, Address, Count, TS}
                  end, queue:to_list(share:get(SM, nothing, st_neighbours, empty))),
      [case Neighbours of []  -> empty; _ -> Neighbours end, neighbours];
    {statistics, data} when Protocol#pr_conf.ack ->
      Data =
        lists:map(fun({{Role, Payload}, Time, Length, State, TS, Dst, Hops}) ->
                      TRole = case Role of source -> source; _ -> relay end,
                      <<Hash:16, _/binary>> = crypto:hash(md5,Payload),
                      {TRole,Hash,Length,Time,State,TS,Dst,Hops}
                  end, queue:to_list(share:get(SM, nothing, st_data, empty))),
      [case Data of []  -> empty; _ -> Data end, data];
    {statistics, data} ->
      [error, data];
    {delete, neighbour, _} ->
      [share:get(SM, current_neighbours), neighbours];
    states ->
      Last_states = share:get(SM, last_states),
      [queue:to_list(Last_states), states];
    state ->
      States = {SM#sm.state, SM#sm.event},
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
    %% error ->
    %%   {nl, error};
    Req when Req =:= nothing; Req =:= []; Req =:= {[],[]} ->
      {nl, Asw, empty};
    _ ->
      case Command of
        {statistics, paths} ->
          {nl, statistics, paths, Req};
        {statistics, neighbours} ->
          {nl, statistics, neighbours, Req};
        {statistics, data} ->
          {nl, statistics, data, Req};
        protocols ->
          {nl, Command, Req};
        {protocolinfo, Name} ->
          {nl, protocolinfo, Name, get_protocol_info(SM, Name)};
        neighbours ->
          {nl, neighbours, share:get(SM, neighbours_channel)};
        {delete, neighbour, Addr} ->
          LNeighbours = neighbours_to_list(SM, share:get(SM, current_neighbours), mac),
          delete_neighbour(SM, Addr, LNeighbours),
          {nl, neighbour, ok};
        routing ->
          {nl, routing, routing_to_list(SM)};
        state ->
          {nl, Command, Req};
        states ->
          {nl, Command, Req};
        address ->
          {nl, Command, Req};
        _ ->
          {nl, error}
      end
  end,
  if Debug =:= true ->
      ?TRACE(?ID, "Command answer ~p~n", [Answer]);
     true ->
      fsm:cast(SM, nl_impl, {send, Answer})
  end,
  SM.

update_neighbours_channel(_SM, _, []) ->
  nothing;
update_neighbours_channel(_SM, _, nothing) ->
  nothing;
update_neighbours_channel(SM, NLSrcAT, Neighbours_channel) ->
  El = lists:keyfind(NLSrcAT, 1, Neighbours_channel),
  Updated_neighbours_channel = 
  case El of
    false ->
      lists:delete(NLSrcAT, Neighbours_channel);
    _ ->
      lists:delete(El, Neighbours_channel)
  end,
  share:put(SM, neighbours_channel, Updated_neighbours_channel).

delete_neighbour(SM, Addr, LNeighbours) ->
  case lists:member(Addr, LNeighbours) of
    true ->
        % delete neighbour from the current neighbour list
        NewNeigbourList = lists:delete(Addr, LNeighbours),
        share:put(SM, current_neighbours, NewNeigbourList),

        Neighbours_channel = share:get(SM, neighbours_channel),
        update_neighbours_channel(SM, Addr, Neighbours_channel),

        %delete neighbour from the routing
        Routing_table = share:get(SM, routing_table),
        case Routing_table of
          ?ADDRESS_MAX -> nothing;
          _ ->
            NRouting_table = lists:filtermap(fun(X) ->
              case X of
                {_, Addr} -> false;
                Addr -> false;
                _ -> {true, X}
              end end, Routing_table),
            share:put(SM, routing_table, NRouting_table)
        end;
    false ->
      nothing
  end.

update_states_list(SM) ->
  [{_, Msg}] =
  lists:filter(fun({St, _Descr}) -> St =:= SM#sm.state end, ?STATE_DESCR),
  share:put(SM, pr_state, Msg),
  add_item_to_queue(SM, pr_states, Msg, 50),
  add_item_to_queue(SM, last_states, {SM#sm.state, SM#sm.event}, 50).

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

%% path_to_bin(SM, Path) ->
%%   CheckDblPath = remove_dubl_in_path(lists:reverse(Path)),
%%   list_to_binary(lists:join(",",[integer_to_binary(addr_mac2nl(SM, X)) || X <- CheckDblPath])).

analyse(SM, QName, Path, {Real_src, Real_dst}) ->
  {Time, Role, TSC, _Addrs} = get_stats_time(SM, Real_src, Real_dst),

  BPath =
  case QName of
    paths when Path =:= nothing ->
      [];
      %% <<>>;
    paths ->
      save_stat_total(SM, Role),
      remove_dubl_in_path(lists:reverse(Path));
      %% path_to_bin(SM, Path);
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
