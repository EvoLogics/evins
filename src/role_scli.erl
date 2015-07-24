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
-module(role_scli).
-behaviour(role_worker).
-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM).

ctrl(_,Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

split(L, _Cfg) ->
  Lst = lists:reverse(re:split(L,"\n")),
  lists:reverse([{more, hd(Lst)} | tl(Lst)]).

from_term({string, S}, Cfg) -> [list_to_binary(S ++ "\n"), Cfg];
from_term({binary, B}, Cfg) -> [B, Cfg];
from_term({prompt}, Cfg)    -> [<<"> ">>, Cfg];
from_term(_, _)             -> {error, term_not_supported}.
