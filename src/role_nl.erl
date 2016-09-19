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
-module(role_nl).
-behaviour(role_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

-record(config, {filter, mode, waitsync, request, telegram, eol, ext_networking, pid}).
-define(EOL_RECV, <<"\r">>).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  Cfg = #config{filter = nl, mode = data, waitsync = no, request = "", telegram = "", eol = "\n", ext_networking = no, pid = 0},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl(_, Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

from_term(Term, Cfg) ->
  Tuple = from_term_helper(Term, Cfg#config.pid, Cfg#config.filter),
  Bin = list_to_binary([Tuple, Cfg#config.eol]),
  [Bin, Cfg].

from_term_helper(Tuple,_,_) when is_tuple(Tuple) ->
  case Tuple of
    {nl, error} -> [nl_mac_hf:convert_to_binary(tuple_to_list(Tuple)), ?EOL_RECV];
    {async, T} when is_tuple(T) -> [nl_mac_hf:convert_to_binary(tuple_to_list(T)), ?EOL_RECV];
    {sync,  T} when is_tuple(T) -> [nl_mac_hf:convert_to_binary(tuple_to_list(T)), ?EOL_RECV];
    T -> [nl_mac_hf:convert_to_binary(tuple_to_list(T))]
  end.

split(L, Cfg) ->
  case re:run(L, "\r\n") of
    {match, [{_, _}]} -> try_recv(L, Cfg);
    nomatch -> try_send(L, Cfg)
  end.

try_recv(L, Cfg) ->
  case re:run(L,"(NL,recv,)(.*?)[\r\n]+(.*)", [dotall, {capture, [1, 2, 3], binary}]) of
    {match, [<<"NL,recv,">>, P, L1]} -> [nl_recv_extract(P, Cfg) | split(L1, Cfg)];
    nomatch ->
      case re:run(L,"^(NL,busy|NL,ok)[\r\n]+(.*)", [dotall, {capture, [1, 2], binary}]) of
        {match, [<<"NL,busy">>, L1]} -> [ {rcv_ll, {nl, busy}} | split(L1, Cfg)];
        {match, [<<"NL,ok">>, L1]} -> [ {rcv_ll, {nl, ok}} | split(L1, Cfg)];
        nomatch -> [{nl, error}]
      end
  end.

try_send(L, Cfg) ->
  case re:run(L, "\n") of
    {match, [{_, _}]} ->
      case re:run(L, "^(NL,send,)(.*)", [dotall, {capture, [1, 2], binary}]) of
        {match, [<<"NL,send,">>, P]}  -> nl_send_extract(P, Cfg);
        nomatch ->
          case re:run(L,"^(NL,get,)(.*?)[\n]+(.*)", [dotall, {capture, [1, 2, 3], binary}]) of
            {match, [<<"NL,get,">>, P, L1]} -> [ param_extract(P) | split(L1, Cfg)];
            nomatch -> [{nl, error}]
          end
      end;
    nomatch ->
      [{more, L}]
  end.

nl_send_extract(P, Cfg) ->
  try
    {match, [ProtocolID, BDst, PayloadTail]} = re:run(P,"([^,]*),([^,]*),(.*)", [dotall, {capture, [1, 2, 3], binary}]),
    PLLen = byte_size(PayloadTail),
    IDst = binary_to_integer(BDst),
    AProtocolID = binary_to_atom(ProtocolID, utf8),

    true = PLLen < 60,

    case lists:member(AProtocolID, ?LIST_ALL_PROTOCOLS) of
      true ->
        OPLLen = PLLen - 1,
        {match, [Payload, Tail1]} = re:run(PayloadTail, "^(.{" ++ integer_to_list(OPLLen) ++ "})\n(.*)", [dotall, {capture, [1, 2], binary}]),
        Tuple = {nl, send, IDst, Payload},
        [{rcv_ul, AProtocolID, Tuple} | split(Tail1,Cfg)];
      false -> [{nl, error}]
    end
  catch error: _Reason -> [{nl, error}]
  end.

nl_recv_extract(P, _Cfg) ->
  try
    {match, [ProtocolID, BSrc, BDst, Payload]} = re:run(P,"([^,]*),([^,]*),([^,]*),(.*)", [dotall, {capture, [1, 2, 3, 4], binary}]),
    IDst = binary_to_integer(BDst),
    ISrc = binary_to_integer(BSrc),
    AProtocolID = binary_to_atom(ProtocolID, utf8),
    case lists:member(AProtocolID, ?LIST_ALL_PROTOCOLS) of
      true ->
        Tuple = {nl, recv, ISrc, IDst, Payload},
        {rcv_ll, AProtocolID, Tuple};
      false -> {nl, error}
    end
  catch error: _Reason -> {nl, error}
  end.

param_extract(P) ->
  case binary_to_atom(P, utf8) of
    protocols ->
      {rcv_ul, get, protocols};
    _ ->
    case re:run(P,"(protocol,|fsm,|stats,)(.*)", [dotall, {capture, [1, 2], binary}]) of
      {match, [<<"protocol,">>, Name]} -> protocol_extract(Name);
      {match, [<<"fsm,">>, Name]} -> state_extract(Name);
      {match, [<<"stats,">>, Name]} -> stat_extract(Name);
      nomatch -> {nl, error}
    end
  end.

protocol_extract(P) ->
  try
    {match, [Name, Command]} = re:run(P,"([^,]*),(.*)", [dotall, {capture, [1, 2], binary}]),
    case lists:member(NPA = binary_to_atom(Name, utf8), ?LIST_ALL_PROTOCOLS) of
      true ->
        case CPA = binary_to_atom(Command, utf8) of
          _ when CPA =:= info; CPA =:= state; CPA =:= states; CPA =:= neighbours; CPA =:= routing ->
            {rcv_ul, get, {protocol, NPA, CPA} };
          _ -> {nl, error}
        end;
      false -> {nl, error}
    end
  catch error: _Reason -> {nl, error}
  end.

state_extract(Name) ->
  case NPA = binary_to_atom(Name, utf8) of
    _ when NPA =:= state; NPA =:= states ->
      {rcv_ul, get, {fsm, NPA} };
    _ -> {nl, error}
  end.

stat_extract(P) ->
  try
    {match, [Name, Command]} = re:run(P,"([^,]*),(.*)", [dotall, {capture, [1, 2], binary}]),
    case lists:member(NPA = binary_to_atom(Name, utf8), ?LIST_ALL_PROTOCOLS) of
      true ->
        case CPA = binary_to_atom(Command, utf8) of
          _ when CPA =:= paths; CPA =:= neighbours; CPA =:= data ->
            {rcv_ul, get, {statistics, NPA, CPA} };
          _ -> {nl, error}
        end;
      false -> {nl, error}
    end
  catch error: _Reason -> {nl, error}
  end.
