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
-module(fsm_mod_supervisor).
-behaviour(supervisor).

-include("fsm.hrl").

-export([start_link/1, init/1]).
-import(lists, [map/2, zip/2, seq/2]).

-export([role_workers/4]).

start_link(Args) ->
  {module, ID, _} = Args,
  Sup_ID = list_to_atom(lists:flatten(io_lib:format("~p_~p",[?MODULE,ID]))),
  supervisor:start_link({local, Sup_ID}, ?MODULE, {supervisor, Sup_ID, args, Args}).

role_workers(ID, Mod_ID, Offset, ConfigData) ->
  Roles = 
    [{R,{cowboy,I,P},[]}       || {role,R,iface,{cowboy,I,P}} <- ConfigData] ++
    [{R,{cowboy,I,P},E}        || {role,R,params,E,iface,{cowboy,I,P}} <- ConfigData] ++
    [{R,{erlang,I1,Target},[]} || {role,R,iface,{erlang,id,I1,target,Target}} <- ConfigData] ++
    [{R,{erlang,I1,Target},E}  || {role,R,params,E,iface,{erlang,id,I1,target,Target}} <- ConfigData] ++
    [{R,{socket,I,P,T},[]}     || {role,R,iface,{socket,I,P,T}} <- ConfigData] ++
    [{R,{socket,I,P,T},E}      || {role,R,params,E,iface,{socket,I,P,T}} <- ConfigData] ++  
    [{R,{port,P,PS},[]}        || {role,R,iface,{port,P,PS}} <- ConfigData] ++      
    [{R,{port,P,PS},E}         || {role,R,params,E,iface,{port,P,PS}} <- ConfigData],
  Role_ID_list = map(fun({N, {R,If,_}}) ->
                         list_to_atom(lists:flatten(case If of
                                                      {socket,_,_,_}  -> io_lib:format("~p_~p_~p",[R,ID,N]);
                                                      {port,_,_}      -> io_lib:format("~p_~p_~p",[R,ID,N]);
                                                      {cowboy,_,_}    -> io_lib:format("~p_~p_~p",[R,ID,N]);
                                                      {erlang,I1,_} -> io_lib:format("~p_~p",[ID,I1])
                                                    end))
                     end, zip(seq(Offset,Offset-1+length(Roles)), Roles)),
  %% M2,I2
  Role_workers = map(fun({Role_ID, {R,If,E}}) ->
                         Iface = case If of
                                   {socket, I, P, T} ->
                                     {ok, IP} = inet:parse_ipv4_address(I),
                                     {socket, IP, P, T};
                                   {erlang, _, MID} when is_atom(MID) ->
                                     {erlang, MID};
                                   {erlang, _, {M2, I2}} ->
                                     MID = list_to_atom(lists:flatten(io_lib:format("~p_~p",[M2,I2]))),
                                     {erlang, MID};
                                   {erlang, _, {M2, I2, Remote}} ->
                                     MID = list_to_atom(lists:flatten(io_lib:format("~p_~p",[M2,I2]))),
                                     {erlang, {MID, Remote}};
                                   _ -> If
                                 end,
                         Role = case If of
                                  {erlang, _, _} -> role_fake;
                                  _ -> list_to_atom("role_" ++ atom_to_list(R))
                                end,
                         MM = #mm{role=R,role_id=Role_ID,iface=Iface,params=E},
                         {Role_ID,
                          {Role, start, [Role_ID, Mod_ID, MM]},
                          permanent, 1000, worker, [role_worker]}
                     end, zip(Role_ID_list, Roles)),
  Role_IDs = [{R,Role_ID,undefined,false,E} || {Role_ID, {R,_,E}} <- zip(Role_ID_list, Roles)],
  {Role_IDs, Role_workers}.
  
%% {spec, #{restart => restart()}}
init({supervisor, Sup_ID, args, {module, ID, ConfigData}}) ->
  [{M, F, A}] = [{Mx, Fx, Ax} || {mfa, Mx, Fx, Ax} <- ConfigData],
  Spec =
    case [SpecX || {spec, SpecX} <- A] of
      [Item | []] when is_map(Item) -> Item;
      _ -> #{}
    end,
  Restart = maps:get(restart, Spec, permanent),
  Mod_ID = list_to_atom(lists:flatten(io_lib:format("~p_~p",[M,ID]))),
  {Role_IDs, Role_workers} = role_workers(ID, Mod_ID, 1, ConfigData),
  SM_worker = {Mod_ID, 
               {M, start, [Mod_ID, Role_IDs, Sup_ID, {M, F, A}]},
               Restart, 1000, worker, [fsm_worker]},

  {ok, {{one_for_all, 30, 10}, [SM_worker | Role_workers]}}.
  %% {ok, {{one_for_all, 0, 1}, [SM_worker | Role_workers]}}.
