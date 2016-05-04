%% Copyright (c) 2016, Oleksiy Kebkal <lesha@evologics.de>
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
-module(role_sdm).
-behaviour(role_worker).
-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

%% states: idle, rx

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, idle).

ctrl(idle,_) -> idle;
ctrl(rx,_) -> rx.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

split(L, rx) ->
  case binary:split(L,<<16#80007fff00000000:64>>,[global]) of
    [Body] when size(Body) > 7 ->
      S = size(Body),
      B = binary:part(Body,{0, S - 7}),
      R = binary:part(Body,{S, - 7}),
      [{sdm,{rx, B}}, {more, R}];
    [Body] ->
      [{more, Body}];
    [Body | RestList] ->
      Rest = list_to_binary([[<<16#80007fff00000000:64>>,I] || I <- RestList]),
      [{sdm,{rx, Body}}, {ctrl, idle} | split(Rest, idle)]
  end;
split(L, idle = Cfg) ->
  case binary:split(L,<<16#80007fff00000000:64>>,[global]) of
    [_Garbage, <<Cmd:8, Param: 24/unsigned-little-integer, Len: 32/signed-little-integer, Body/binary>> | RestList] ->
      Rest = list_to_binary([[<<16#80007fff00000000:64>>,I] || I <- RestList]),
      case code_to_atom(Cmd) of
        stop ->
          [{sdm, {stop}} | split(Rest, Cfg)];
        rx ->
          case size(Body) of
            _ when size(Rest) > 0 ->
              [{sdm,{rx,start}}, {sdm,{rx, Body}} | split(Rest, Cfg)];
            S when size(Rest) == 0, S > 7 ->
              %% Body might contain part of header
              B = binary:part(Body, {0, S - 7}),
              R = binary:part(Body, {S, -7}),
              [{sdm,{rx,start}}, {sdm,{rx, B}}, {more, R}, {ctrl, rx}];
            _ when size(Rest) == 0 ->
              [{sdm,{rx,start}}, {more, Body}, {ctrl, rx}]
          end;
        busy ->
          [{sdm,{busy, code_to_atom(Param)}} | split(Rest, Cfg)];
        report ->
          [{sdm,{report,report_code_to_atom(Param),Len}} | split(Rest, Cfg)];
        _ ->
          [{error, {unknownCommand, Cmd}} | split(Rest, Cfg)]
      end;
    _ -> [{more, L}]
  end.

from_term({sdm,{stop}}, Cfg) ->
  [<<16#80007fff00000000:64, (atom_to_code(stop)):8, 0:24, 0:32>>, Cfg];
from_term({sdm,{config,Thr,Gain,SL}}, Cfg) ->
  [<<16#80007fff00000000:64, (atom_to_code(config)):8, Thr:16/little-integer,Gain:1,SL:7, 0:32>>, Cfg];
from_term({sdm,{tx,Data}}, Cfg) when is_binary(Data) ->
  case (size(Data) band 1) of
    1 -> {error, oddDataSize};
    0 ->
      Len = size(Data) div 2,
      [<<16#80007fff00000000:64, (atom_to_code(tx)):8, 0:24, Len:32/signed-little-integer, Data/binary>>, Cfg]
  end;
from_term({sdm,{rx,Len}}, Cfg) ->
  [<<16#80007fff00000000:64, (atom_to_code(rx)):8, Len:24/unsigned-little-integer, 0:32>>, Cfg];
from_term({sdm,{ref,Data}}, Cfg) when is_binary(Data) ->
  case (size(Data) band 1) of
    1 -> {error, oddDataSize};
    0 ->
      Len = size(Data) div 2,
      [<<16#80007fff00000000:64, (atom_to_code(ref)):8, 0:24, Len:32/signed-little-integer, Data/binary>>, Cfg]
  end;
from_term(_, _) ->
  {error, term_not_supported}.

report_code_to_atom(254) -> garbage;
report_code_to_atom(255) -> unknown;
report_code_to_atom(Code) -> code_to_atom(Code).

code_to_atom(0) -> stop;
code_to_atom(1) -> tx;
code_to_atom(2) -> rx;
code_to_atom(3) -> ref;
code_to_atom(4) -> config;
code_to_atom(254) -> busy;
code_to_atom(255) -> report;
code_to_atom(_) -> nothing.

atom_to_code(stop) -> 0;
atom_to_code(tx) -> 1;
atom_to_code(rx) -> 2;
atom_to_code(ref) -> 3;
atom_to_code(config) -> 4;
atom_to_code(254) -> 254;
atom_to_code(255) -> 255.
