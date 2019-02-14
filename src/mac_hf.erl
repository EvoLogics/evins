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
-module(mac_hf). % network and mac layer helper functions

-import(lists, [filter/2, foldl/3, map/2, member/2]).

-include("fsm.hrl").
-include("nl.hrl").

-export([convert_type_to_bin/1, convert_t/2, count_flag_bits/1]).
-export([event_params/3, num2flag/2, rand_float/2, get_dst_addr/1]).
-export([extract_payload_mac_flag/1]).
-export([send_helpers/4, send_cts/6, send_mac/4]).
-export([bin_to_num/1, create_payload_mac_flag/3]).
%%--------------------------------------------------- Convert types functions -----------------------------------------------
event_params(SM, Term, Event) ->
  if SM#sm.event_params =:= [] ->
       [Term, SM];
     true ->
       EventP = hd(tuple_to_list(SM#sm.event_params)),
       if EventP =:= Event -> [SM#sm.event_params, SM#sm{event_params = []}];
          true -> [Term, SM]
       end
  end.

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
  if Rem =:= 0 ->
    F / 2;
    true -> F / 2 - 0.5
  end,
  count_flag_bits_helper(round(D), C + 1).

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

num2flag(Num, Layer) when is_integer(Num)->
  ?NUM2FLAG(Num, Layer);
num2flag(Num, Layer) when is_binary(Num)->
  ?NUM2FLAG(binary_to_integer(Num), Layer).
%%--------------------------------------------------- Deprecated -----------------------------------------------
send_cts(SM, Interface, MACP, Timestamp, USEC, Dur) ->
  {at, PID, _, IDst, _, _} = MACP,
  Tuple = {at, PID,"*SENDIMS", IDst, Timestamp + USEC, convert_type_to_bin(Dur + USEC)},
  send_mac(SM, Interface, cts, Tuple).

convert_t(Val, T) ->
  case T of
    {us, s} -> Val / 1000000;
    {s, us} -> Val * 1000000
  end.

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
send_mac(SM, _Interface, Flag, MACP) ->
  AT = mac2at(SM, Flag, MACP),
  ?INFO(?ID, ">>>>>>>>>>>>>>>> send_mac ~p~n", [AT]),
  fsm:send_at_command(SM, AT).

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
get_dst_addr({nl, send, IDst,_}) -> IDst;
get_dst_addr({at, _, _, IDst, _, _}) -> IDst.

