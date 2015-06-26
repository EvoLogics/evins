%% Copyright (c) 2015, Veronika Kebkal <veronika.kebkal@evologics.de>
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
-module(fsm_triv_alh).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3, handle_alarm/3, handle_sp/3, handle_write_alh/3, handle_final/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {answer_timeout, idle},
                  {send_data, write_alh},
                  {backoff, write_alh},
                  {sendend, idle},
                  {recvend, idle},
                  {sendstart, sp},
                  {recvstart, sp}
                 ]},

                {write_alh,
                 [{data_sent, idle}
                 ]},

                {sp,
                 [{answer_timeout, sp},
                  {backoff, sp},
                  {send_data, sp},
                  {sendstart, sp},
                  {recvstart, sp},
                  {sendend, idle},
                  {recvend, idle}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------Handler Event----------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT~n", []),
  ?TRACE(?ID, "~p~n", [Term]),
  Got_sync = readETS(SM, got_sync),
  case Term of
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    T={send_data, _P} when Got_sync ->
      fsm:run_event(MM, SM#sm{event=send_data}, T);
    {send_data, _P} ->
      fsm:cast(SM, triv_alh, {send, {string, "ERROR SYNC\n"} }),
      SM;
    {async, _PID, {recvim,_,_,_,_,_,_,_,_, Payl}} ->
      fsm:cast(SM, triv_alh, {send, {binary, list_to_binary([Payl,"\n"])} }),
      SM;
    {async, Tuple} ->
      case Tuple of
        {sendstart,_,_,_,_} ->
          fsm:run_event(MM, SM#sm{event=sendstart},{});
        {sendend,_,_,_,_} ->
          fsm:run_event(MM, SM#sm{event=sendend},{});
        {recvstart} ->
          fsm:run_event(MM, SM#sm{event=recvstart},{});
        {recvend,_,_,_,_} ->
          fsm:run_event(MM, SM#sm{event=recvend},{});
        _ ->
          SM
      end;
    {sync, _Req, _Asw} ->
      insertETS(SM, got_sync, true),
      SM;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

%%--------------------------------Handler functions-------------------------------
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case SM#sm.event of
    internal ->
      insertETS(SM, got_sync, true),
      init_backoff(SM);
    _ ->
      nothing
  end,
  SM#sm{event = eps}.

handle_sp(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_sp ~120p~n", [Term]),
  case Term of
    {send_data, P} ->
      insertETS(SM, current_msg, P),
      case fsm:check_timeout(SM, backoff) of
        false ->
          Backoff_tmp = change_backoff(SM, increment),
          fsm:set_timeout(SM#sm{event=eps}, {s, Backoff_tmp}, backoff);
        true  ->
          fsm:cast(SM, triv_alh, {send, {string, "OK\n"} }),
          SM#sm{event = eps}
      end;
    _ when SM#sm.event =:= backoff ->
      Backoff_tmp = change_backoff(SM, increment),
      fsm:set_timeout(SM#sm{event=eps}, {s, Backoff_tmp}, backoff);
    _ ->
      SM#sm{event = eps}
  end.

handle_write_alh(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM1 = fsm:clear_timeout(SM, backoff),
  change_backoff(SM, decrement),
  insertETS(SM, got_sync, false),
  Payl =
  case Term of
    {send_data, P} ->
      P;
    _ when SM1#sm.event =:= backoff ->
      readETS(SM1, current_msg)
  end,
  fsm:send_at_command(SM1, {at,{pid,0},"*SENDIM",255,noack,Payl}),
  SM1#sm{event = data_sent}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions--------------------------------------------------
init_backoff(SM)->
  insertETS(SM, current_step, 0). % 2 ^ 0

check_limit(SM, Current_Backoff, Current_Step) ->
  case Current_Backoff of
    Current_Backoff when ((Current_Backoff =< 200) and (Current_Backoff >= 1)) ->
      Current_Step;
    Current_Backoff when (Current_Backoff > 200) ->
      Current_Step - 1;
    Current_Backoff when (Current_Backoff < 1) ->
      init_backoff(SM)
  end.

change_backoff(SM, Type) ->
  Exp = readETS(SM, current_step),
  Current_Step =
  case Type of
    increment -> Exp + 1;
    decrement -> case ( Exp - 1 > 0 ) of true -> Exp - 1; false -> 0 end
  end,
  Current_Backoff = math:pow(2, Current_Step),
  NewStep= check_limit(SM, Current_Backoff, Current_Step),
  insertETS(SM, current_step, NewStep),
  math:pow(2, readETS(SM, current_step)).

%%---------------------------------------ETS functions ---------------------------------------------------
insertETS(SM, Term, Value) ->
  cleanETS(SM, Term),
  case ets:insert(SM#sm.share, [{Term, Value}]) of
    true  -> SM;
    false -> insertETS(SM, Term, Value)
  end.

readETS(SM, Term) ->
  case ets:lookup(SM#sm.share, Term) of
    [{Term, Value}] -> Value;
    _ -> not_inside
  end.

cleanETS(SM, Term) ->
  ets:match_delete(SM#sm.share, {Term, '_'}).
