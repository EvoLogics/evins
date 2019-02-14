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

-module(fsm_get_multipath).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, init_event/0]).
-export([init/1,final/0,handle_event/3,stop/1]).
-export([handle_idle/3, handle_alarm/3, handle_recv/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {recvim, recv}
                 ]},

                {recv,
                 [{sync, idle},
                  {recvim, recv}
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

handle_event(MM, SM, Term) ->
  case Term of
    {timeout, {retry_get_multipath, Event_params}} ->
      fsm:run_event(MM, SM#sm{event=recvim}, Event_params);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {async, _PID, {recvim,_,Src,Dst,_,_,_,_,_,_}} ->
      fsm:run_event(MM, SM#sm{event = recvim}, {recvim, {Src, Dst}});
    {sync, "?P", Answer} ->
      get_multipath(SM, Term, Answer);
    {sync, _Req, _Asw} ->
      SM1 = fsm:clear_timeout(SM, answer_timeout),
      fsm:run_event(MM, SM1#sm{event = sync}, {});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _Term) ->
  fsm:set_event(SM, eps).

handle_recv(_MM, SM, Term) ->
  [Event_params, SMP] = mac_hf:event_params(SM, Term, recvim),
  case SM#sm.event of
    recvim ->
      fsm:set_timeout(SM#sm{event = eps}, {s, 1}, {retry_get_multipath, Event_params});
    _ ->
      send_multipath(SMP, Event_params)
end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

try_send_at_command(SM, AT) ->
  case fsm:check_timeout(SM, answer_timeout) of
    true ->
      SM;
    _ ->
      fsm:send_at_command(SM, AT)
  end.

send_multipath(SM, Tuple) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  if Answer_timeout == false ->
    SMT = SM#sm{event_params = Tuple},
    try_send_at_command(SMT, {at, "?P", ""});
  true -> SM
  end.

get_multipath(SM, Term, Answer) ->
  SMAT = fsm:clear_timeout(SM, answer_timeout),
  [Event_params, SMP] = mac_hf:event_params(SMAT, Term, recvim),
  case Event_params of
    {recvim, {Src, Dst}} ->
      ?TRACE(?ID, "Multipath src ~p dst ~p : ~p~n", [Src, Dst, Answer]);
    _ -> nothing
  end,
  SMP.
