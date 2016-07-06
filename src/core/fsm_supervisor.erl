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
-module(fsm_supervisor).
-behaviour(supervisor).

-export([start_link/1, init/1, check_terms/1, check_role/1, check_mfa/1]).
-import(lists, [map/2, any/2]).

start_link(Args) ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, Args).

init(Args) ->
  {ok,{{one_for_one, 3, 10},
  %% {ok,{{one_for_one, 0, 1},
       [{fsm_watch,
         {fsm_watch, start_link, [Args, ?MODULE]},
         permanent, 1000, supervisor, []}]}}.

check_terms(ConfigData) ->
  L = map(fun check_term/1, ConfigData),
  IDs = [ID || {module,ID,_} <- ConfigData],
  L1 = case erlang:length(IDs) == ordsets:size(ordsets:from_list(IDs)) of
         true -> L;
         _ -> [{error, dups} | L]
       end,
  [X || {error, X} <- L1].

check_role({role,_,_,_} = Role_spec) -> check_list_term(Role_spec);
check_role({role,_,_,_,_,_} = Role_spec) -> check_list_term(Role_spec);
check_role(X) -> {error, {badRole, X}}.

check_mfa({mfa,_,_,_} = MFA) -> check_list_term(MFA);
check_mfa(X) -> {error, {badMFA, X}}.

check_port_name({spawn, Command}) when is_list(Command); is_binary(Command) -> ok;
check_port_name({spawn_driver, Command}) when is_list(Command); is_binary(Command) -> ok;
check_port_name({spawn_executable, FileName}) when is_list(FileName) -> ok;
check_port_name({fd, In, Out}) when is_number(In), is_number(Out) -> ok;
check_port_name(X) -> {error, {badPort, X}}.

check_list_term({role,Role,iface,{cowboy,Address,Port}})
  when is_atom(Role), is_list(Address), is_integer(Port) ->
  ok;
check_list_term({role,Role,params,Params,iface,{cowboy,Address,Port}})
  when is_atom(Role), is_list(Params), is_list(Address), is_integer(Port) ->
  ok;
check_list_term({role,Role,iface,{erlang,id,EID,target,{Module_ID,TID}}})
  when is_atom(Role), is_atom(EID), is_atom(Module_ID), is_atom(TID) ->
  ok;
check_list_term({role,Role,iface,{erlang,id,EID,target,MID}})
  when is_atom(Role), is_atom(EID), is_atom(MID) ->
  ok;
check_list_term({role,Role,iface,{erlang,id,EID,target,{Module_ID,TID,Remote}}})
  when is_atom(Role), is_atom(EID), is_atom(Module_ID), is_atom(TID), is_atom(Remote)->
  ok;
check_list_term({role,Role,params,Params,iface,{erlang,id,EID,target,MID}})
  when is_atom(Role), is_list(Params), is_atom(EID), is_atom(MID) ->
  ok;
check_list_term({role,Role,params,Params,iface,{erlang,id,EID,target,{Module_ID,TID}}})
  when is_atom(Role), is_list(Params), is_atom(EID), is_atom(Module_ID), is_atom(TID) ->
  ok;
check_list_term({role,Role,params,Params,iface,{erlang,id,EID,target,{Module_ID,TID,Remote}}})
  when is_atom(Role), is_list(Params), is_atom(EID), is_atom(Module_ID), is_atom(TID), is_atom(Remote) ->
  ok;
check_list_term({role,Role,iface,{socket,Address,Port,TCPRole}})
  when is_atom(Role), is_list(Address), is_integer(Port), is_atom(TCPRole) ->
  ok;
check_list_term({role,Role,params,Params,iface,{socket,Address,Port,TCPRole}})
  when is_atom(Role), is_list(Params), is_list(Address), is_integer(Port), is_atom(TCPRole) ->
  ok;
check_list_term({role,Role,iface,{port,PortName,PortSettings}})
  when is_atom(Role), is_list(PortSettings) ->
  check_port_name(PortName);
check_list_term({role,Role,params,Params,iface,{port,PortName,PortSettings}})
  when is_atom(Role), is_list(Params), is_list(PortSettings) ->
  check_port_name(PortName);
check_list_term({mfa,M,F,A}) when is_atom(M), is_atom(F), is_list(A) ->
  ok;
check_list_term(X) -> {error, {badTerm, X}}.

check_term({module,ID,L}) when is_atom(ID), is_list(L) ->
  IsMFA = lists:keymember(mfa,1,L),
  AnyError = (not IsMFA) or 
    any(fun(X) ->
            case check_list_term(X) of
              ok -> false;
              {error, _Error} -> true
            end
        end, L),
  case AnyError of
    true -> {error, {badTerm, L}};
    false -> []
  end;
check_term(X) -> {error, {badTerm, X}}. 
