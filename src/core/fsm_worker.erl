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
          share                 % Share ets table
         }).

start(Behaviour, Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  gen_event:notify(error_logger, {fsm_core, self(), {Mod_ID, start}}),
  Ret = gen_server:start_link({local, Mod_ID}, ?MODULE,
                              #modstate{behaviour = Behaviour, role_ids = Role_IDs, mod_id = Mod_ID, sup_id = Sup_ID, mfa = {M, F, A}}, []),
  case Ret of
    {error, Reason} -> error_logger:error_report({error, Reason, Mod_ID});
    _ -> nothing
  end,
  Ret.

init(#modstate{behaviour = B, mod_id = Mod_ID, role_ids = Role_IDs, mfa = {_, _, ArgS}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {Mod_ID, init}}),
  process_flag(trap_exit, true),
  Share = ets:new(table, [ordered_set, public]),
  FSMs_pre = B:register_fsms(Mod_ID, Role_IDs, Share, ArgS),
  FSMs = lists:map(fun(FSM) -> FSM#sm{id = Mod_ID} end, FSMs_pre),
  {ok, State#modstate{fsms = FSMs, share = Share}}.

handle_call(behaviour = Request, From, #modstate{behaviour = B, mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {Request, From}}}),
  {reply, B, State};

handle_call(Request, From, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {Request, From}}}),
  {stop, {Request, From}, State}.

handle_cast({Src_Role_PID, Src_Role_ID, ok} = Req, #modstate{mod_id = ID, role_ids = Role_IDs} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, Req}}),
  {New_Role_IDs, Status} =
    lists:foldl(fun({Role, Role_ID, _, Flag, E} = Item, {Acc_Role_IDs, AccFlag}) ->
                    case Role_ID =:= Src_Role_ID of
                      true  -> {[{Role, Role_ID, Src_Role_PID, true, E} | Acc_Role_IDs], AccFlag};
                      false -> {[Item | Acc_Role_IDs], Flag and AccFlag}
                    end
                end, {[], true}, Role_IDs),
  if Status ->
      run_next_fsm(State#modstate{role_ids = New_Role_IDs});
     true ->
      {noreply, State#modstate{role_ids = New_Role_IDs}}
  end;

handle_cast(restart, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, restart}}),
  {stop, restart, State};

handle_cast({stop, SM, normal}, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {stop, SM, normal}}}),
  ets:delete(SM#sm.table),
  {noreply, State};

handle_cast({stop, SM, Reason}, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {stop, SM, Reason}}}),
  ets:delete(SM#sm.table),
  {stop, Reason, State};

handle_cast(Request, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, Request}}),
  {stop, Request, State}.

handle_info({'EXIT',Pid,Reason}, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {exit,Pid,Reason}}}),
  run_next_fsm(State);

handle_info(Info, #modstate{mod_id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, Info}}),
  {stop, Info, State}.       

terminate(Reason, #modstate{mod_id = ID, sup_id = Sup_ID, share = Share}) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {terminate, Reason}}}),
  case supervisor:terminate_child(Sup_ID, {fsm, ID}) of
    ok ->
      nothing;
    {error, not_found} ->
      gen_event:notify(error_logger, {fsm_core, self(), {ID, {error, child_not_found}}})
  end,
  ets:delete(Share),
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

run_next_fsm(#modstate{fsms = []} = State) ->
  {stop, normal, State};
  %% {stop, empty_fsms, State};

run_next_fsm(#modstate{fsms = FSMs, mod_id = Mod_ID, sup_id = Sup_ID, share = Share} = State) ->
  Table = ets:new(table, [ordered_set, public]),
  FSM = hd(FSMs),
  ets_insert_sm(Table, (FSM#sm.module):trans()),
  FSM_worker = {{fsm,Mod_ID}, 
                {FSM#sm.module, start_link, [FSM#sm{share = Share, table = Table}]},
                temporary, 10000, worker, [fsm]},
  {ok, Child_pid} = supervisor:start_child(Sup_ID, FSM_worker),
  link(Child_pid),
  {noreply, State#modstate{fsms = tl(FSMs)}}.

%% public helper functions
role_info(Role_IDs, Role) when is_atom(Role) ->
  [{Role,Role_ID,MM,F,E} || {Role1,Role_ID,MM,F,E} <- Role_IDs, Role1 == Role];

role_info(Role_IDs, Roles) when is_list(Roles) ->
  lists:flatten([role_info(Role_IDs, R) || R <- Roles]).

