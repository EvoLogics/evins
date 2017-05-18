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
-module(role_polling_mux).
-behaviour(role_worker).

-include("fsm.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).
%-record(config, {filter, mode, waitsync, request, telegram, eol, ext_networking, pid}).
-define(EOL_RECV, <<"\r\n">>).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  %Cfg = #config{filter = nl, mode = data, waitsync = no, request = "", telegram = "", eol = "\n", ext_networking = no, pid = 0},
  Cfg = #{filter => nl, mode => data, waitsync => no, request => "",
          telegram => "", eol => "\n", ext_networking => no, pid => 0},

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
    {response, T} -> [nl_mac_hf:convert_to_binary(tuple_to_list(T)), ?EOL_RECV];
    _ ->
    #{eol := EOL} = Cfg,
    [nl_mac_hf:convert_to_binary(tuple_to_list(Tuple)), EOL]
  end.

split(L, Cfg) ->
  case re:run(L, "\r\n") of
    {match, [{_, _}]} -> try_recv(L, Cfg);
    nomatch -> try_send(L, Cfg)
  end.

try_recv(_L, _Cfg) ->
  [{nl, error}].

% NL,send..
% NL,set,polling,seq,...
% NL,set,polling,start
% NL,set,polling,stop
% NL,flush,buffer
% NL,get,polling,queue

try_send(L, Cfg) ->
  case re:run(L, "\n") of
    {match, [{_, _}]} ->
      case re:run(L,
        "^(NL,send,|NL,set,polling,seq,|NL,set,polling,start|NL,set,polling,stop|NL,flush,buffer|NL,get,protocol|NL,set,routing,|NL,set,neighbours,|NL,get,routing)(.*)",
        [dotall, {capture, [1, 2], binary}]) of
        {match, [<<"NL,send,">>, P]}  -> nl_send_extract(P, Cfg);
        {match, [<<"NL,get,protocol">>, _P]}  -> [{rcv_ul, {get, protocol}}];
        {match, [<<"NL,flush,buffer">>, _P]}  -> [{rcv_ul, {flush, buffer}}];
        {match, [<<"NL,set,polling,seq,">>, P]}  -> nl_set_polling_seq(P, Cfg);
        {match, [<<"NL,set,polling,start">>, _P]}  -> [{rcv_ul, {set, polling, start} }];
        {match, [<<"NL,set,polling,stop">>, _P]}  -> [{rcv_ul, {set, polling, stop} }];
        {match, [<<"NL,set,neighbours,">>, P]}  -> nl_set_neighbours(P, Cfg);
        {match, [<<"NL,set,routing,">>, P]}  -> nl_set_routing(P, Cfg);
        {match, [<<"NL,get,routing">>, _P]}  -> [{rcv_ul, {get, routing}}];
        nomatch -> [{nl, error}]
      end;
    nomatch ->
      [{more, L}]
  end.


nl_set_routing(P, _Cfg) ->
  try
    {match, [BRouting]} = re:run(P,"(.*)\n", [dotall, {capture, [1], binary}]),
    LRouting = string:tokens(binary_to_list(BRouting), ","),
    IRouting = lists:map(fun(X)-> S = string:tokens(X, "->"), [list_to_integer(X1) || X1 <- S] end, LRouting),
    TRouting = [case X of [A1, A2] -> {A1, A2}; [A1] -> A1 end|| X <- IRouting],
    [{rcv_ul, {set, routing, TRouting} }]
  catch error: _Reason -> [{nl, error}]
  end.

nl_set_neighbours(P, _Cfg) ->
  try
    {match, [BNeighbours]} = re:run(P,"(.*)\n", [dotall, {capture, [1], binary}]),
    LBNeighbours = binary:split(BNeighbours, [<<":">>],[global]),
    [Flag, Neighours] =
    case LBNeighbours of
      _ when length(LBNeighbours) == 1 ->
        LINeighbours = binary:split(BNeighbours, [<<",">>],[global]),
        NL = [nl_mac_hf:bin_to_num(N) || N <- LINeighbours],
        [normal, NL];
      _ ->
        LAddINeighbours = binary:split(BNeighbours, [<<",">>],[global]),
        NL =
        lists:map(fun(X) ->
          [N1, I, R, T] = binary:split(X, [<<":">>],[global]),
          {nl_mac_hf:bin_to_num(N1),
          nl_mac_hf:bin_to_num(I),
          nl_mac_hf:bin_to_num(R),
          nl_mac_hf:bin_to_num(T)} end, LAddINeighbours),
        [add, NL]
      end,
      [{rcv_ul, {set, neighbours, Flag, Neighours} }]
  catch error: _Reason -> [{nl, error}]
  end.
nl_set_polling_seq(P, _Cfg) ->
  try
    {match, [BSeq]} = re:run(P,"([^\n]*)", [dotall, {capture, [1], binary}]),
    LBSeq = binary:split(BSeq, <<",">>, [global]),
    LSeq = [ binary_to_integer(X) || X <- LBSeq],
    [{rcv_ul, {set, polling_seq, LSeq} }]
  catch error: _Reason -> [{nl, error}]
  end.

nl_send_extract(P, Cfg) ->
  try
    {match, [BTransmitLen, BDst, PayloadSTail]} = re:run(P,"([^,]*),([^,]*),(.*)", [dotall, {capture, [1, 2, 3], binary}]),

    Match_CDT_msg_type = re:run(PayloadSTail,"([^,]*),([^,]*),(.*)", [dotall, {capture, [1, 2, 3], binary}]),
    [PayloadTail, BurstTypeCDT, MsgTypeCDT] =
    case Match_CDT_msg_type of
      {match, [MsgType, BurstType, PP]} ->
          AMsgType = binary_to_atom(MsgType, utf8),
          ABurstType = binary_to_atom(BurstType, utf8),
          Messages = [dtolerant, dsensitive], %alarm????
          BurstTypes = [b, nb],
          [AMsgType] = lists:filter(fun(X)-> X == AMsgType end, Messages),
          [ABurstType] = lists:filter(fun(X)-> X == ABurstType end, BurstTypes),
          [PP, ABurstType, AMsgType];
      nomatch -> [PayloadSTail, nothing, nothing]
    end,

    PLLen = byte_size(PayloadTail),
    IDst = binary_to_integer(BDst),

    TransmitLen =
    case BTransmitLen of
      <<>> ->
        PLLen - 1;
      _ ->
        binary_to_integer(BTransmitLen)
    end,

    %true = PLLen < 50,
    {match, [Payload, Tail1]} = re:run(PayloadTail, "^(.{" ++ integer_to_list(TransmitLen) ++ "})\n(.*)", [dotall, {capture, [1, 2], binary}]),
    Tuple =
    case MsgTypeCDT of
      nothing -> {nl, send, TransmitLen, IDst, Payload};
      _ -> {nl, send, TransmitLen, IDst, MsgTypeCDT, BurstTypeCDT, Payload}
    end,

    [{rcv_ul, Tuple} | split(Tail1,Cfg)]

  catch error: _Reason -> [{nl, error}]
  end.
