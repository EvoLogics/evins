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
-module(fsm).
-behaviour(gen_server).

-include("fsm.hrl").

%% public API
-export([start_link/1]).

%% helper functions
-export([clear_timeout/2, clear_timeouts/2, clear_timeouts/1]).
-export([run_event/3, send_at_command/2, send_at_command/3, broadcast/3, cast/2, cast/3, cast/5]).
-export([role_available/2]).
-export([set_event/2, set_timeout/3, maybe_set_timeout/3, set_interval/3, check_timeout/2]).
-export([maybe_send_at_command/2, maybe_send_at_command/3, maybe_send_at_command/4]).

%% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-callback start_link(#sm{}) -> {ok,pid()} | ignore | {error,any()}.
-callback init(#sm{}) -> #sm{}.
-callback stop(#sm{}) -> ok.
-callback handle_event(#mm{}, #sm{}, any()) -> #sm{}.
-callback trans() -> list(tuple()).
-callback final() -> list(atom()).
-callback init_event() -> atom().

start_link(#sm{id = Mod_ID, module = Module} = SM) ->
  FSM_ID = list_to_atom(atom_to_list(Module) ++ atom_to_list(Mod_ID)),
  gen_server:start_link({local, FSM_ID}, ?MODULE, SM, []).

handle_event(Module, MM, SM, Term) ->
  case Module:handle_event(MM, SM, Term) of
    NewSM when is_record(NewSM, sm) ->
      {noreply, NewSM};
    Other ->
      {stop, {error, {Module, handle_event, returns, Other}}, SM}
  end.

%%% gen_server callbacks
init(#sm{module = Module} = SM) ->
  SMi = Module:init(SM),
  Init_event = Module:init_event(),
  Finals = Module:final(),
  Self = self(),
  true = lists:all(fun(A) -> A == ok end,
                   lists:map(fun({_,Role_ID,_,_,_}) ->
                                 cast_helper(Role_ID, {fsm, Self, ok})
                             end, SMi#sm.roles)),
  {ok, run_event(nothing, SMi#sm{event = Init_event, final = Finals}, nothing)}.

handle_call(_Request, _From, SM) ->
  %% gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {Request, From}}}),
  {noreply, SM}.

handle_cast({chan, nothing, Term}, #sm{module = Module} = SM) ->
  %% gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {chan, nothing, Term}}}),
  handle_event(Module, nothing, SM, Term);

handle_cast({chan, MM, Term}, #sm{module = Module} = SM) ->
  %% gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {chan, MM#mm.role_id, Term}}}),
  handle_event(Module, MM, SM, Term);

handle_cast({send_error, MM, Reason}, #sm{module = Module} = SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {send_error, MM#mm.role_id, Reason}}}),
  handle_event(Module, MM, SM, {send_error, Reason});

handle_cast(final, SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, final}}),
  {stop, normal, SM};

handle_cast({chan_closed, MM}, #sm{module = Module} = SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {chan_closed, MM}}}),
  handle_event(Module, MM, SM, {disconnected, closed});
  %% {noreply, SM};

handle_cast({chan_error, MM, Reason}, #sm{module = Module} = SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {chan_error, MM, Reason}}}),
  handle_event(Module, MM, SM, {disconnected, {error, Reason}});

handle_cast({chan_closed_client, MM}, #sm{module = Module} = SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {chan_closed_client, MM}}}),
  handle_event(Module, MM, SM, {disconnected, closed});
  %% {noreply, SM};

handle_cast({chan_parseError, _, _} = Reason, SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, Reason}}),
  {stop, Reason, SM};

handle_cast({role, {_,Role_ID,_,_,_} = Item}, #sm{roles = Roles} = SM) ->
  Self = self(),
  cast_helper(Role_ID, {fsm, Self, ok}),
  {noreply, SM#sm{roles = [Item | Roles]}};

handle_cast(Request, SM) ->
  %% gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {unhandled_cast, Request}}}),
  {stop, Request, SM}.

handle_info({timeout,E}, #sm{module = Module} = SM) ->
  case lists:any(fun({Event,_}) -> Event == E end, SM#sm.timeouts) of
    true ->
      % this should be logged as trace. removed due to a spamming in sinaps
      %gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {timeout, E}}}),
      TL = lists:filter(fun({_,{interval,_}}) -> true;
                           ({Event,_}) -> Event =/= E
                        end, SM#sm.timeouts),
      handle_event(Module, nothing, SM#sm{timeouts = TL}, {timeout, E});
    _ ->
      gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {skipped_timeout, E}}}),
      {noreply, SM}
  end;

handle_info(Info, SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {unhandled_info, Info}}),
  {stop, Info, SM}.

code_change(_, Pid, _) ->
  {ok, Pid}.

terminate(Reason, #sm{module = Module} = SM) ->
  gen_event:notify(error_logger, {fsm_event, self(), {SM#sm.id, {terminate, Reason}}}),
  Module:stop(SM),
  cast_helper(SM#sm.id, {stop, SM, Reason}),
  ok.

run_event(_, #sm{event = eps} = SM, _) -> SM;
run_event(MM, #sm{module = Module} = SM, Term) ->
  %% (state,event,pop_event) -> (state,event,push_event)
  {Pop, Tail} = case SM#sm.stack of
                  []    -> {eps, []};
                  [H|T] -> {H,T}
                end,
  Set1 = ets:lookup(SM#sm.table, {SM#sm.state, SM#sm.event, Pop}),
  Set2 = ets:lookup(SM#sm.table, {SM#sm.state, SM#sm.event, eps}),
  {State, Stack} = case {Set1, Set2, Pop} of
                     {[], [], _}              -> {alarm, []};
                     {[{_,{S,Push}}], _, eps} -> {S, push(Push,SM#sm.stack)};
                     {[{_,{S,Push}}], _, Pop} -> {S, push(Push,Tail)};
                     {[], [{_,{S,Push}}], _}  -> {S, push(Push,SM#sm.stack)}
                   end,
  Handle = list_to_atom("handle_" ++ atom_to_list(State)),
  log_transition(SM, Stack, Handle),
  SM1 = Module:Handle(MM, SM#sm{state = State, stack = Stack}, Term),
  case is_record(SM1, sm) of
    true ->
      case is_final(SM1) of
        true ->
          FSM_ID = list_to_atom("fsm_" ++ atom_to_list(SM#sm.id)),
          cast_helper(FSM_ID, final);
        _ -> true
      end,
      case SM1#sm.event of
        eps -> SM1;
        _ -> run_event(MM, SM1, Term)
      end;
    false ->
      exit({error, {Module, Handle, returns, SM1}})
  end.

push(eps, Stack) -> Stack;
push(Push, Stack) -> [Push|Stack].

log_transition(SM, Stack, Handle) ->
  Timeouts = lists:foldl(fun({Event,TRef},A) ->
                             [{Event,TRef} | A]
                         end, [], SM#sm.timeouts),

  Report = case {Handle, Timeouts, Stack} of
             {handle_alarm, _, _} -> {ioc:timestamp_string(), Handle, SM#sm.event};
             {_, [],[]}           -> {ioc:timestamp_string(), Handle, SM#sm.event};
             {_, _, []}           -> {ioc:timestamp_string(), Handle, SM#sm.event, Timeouts};
             {_, [], _}           -> {ioc:timestamp_string(), Handle, SM#sm.event, Stack};
             {_, _,  _}           -> {ioc:timestamp_string(), Handle, SM#sm.event, Stack, Timeouts}
           end,
  gen_event:notify(error_logger, {fsm_transition, self(), {SM#sm.id, Report}}).

%% public functions
is_final(SM) ->
  lists:member(SM#sm.state, SM#sm.final).

check_timeout(#sm{timeouts = Timeouts}, Event) ->
  length(lists:filter(fun({E,_}) -> Event =:= E end, Timeouts)) =:= 1.

clear_timeouts(SM) ->
  true = lists:all(fun(A) -> A == {ok, cancel} end,
                   lists:map(fun({_,Ref}) -> timer:cancel(Ref) end, SM#sm.timeouts)),
  SM#sm{timeouts = []}.

clear_timeouts(SM, EL) ->
  lists:foldl(fun(E,SMi) -> clear_timeout(SMi, E) end, SM, EL).

clear_timeout(SM, Event) ->
  TRefList = lists:filter(fun({E,TRef}) ->
                              case E =:= Event of
                                true -> {ok, cancel} = timer:cancel(TRef), false;
                                _ -> true
                              end
                          end, SM#sm.timeouts),
  SM#sm{timeouts = TRefList}.

%% Time: {s, Seconds}, {ms, Milliseconds}, {us, Microseconds}
set_timeout(SM, {_, Value} = Time, Event) when Value > 0 -> 
  #sm{timeouts = Timeouts} = clear_timeout(SM, Event),
  MS = case Time of
         {s, V} -> V * 1000;
         {ms, V} -> V;
         {us, V} -> (V + 999) div 1000
       end,
  {ok, TRef} = timer:send_after(round(MS), {timeout, Event}),
  SM#sm{timeouts = [{Event,TRef} | Timeouts]};
set_timeout(_, {_, Value}, Event) ->
  error({error, lists:flatten(io_lib:format("~p negative ~p", [Event, Value]))});
set_timeout(_, Time, Event) ->
  error({error, lists:flatten(io_lib:format("~p no appliable ~p", [Event, Time]))}).

maybe_set_timeout(SM, Time, Event) ->
  case check_timeout(SM, Event) of
    true -> SM;
    false -> set_timeout(SM, Time, Event)
  end.

set_interval(SM, Time, Event) ->
  #sm{timeouts = Timeouts} = clear_timeout(SM, Event),
  MS = case Time of
         {s, V} -> V * 1000;
         {ms, V} -> V;
         {us, V} -> (V + 999) div 1000
       end,
  {ok, TRef} = timer:send_interval(round(MS), {timeout, Event}),
  SM#sm{timeouts = [{Event,TRef} | Timeouts]}.

set_event(SM, Event) ->
  SM#sm{event = Event}.

send_at_command(SM, AT) ->
  send_at_command(SM, ?ANSWER_TIMEOUT, AT).

send_at_command(SM, Answer_timeout, AT) ->
  set_event(
    set_timeout(
      cast(SM, at, {send, AT}), Answer_timeout, answer_timeout), eps).

maybe_send_at_command(SM, AT) ->
  maybe_send_at_command(SM, AT, fun(LSM,_) -> LSM end).

maybe_send_at_command(SM, AT, Fun) ->
  maybe_send_at_command(SM, ?ANSWER_TIMEOUT, AT, Fun).

maybe_send_at_command(SM, Answer_timeout, AT, Fun) ->
  case fsm:check_timeout(SM, answer_timeout) of
    true ->
      Fun(SM,blocked);
    _ ->
      Fun(fsm:send_at_command(SM, Answer_timeout, AT), ok)
    end.

broadcast(#sm{roles = Roles} = SM, Target_role, T) ->
  true = lists:all(fun(A) -> A == ok end, 
                   lists:map(fun(Role_ID) ->
                                 cast_helper(Role_ID, T)
                             end, [Role_ID || {Role,Role_ID,_,_,_} <- Roles, Role == Target_role])),
  SM.

cast(#cbstate{id = CB_ID, fsm_id = FSM_ID}, T) ->
  cast_helper(FSM_ID, {chan, CB_ID, T}).

cast(#sm{roles = Roles} = SM, Target_role, T) ->
  case lists:filter(fun({Role,_,_,_,_}) -> Role =:= Target_role end, Roles) of
    [{_,Role_ID,_,_,_}] -> cast_helper(Role_ID, T);
    _ -> error_logger:error_report([{file,?MODULE,?LINE}, {id, ?ID}, "No role", [Target_role, T, Roles]])
  end,
  SM.

cast(#sm{roles = Roles} = SM, #mm{role = Target_role} = MM, EOpts, T, Cond) ->
  case lists:filter(fun({Role,_,_,_,_} = RoleT) -> (Role == Target_role) and Cond(MM,RoleT,EOpts) end, Roles) of
    [{_,Role_ID,_,_,_}] -> cast_helper(Role_ID, T);
    Other -> error_logger:error_report([{file,?MODULE,?LINE}, {id, ?ID}, "No target", [MM, EOpts, T, Other]])
  end,
  SM.

role_available(#sm{roles = Roles}, Target_role) ->
  case lists:filter(fun({Role,_,_,_,_}) -> Role == Target_role end, Roles) of
    [] -> false;
    _ -> true
  end.

cast_helper(Target, Message) ->
  %% gen_event:notify(error_logger, {fsm_cast, self(), {Target, Message}}),
  gen_server:cast(Target, {self(), Message}).

