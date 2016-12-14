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
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, init_event/0]).
-export([init/1,final/0,handle_event/3,stop/1]).
-export([handle_idle/3, handle_alarm/3, handle_sense/3, handle_transmit/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {answer_timeout, idle},
                  {send_data, transmit},
                  {backoff, transmit},
                  {sendend, idle},
                  {recvend, idle},
                  {sendstart, sense},
                  {recvstart, sense}
                 ]},

                {transmit,
                 [{data_sent, idle}
                 ]},

                {sense,
                 [{answer_timeout, sense},
                  {backoff, sense},
                  {send_data, sense},
                  {sendstart, sense},
                  {recvstart, sense},
                  {sendend, idle},
                  {recvend, idle}
                 ]},

                {alarm,[]}
               ]).

start_link(SM) ->
  [
   env:put(__,got_sync,true),   
   fsm:start_link(__)
  ] (SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> internal.
stop(_SM)      -> ok.

handle_event(MM, #sm{env = #{got_sync := Got_sync}} = SM, Term) ->
  case Term of
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {send_data, _} when Got_sync ->
      fsm:run_event(MM, SM#sm{event=send_data}, Term);
    {send_data, _} ->
      fsm:cast(SM, triv_alh, {send, {string, "ERROR SYNC\n"} });
    {async, _PID, {recvim,_,_,_,_,_,_,_,_, Payl}} ->
      fsm:cast(SM, triv_alh, {send, {binary, list_to_binary([Payl,"\n"])} });
    {async, Tuple} when is_tuple(Tuple) ->
      Event = element(1, Tuple),
      case lists:member(Event, [sendstart, sendend, recvstart, recvend]) of
        true -> fsm:run_event(MM, SM#sm{event = Event},{});
        _ -> SM
      end;
    {sync, _Req, _Asw} ->
      env:put(SM, got_sync, true);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _Term) ->
  case SM#sm.event of
    internal ->
      [
       env:put(__, got_sync, true),       
       init_backoff_step(__),
       fsm:set_event(__, eps)
      ] (SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_sense(_MM, SM, Term) ->
  case Term of
    {send_data, P} ->
      Cmd =
        case fsm:check_timeout(SM, backoff) of
          false ->
            increment;
          true ->
            fsm:cast(SM, triv_alh, {send, {string, "OK\n"} }),
            nothing
        end,
      [
       update_backoff(__, Cmd),
       env:put(__, delayed_msg, P),
       fsm:set_event(__, eps)
      ] (SM);
    _ when SM#sm.event =:= backoff ->
      [
       update_backoff(__, increment),
       fsm:set_event(__, eps)
      ] (SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_transmit(_MM, #sm{event = Event} = SM, Term) ->
  Payl =
    case Term of
      {send_data, P}          -> P;
      _ when Event == backoff -> env:get(SM, delayed_msg)
    end,
  [
   env:put(__,got_sync,false),   
   fsm:clear_timeout(__, backoff),
   update_backoff(__, decrement),
   fsm:send_at_command(__, {at,{pid,0},"*SENDIM",255,noack,Payl}),
   fsm:set_event(__, data_sent)
  ] (SM).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

%%--------------------------------------Helper functions--------------------------------------------------
init_backoff_step(SM)->
  env:put(SM, step, 0).  % 2 ^ 0

update_backoff_step(SM, Backoff, _) when Backoff < 1 ->
  init_backoff_step(SM);
update_backoff_step(SM, Backoff, Step) when (Backoff =< 200) and (Backoff >= 0) ->
  env:put(SM, step, Step);
update_backoff_step(SM, Backoff, Step) when Backoff > 200 ->
  env:put(SM, step, Step - 1).

set_backoff_timeout(SM) -> 
  Backoff = math:pow(2, env:get(SM, step)),
  fsm:set_timeout(SM, {s, Backoff}, backoff).

update_backoff(SM, nothing) ->
  SM;
update_backoff(SM, decrement) ->
  Prev_step = env:get(SM, step),
  Step = case ( Prev_step - 1 > 0 ) of true -> Prev_step - 1; false -> 0 end,
  update_backoff_step(SM, math:pow(2, Step), Step);
update_backoff(SM, increment) ->
  Step = env:get(SM, step) + 1,
  Backoff = math:pow(2, Step),
  [
   update_backoff_step(__, Backoff, Step),
   set_backoff_timeout(__)
  ] (SM).
