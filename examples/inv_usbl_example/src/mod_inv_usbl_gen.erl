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
-module(mod_inv_usbl_gen).
-behaviour(fsm_worker).

-include_lib("evins/include/fsm.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  parse_conf(Mod_ID, ArgS, Share),
  Roles = fsm_worker:role_info(Role_IDs, [at]),
  [#sm{roles = [hd(Roles)], module = fsm_conf}, #sm{roles = Roles, module = fsm_inv_usbl_gen}].

parse_conf(_Mod_ID, ArgS, Share) ->
  QDelay = [P || {query_delay, P} <- ArgS],
  ADelay = [P || {answer_delay, P} <- ArgS],
  Mode   = [P || {mode, P} <- ArgS],
  Addr   = [P || {dst, P} <- ArgS],
  Pid    = [P || {pid, P} <- ArgS],

  share:put(#sm{share = Share}, [{query_delay, set_params(QDelay, 1000)},
                                 {answer_delay, set_params(ADelay, 500)},
                                 {mode, set_params(Mode, im)},
                                 {dst, set_params(Addr, 1)},
                                 {pid, set_params(Pid, 0)}]).

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.
