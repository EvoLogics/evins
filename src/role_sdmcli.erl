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
-module(role_sdmcli).
-behaviour(role_worker).
-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM).

ctrl(_,Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

%% stop
%% rx,<len>,<filename>
%% tx,<filename>
%% ref,<filename>
%% config,threshould,gain,source_level

%% hook,rx,<len>,<filename>

%% stop
%% report,<code_name>,<len>
%% busy,<code_name>
%% rx

split(L, Cfg) ->
  case re:split(L,"\n",[{parts,2}]) of
    [Line,Rest] ->
      try 
        case re:split(Line,",") of
          [<<"stop">>] ->
            [{sdmcli, {stop}} | split(Rest, Cfg)];
          [<<"rx">>,BLen,BFName] ->
            [{sdmcli, {rx, binary_to_integer(BLen), binary_to_list(BFName)}} | split(Rest, Cfg)];
          [<<"hook">>,<<"rx">>,BLen,BFName] ->
            [{sdmcli, {hook, rx, binary_to_integer(BLen), binary_to_list(BFName)}} | split(Rest, Cfg)];
          [<<"tx">>,BFName] ->
            [{sdmcli, {tx, binary_to_list(BFName)}} | split(Rest, Cfg)];
          [<<"ref">>,BFName] ->
            [{sdmcli, {ref, binary_to_list(BFName)}} | split(Rest, Cfg)];
          [<<"config">>,BThr,BGain,BSL] ->
            [Thr,Gain,SL] = [binary_to_integer(X) || X <- [BThr,BGain,BSL]],
            [{sdmcli, {config,Thr,Gain,SL}} | split(Rest, Cfg)]
        end
      catch
        _Error:_ ->
          io:format("Error: ~p~n", [_Error]),
          [{error, {parseError, binary_to_list(L)}} | split(Rest, Cfg)]
      end;
    [_] -> [{more, L}]
  end.

from_term({sdmcli,{rx}}, Cfg) ->
  [<<"rx\n">>, Cfg];
from_term({sdmcli,{hook}}, Cfg) ->
  [<<"hook\n">>, Cfg];
from_term({sdmcli,{stop}}, Cfg) ->
  [<<"stop\n">>, Cfg];
from_term({sdmcli,{report,Name,Len}}, Cfg) ->
  [list_to_binary(["report",$,,atom_to_list(Name),$,,integer_to_list(Len),"\n"]), Cfg];
from_term({sdmcli,{busy,Name}}, Cfg) ->
  [list_to_binary(["busy",$,,atom_to_list(Name),"\n"]), Cfg];
from_term(_, _) ->
  {error, term_not_supported}.

