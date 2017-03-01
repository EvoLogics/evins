%% Copyright (c) 2015, Oleksiy Kebkal <lesha@evologics.de>
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
-module(role_nl_mux).
-behaviour(role_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).
-record(config, {filter, mode, waitsync, request, telegram, eol, ext_networking, pid}).
-define(EOL_RECV, <<"\r\n">>).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  Cfg = #config{filter = nl, mode = data, waitsync = no, request = "", telegram = "", eol = "\n", ext_networking = no, pid = 0},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl(_,Cfg) -> Cfg.
     
to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

from_term(Term, Cfg) ->
  Tuple = from_term_helper(Term, Cfg),
  Bin = list_to_binary(Tuple),
  [Bin, Cfg].

from_term_helper(Tuple, _) when is_binary(Tuple) ->
  [Tuple];
from_term_helper(Tuple, Cfg) when is_tuple(Tuple) ->
  case Tuple of
    {answer, T} -> [nl_mac_hf:convert_to_binary(tuple_to_list(T)), ?EOL_RECV];
    _ ->
    [nl_mac_hf:convert_to_binary(tuple_to_list(Tuple)), Cfg#config.eol]
  end.

split(L, Cfg) ->
  case re:run(L, "\r\n") of
    {match, [{_, _}]} -> try_recv(L, Cfg);
    nomatch -> try_send(L, Cfg)
  end.


try_recv(L, Cfg) ->
  case re:run(L,"^(NL,ok|NL,busy|NL,error|NL,protocol,|NL,recv,|NL,neighbours,|NL,routing,|NL,delivered,|NL,failed,)(.*?)[\r\n]+(.*)", [dotall, {capture, [1, 2, 3], binary}]) of
    {match, [<<"NL,ok">>, _P, L1]}   -> [ {rcv_ll, {sync, L}} | split(L1, Cfg)];
    {match, [<<"NL,busy">>, _P, L1]}   -> [ {rcv_ll, {sync, L}} | split(L1, Cfg)];
    {match, [<<"NL,error">>, _P, L1]}   -> [ {rcv_ll, {sync, L}} | split(L1, Cfg)];
    {match, [<<"NL,protocol,">>, P, L1]}   -> [nl_protocol_extract(P, Cfg) | split(L1, Cfg)];
    {match, [<<"NL,routing,">>, _P, L1]}   -> [ {rcv_ll, {routing, L}} | split(L1, Cfg)];
    {match, [<<"NL,delivered,">>, _P, L1]} -> [ {rcv_ll, {delivered, L}} | split(L1, Cfg)];
    {match, [<<"NL,failed,">>, _P, L1]}    -> [ {rcv_ll, {failed, L}} | split(L1, Cfg)];
    {match, [<<"NL,recv,">>, P, L1]}       -> [ nl_recv_extract(P, L) | split(L1, Cfg)];
    {match, [<<"NL,neighbours,">>, P, L1]} -> [ nl_neighbours_extract(L, P, Cfg)| split(L1, Cfg)];
    nomatch ->  [{rcv_ll, L}]
  end.

try_send(L, Cfg) ->
  case L of
      <<"?\n">>  -> [ {rcv_ul, {help, L}} ];
      _ ->
      case re:run(L, "\n") of
        {match, [{_, _}]} ->
          case re:run(L,
            "^(NL,set,protocol,|NL,discovery,stop|NL,discovery|NL,get,discovery|NL,get,protocols,configured)(.*)",
            [dotall, {capture, [1, 2], binary}]) of

            {match, [<<"NL,set,protocol,">>, P]}  -> nl_set_protocol(P, Cfg);
            {match, [<<"NL,discovery">>, P]}  -> nl_discovery(P, Cfg);
            {match, [<<"NL,discovery,stop">>, _P]}  -> [{rcv_ul, stop, discovery}];
            {match, [<<"NL,get,discovery">>, P]}  -> nl_get_discovery(P, Cfg);
            {match, [<<"NL,get,protocols,configured">>, _P]}  -> [{rcv_ul, {get, configured, protocols}}];
            nomatch -> [{rcv_ul, L}]
          end;
        nomatch ->
          [{more, L}]
      end
  end.


nl_recv_extract(P, L) ->
   try
    {match, [_Len, _Src, Dst, Data]} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*)", [dotall, {capture, [1, 2, 3, 4], binary}]),
    {rcv_ll, {recv, nl_mac_hf:bin_to_num(Dst), Data, L}}
  catch error: _Reason -> {nl, error}
  end.

nl_get_discovery(P, _Cfg) ->
  try
    {match, [Param]} = re:run(P,",([^,]*)\n", [dotall, {capture, [1], binary}]),
    Flag =
    case Param of
      <<"period">> -> period;
      <<"time">> -> time
    end,

    [{rcv_ul, get, discovery, Flag}]
  catch error: _Reason -> [{nl, error}]
  end.

nl_discovery(P, _Cfg) ->
  try
    {match, [Discovery_perod, Time_discovery]} = re:run(P,",([^,]*),([^,]*)\n", [dotall, {capture, [1, 2], binary}]),
    [{rcv_ul, discovery, nl_mac_hf:bin_to_num(Discovery_perod), nl_mac_hf:bin_to_num(Time_discovery)}]
  catch error: _Reason -> [{nl, error}]
  end.

nl_set_protocol(P, _Cfg) ->
  try
    {match, [ProtocolID]} = re:run(P,"([^,]*)\n", [dotall, {capture, [1], binary}]),
    AProtocolID = binary_to_atom(ProtocolID, utf8),
    case lists:member(AProtocolID, ?LIST_ALL_PROTOCOLS) of
      true ->
        [{rcv_ul, {set, protocol, AProtocolID} }];
      false -> [{nl, error}]
    end
  catch error: _Reason -> [{nl, error}]
  end.


nl_neighbours_extract(L, NeighboursBin, _Cfg) ->
  try
    Neighbours = binary:split(NeighboursBin, [<<",">>],[global]),
    NL =
    lists:map(fun(X)->
      [H, Int, Rssi, Time] = binary:split(X, [<<":">>],[global]),
      {nl_mac_hf:bin_to_num(H),
      nl_mac_hf:bin_to_num(Int),
      nl_mac_hf:bin_to_num(Rssi),
      nl_mac_hf:bin_to_num(Time)}
    end, Neighbours),
    {rcv_ll, {neighbours, L, NL}}
  catch error: _Reason -> {rcv_ll, {neighbours, L, empty}}
  end.

nl_protocol_extract(P, _Cfg) ->
   try
    {match, [Name]} = re:run(P,"([^,]*)", [dotall, {capture, [1], binary}]),
    case lists:member(NPA = binary_to_atom(Name, utf8), ?LIST_ALL_PROTOCOLS) of
      true  -> {rcv_ll, {nl, protocol, NPA}};
      false -> {nl, error}
    end
  catch error: _Reason -> {nl, error}
  end.