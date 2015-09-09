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
-module(evins).

%% module for console interaction with user
-include("fsm.hrl").

%% running modules
-export([supervisors/0,stop/1,stop_all/0,restart/1,restart_all/0]).
-export([loaded_modules/0,find_id/1,fabric_config/0,user_config/0,configured_modules/0,update_config/0,update_config/1,sign_config/1,cast/2]).

-export([module_parameters/1,module_parameters/2,roles/1,roles/3,store_config/0,store_config/1,config/1,config/0]).
-export([module_id/2,mfa/1,mfa/2]).
-export([add_module/1,delete_module/1]).

%% TODO: reflect status, that running configuration doesn't correspond to the stored in the memory

-export([rb/1,rb/2]).
-export([logon/0,logon/1,logoff/0,q/0]).
-export([tail/0,tail/1,tail/2]).
-export([fsm_events/0]).

%% private API
-export([log/1]).

-define(TAIL,10).

called_by(Process, Initial_call) ->
  lists:filter(fun(L) ->
                   D = proplists:get_value(dictionary, process_info(L)),
                   Initial_call == proplists:get_value('$initial_call', D)
               end, proplists:get_value(links, process_info(Process))).

supervisors() ->
  called_by(whereis(fsm_supervisor), {supervisor,fsm_mod_supervisor,1}).

fabric_config() -> gen_server:call(fsm_watch, fabric_config).
user_config() -> gen_server:call(fsm_watch, user_config).
configured_modules() -> gen_server:call(fsm_watch, configured_modules).

add_module(Module_spec) -> gen_server:call(fsm_watch, {add, Module_spec}).
delete_module(Module_id) -> gen_server:call(fsm_watch, {delete, Module_id}).   

module_parameters(Module_ID) -> gen_server:call(fsm_watch, {module_parameters, Module_ID}).
module_parameters(Module_ID, Opts) -> gen_server:call(fsm_watch, {module_parameters, Module_ID, Opts}).

module_id(Module_ID, Module_ID_new) -> gen_server:call(fsm_watch, {module_id, Module_ID, Module_ID_new}).

mfa(Module_ID) -> gen_server:call(fsm_watch, {mfa, Module_ID}).
mfa(Module_ID, MFA_new) -> gen_server:call(fsm_watch, {mfa, Module_ID, MFA_new}).

roles(Module_ID) -> gen_server:call(fsm_watch, {roles, Module_ID}).
roles(Module_ID, Role_spec_old, Role_spec_new) -> gen_server:call(fsm_watch, {roles, Module_ID, Role_spec_old, Role_spec_new}).

config(Module_ID) -> gen_server:call(fsm_watch, {config, Module_ID}).
config() -> gen_server:call(fsm_watch, config).

store_config() -> gen_server:call(fsm_watch, {store, user_config()}).
store_config(Filename) -> gen_server:call(fsm_watch, {store, Filename}).

rb(start)          -> fsm_rb:start();
rb(stop)           -> fsm_rb:stop().
rb(start, Options) -> fsm_rb:start(Options).

fsm_events() ->
  [fsm_event, fsm_transition, fsm_cast, fsm_event, fsm_progress].

fsm_rb_request(Fun,Args) ->
  case whereis(rb_server) of
    undefined -> io:format("Report broweser is not running~n");
    _ -> apply(fsm_rb,Fun,Args)
  end.

tail(list, N)             -> fsm_rb_request(list_tail, [all, N]);
tail({list, Type}, N)     -> fsm_rb_request(list_tail, [Type,N]);
tail({show, Type}, N)     -> fsm_rb_request(show_tail, [Type,N]);
tail({grep, RegExp}, N)   -> fsm_rb_request(grep_tail, [RegExp, N]).
tail(list)                -> fsm_rb_request(list_tail, [all, ?TAIL]);
tail({grep, RegExp})      -> fsm_rb_request(grep_tail, [RegExp, ?TAIL]);
tail({show, Types})       -> fsm_rb_request(show_tail, [Types, ?TAIL]);
tail(N) when is_number(N) -> fsm_rb_request(tail,[N]).
tail()                    -> fsm_rb_request(tail, []).

logon() ->
  case whereis(fsm_logon) of
    undefined ->
      Pid = spawn(evins,log,[init]),
      register(fsm_logon,Pid);
    _ ->
      ok
  end.

logon(RegExp) ->
  case whereis(fsm_logon) of
    undefined ->
      Pid = spawn(evins,log,[{init,RegExp}]),
      register(fsm_logon,Pid);
    _ ->
      ok
  end.

