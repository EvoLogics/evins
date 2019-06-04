%% Copyright (c) 2015, Oleksiy Kebkal <lesha@evologics.de>
%% Copyright (c) 2018, Oleksandr Novychenko <novychenko@evologics.de>
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

register_fsms(Mod_ID, Role_IDs, _Share, ArgS) ->
    Role_names = lists:usort([Role || {Role, _, _, _, _} <- Role_IDs]),
    Roles = fsm_worker:role_info(Role_IDs, Role_names),
    [#sm{roles = [hd(Roles)], module = fsm_conf},
     #sm{roles = Roles, env = parse_conf(Mod_ID, ArgS), module = fsm_inv_usbl_gen}].

parse_conf(_Mod_ID, ArgS) ->
    #{pid => set_params(ArgS, pid, check_integer("PID"), {error, "PID must be defined"}),
      remote_address => set_params(ArgS, remote_address, check_integer("Remote address"), {error, "Remote address must be specified"}),
      answer_delay => set_params(ArgS, answer_delay, check_integer("Answer delay"), 500),
      mode => set_params(ArgS, mode, check_atom("Mode"), ims),
      ping_delay => set_params(ArgS, ping_delay, check_integer("Ping delay"), 500),
      ping_timeout => set_params(ArgS, ping_timeout, check_integer("Ping timeout"), 5000)}.

set_params(ArgS, Name, Validate, Default) ->
    case lists:keyfind(Name, 1, ArgS) of
        {Name, Value} ->
            case Validate of
                F when is_function(F) -> F(Value);
                _ -> Value
            end;
        _ ->
            case Default of
                {error, Reason} -> error(Reason);
                _ -> Default
            end
    end.

check_integer(Name) ->
    fun(V) when is_integer(V) -> V;
       (_) -> error(Name ++ " must be an integer") end.

check_atom(Name) ->
    fun(V) when is_atom(V) -> V;
       (_) -> error(Name ++ " must be an atom") end.
