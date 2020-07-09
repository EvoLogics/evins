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
-module(fsm_worker).
-behaviour(gen_server).

-include("fsm.hrl").

-import(lists, [zip/2]).

-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).
-export([start/5]).

%% public helper functions
-export([role_info/2]).

-type tab() :: atom() | integer().

-callback start(ref(), list(ref()), any(), {any(), any(), any()}) -> {ok,pid()} | ignore | {error,any()}.
-callback register_fsms(ref(), list(ref()), tab(), list(any)) -> list(#sm{}).

-record(modstate, {
          behaviour,            % Calling behaviour module name (for callbacks)
          role_ids,             % 
          mod_id,               % what will be the own registered name
          sup_id,               % supervisor name
          mfa,                  % {M, F, A} to run
                                                % M basically defines the calling behaviour
          fsms,                 % list of FSMs to run sequentially
          fsm_pids,             % list of running FSM child pids
          share                 % Share ets table
         }).

start(Behaviour, Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  logger:info("fsm: ~p~nstart", [Mod_ID]),
  Ret = gen_server:start_link({local, Mod_ID}, ?MODULE,
                              #modstate{behaviour = Behaviour, role_ids = Role_IDs, mod_id = Mod_ID, sup_id = Sup_ID, mfa = {M, F, A}}, []),
  case Ret of
    {error, Reason} -> logger:error("fsm: ~p~nstart error: ~p", [Mod_ID, Reason]);
    _ -> nothing
  end,
  Ret.

init(#modstate{behaviour = B, mod_id = Mod_ID, role_ids = Role_IDs, mfa = {_, _, ArgS}} = State) ->
  logger:info("fsm: ~p~ninit~nroles: ~p", [Mod_ID, Role_IDs]),
  process_flag(trap_exit, true),
  Share = share:init(),
  FSMs_pre = B:register_fsms(Mod_ID, Role_IDs, Share, ArgS),
  FSMs = lists:map(fun(FSM) -> FSM#sm{id = Mod_ID} end, FSMs_pre),
  case Role_IDs of
    [] ->
      gen_server:cast(self(), {nothing, nothing, ok});
    _ ->
      nothing
  end,
  {ok, State#modstate{fsms = FSMs, fsm_pids = [], share = Share}}.

handle_call(behaviour, _From, #modstate{behaviour = B} = State) ->
  {reply, B, State};

handle_call(Request, From, #modstate{mod_id = ID} = State) ->
  logger:error("fsm: ~p~nunhandled call: ~p~nfrom: ~p", [ID, Request, From]),
  {stop, unhandled_call, State}.

handle_cast({Src_Role_PID, Src_Role_ID, ok}, #modstate{mod_id = ID, role_ids = Role_IDs, fsm_pids = []} = State) ->
  logger:info("fsm: ~p~nrole init: ~p, pid: ~p", [ID, Src_Role_ID, Src_Role_PID]),
  {New_Role_IDs, Status} =
    lists:foldl(fun({Role, Role_ID, _, Flag, E} = Item, {Acc_Role_IDs, AccFlag}) ->
                    case Role_ID =:= Src_Role_ID of
                      true  -> {[{Role, Role_ID, Src_Role_PID, true, E} | Acc_Role_IDs], AccFlag};
                      false -> {[Item | Acc_Role_IDs], Flag and AccFlag}
                    end
                end, {[], true}, Role_IDs),
  if Status ->
      run_fsms(State#modstate{role_ids = New_Role_IDs});
     true ->
      {noreply, State#modstate{role_ids = New_Role_IDs}}
  end;
handle_cast({Src_Role_PID, Src_Role_ID, ok}, #modstate{mod_id = ID, role_ids = Role_IDs, fsm_pids = PIDs} = State) ->
  logger:info("fsm: ~p~nrole init: ~p, pid: ~p", [ID, Src_Role_ID, Src_Role_PID]),
  New_role_IDs =
    lists:map(fun({Role, Role_ID, _, _, E} = Item) when Role_ID == Src_Role_ID ->
                  lists:map(fun(PID) ->
                                gen_server:cast(PID, {role, Item})
                            end, PIDs),
                  {Role, Role_ID, Src_Role_PID, true, E};
                 (Item) -> Item
              end, Role_IDs),
  {noreply, State#modstate{role_ids = New_role_IDs}};

handle_cast({role, Role_ID}, #modstate{role_ids = Role_IDs} = State) ->
  {noreply, State#modstate{role_ids = [Role_ID | Role_IDs]}};  

handle_cast(restart, #modstate{mod_id = ID} = State) ->
  logger:info("fsm: ~p~nrestart", [ID]),
  {stop, restart, State};

handle_cast({stop, _SM, Reason}, #modstate{mod_id = ID} = State) ->
  logger:info("fsm: ~p~nstop~nreason: ~p", [ID, Reason]),
  {stop, Reason, State};

handle_cast(Request, #modstate{mod_id = ID} = State) ->
  logger:error("fsm: ~p~nunhandled cast: ~p", [ID, Request]),
  {stop, unhandled_cast, State}.

handle_info({'EXIT',_,_Reason}, State) ->
  {noreply, State};

handle_info(Info, #modstate{mod_id = ID} = State) ->
  logger:error("fsm: ~p~nunhandled info: ~p", [ID, Info]),
  {stop, unhandled_info, State}.

terminate(Reason, #modstate{mod_id = ID, sup_id = _Sup_ID, share = Share}) ->
  logger:info("fsm: ~p~nterminate: ~p", [ID, Reason]),
  %% FIXME: should it be done? maybe to clean up the tree! no need for temporary
  %% case supervisor:terminate_child(Sup_ID, {fsm, ID}) of
  %%   ok ->
  %%     nothing;
  %%   {error, not_found} ->
  %%     gen_event:notify(error_logger, {fsm_core, self(), {ID, {error, child_not_found}}})
  %% end,
  share:delete(#sm{share = Share}),
  ok.

code_change(_, State, _) ->
  {ok, State}.

ets_insert_sm(Table, Trans) ->
  lists:foreach(fun({S, L}) ->
                    L2 = [{E, eps, eps, S1} || {E, S1} <- L],
                    L4 = [{E, Pop, Push, S1} || {E, Pop, Push, S1} <- L],
                    lists:foreach(fun({E, Pop, Push, S1}) -> 
                                      %% {state, event, pop_event} -> {state', push_event}
                                      ets:insert(Table, {{S, E, Pop}, {S1, Push}}) 
                                  end, L2 ++ L4)
                end, Trans).

run_next_fsm(FSM, #modstate{mod_id = Mod_ID, sup_id = Sup_ID, share = Share}) ->
  Table = ets:new(table, [ordered_set, public]),
  ets_insert_sm(Table, (FSM#sm.module):trans()),
  FSM_worker = {{FSM#sm.module, Mod_ID}, 
  %% FSM_worker = {FSM#sm.module, 
                {FSM#sm.module, start_link, [FSM#sm{share = Share, table = Table}]},
                temporary, 10000, worker, [fsm]},
  {ok, Child_pid} = supervisor:start_child(Sup_ID, FSM_worker),
  link(Child_pid),
  Child_pid.

run_fsms(#modstate{fsms = FSMs} = State) ->
  PIDs =
    lists:map(fun(FSM) ->
                  run_next_fsm(FSM, State)
              end, FSMs),
  {noreply, State#modstate{fsms = [], fsm_pids = PIDs}}.

%% public helper functions
role_info(Role_IDs, Role) when is_atom(Role) ->
  [{Role,Role_ID,MM,F,E} || {Role1,Role_ID,MM,F,E} <- Role_IDs, Role1 == Role];

role_info(Role_IDs, Roles) when is_list(Roles) ->
  lists:flatten([role_info(Role_IDs, R) || R <- Roles]).