q() -> logoff().

logoff() ->
  case whereis(fsm_logon) of
    undefined -> 
      ok;
    Pid ->
      exit(Pid,kill)
  end.

log(init) ->
  case whereis(rb_server) of
    undefined -> io:format("Report broweser is not running~n");
    _ -> N = fsm_rb:tail(),
         timer:sleep(1000),
         log(N)
  end;
log(N) when is_number(N) ->
  NN = fsm_rb:tail_after(N),
  timer:sleep(1000),
  log(NN);
log({init,RegExp}) ->
  case whereis(rb_server) of
    undefined -> io:format("Report broweser is not running~n");
    _ -> N = fsm_rb:last_no(),
         timer:sleep(1000),
         log({N,RegExp})
  end;
log({N,RegExp}) ->
  NN = fsm_rb:grep_after(RegExp,N),
  timer:sleep(1000),
  log({NN,RegExp}).

update_config() ->
  update_config(config()).

update_config(ConfigFile) ->
  Mod_supervisors = [Id || {Id,_,_,_} <- supervisor:which_children(fsm_supervisor), Id /= fsm_watch],
  case gen_server:call(fsm_watch, {update_config, ConfigFile}) of
    ok ->
      lists:map(fun(Mod_Id) ->
                    catch supervisor:terminate_child(fsm_supervisor, Mod_Id),
                    catch supervisor:delete_child(fsm_supervisor, Mod_Id)
                end, Mod_supervisors),
      ok;
    Other -> Other
  end.

sign_config(ConfigFile) ->
  Store_status = 
    case file:consult(ConfigFile) of
      {ok, ModemDataList} ->
        case fsm_supervisor:check_terms(ModemDataList) of
          [] -> ok;
          Errors -> Errors
        end;
      Read_errors -> Read_errors
    end,
  case {Store_status, file:read_file(ConfigFile)} of
    {ok, {ok, Bin}} ->
      MD5 = crypto:hash(md5, Bin),
      file:write_file(ConfigFile ++ ".md5", MD5);
    _ -> Store_status
  end.

find_id(Module_process_id) ->
  Top_mods = supervisors(),
  Mod_pids = lists:flatten(lists:map(fun(Top_mod) ->
                                         called_by(Top_mod, {fsm_worker,init,1})
                                     end, Top_mods)),
  lists:foldl(fun(P,ID) ->
                  case proplists:get_value(registered_name, process_info(P)) of
                    Module_process_id ->
                      Name = gen_server:call(Module_process_id, behaviour),
                      list_to_atom(lists:nthtail(length(atom_to_list(Name)) + 1, atom_to_list(Module_process_id)));
                    _ -> ID
                  end
              end, nothing, Mod_pids).

loaded_modules() ->
  Top_mods = supervisors(),
  Mod_pids = lists:flatten(lists:map(fun(Top_mod) ->
                                         called_by(Top_mod, {fsm_worker,init,1})
                                     end, Top_mods)),
  lists:map(fun(P) ->
                Id = proplists:get_value(registered_name, process_info(P)),
                Name = gen_server:call(Id, behaviour),
                {Name, list_to_atom(lists:nthtail(length(atom_to_list(Name)) + 1, atom_to_list(Id))), P}
            end, Mod_pids).

cast(Id, Message) when is_atom(Id) ->
  Mods = loaded_modules(),
  case [{Name,Id} || {Name,Id1,_} <- Mods, Id1 == Id] of
    [Name_pair] -> cast(Name_pair, Message);
    [] -> io:format("Module id ~p not found~n",[Id]);
    _  -> io:format("Module id ~p not uniq, use {Name,Id} pair to idenitfy module~n",[Id])
  end;

cast({Name,Id}, Message) ->
  FSM_Id = list_to_atom(lists:flatten(["fsm_",atom_to_list(Name), "_", atom_to_list(Id)])),
  gen_server:cast(FSM_Id, {chan, #mm{role_id = evins}, Message}).

stop(Id) ->
  supervisor:terminate_child(fsm_supervisor, Id).

restart(Id) ->
  stop(Id),
  case supervisor:restart_child(fsm_supervisor,Id) of
    {ok, _} -> ok;
    Other -> Other
  end.

stop_all() ->
  Modules = configured_modules(),
  [stop(ID) || {_,ID} <- Modules].

restart_all() ->
  Modules = configured_modules(),
  [restart(ID) || {_,ID} <- Modules].
