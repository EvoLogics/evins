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
-module(fsm_conf).
-behaviour(fsm).

-include("../include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_request_mode/3, handle_handle_modem/3,
         handle_request_local_address/3, handle_request_max_address/3,
         handle_handle_max_address/3, handle_handle_yar/3, handle_final/3,
         handle_request_pid/3, handle_handle_pid/3]).

-define(EMSG, <<"ERROR WRONG FORMAT\r\n">>).

%% states 
%% idle | alarm | request_mode | handle_modem | request_local_address | request_max_address | handle_yar
%% | handle_max_address | final

%% events:
%% eps | internal | answer_timeout | error | rcv | wrong_receive | final | yet_another_request

%% restrict framework to work only with options: {version, '1.8'}, {ext_networking, enabled}, {ext_notifications, enabled}, {usbl, enabled}!
%% AT@ZF1, AT@ZX1, AT@ZU1 (1.8, if AT@ZF1 answer is OK) 

-define(TRANS, [
                {idle, 
                 [{internal, idle},
                  {rcv, request_local_address},
                  {error, request_mode},
                  {answer_timeout, idle}
                 ]},

                {alarm, 
                 [{final, alarm}
                 ]},

                {request_mode,
                 [{rcv, handle_modem},
                  {answer_timeout, alarm}
                 ]},

                {handle_modem,
                 [{internal, request_local_address},
                  {wrong_receive, request_mode}
                 ]},

                {request_local_address,
                 [{rcv, request_max_address},
                  {wrong_receive, idle},
                  {answer_timeout, alarm}
                 ]},

                {request_max_address,
                 [{rcv, handle_max_address},
                  {wrong_receive, request_local_address},
                  {answer_timeout, alarm}
                 ]},

                {handle_max_address,
                 [{wrong_receive, request_max_address},
                  {yet_another_request, request_pid},
                  {final, final}
                 ]},

                {request_pid,
                 [{rcv, handle_pid},
                  {answer_timeout, alarm},
                  {wrong_receive, alarm}
                 ]},

                {handle_pid,
                 [{wrong_receive, alarm},
                  {yet_another_request, handle_yar},
                  {final, final}
                 ]},

                {handle_yar,
                 [{yet_another_request, handle_yar},
                  {wrong_receive, handle_yar},
                  {rcv, handle_yar},
                  {answer_timeout, alarm},
                  {final, final}
                 ]},

                {final,
                 [{internal, idle}]}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  share:put(SM, raw_buffer, <<"">>), SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  case Term of
    {sync,_Req,_Answer} when SM#sm.state == final ->
      SM;
    {sync,Req,Answer} -> 
      case Answer of
        S when is_list(S) ->
          fsm:run_event(MM, SM#sm{event=rcv}, Term);
        {error,"WRONG FORMAT"} when Req == "@ZA" ->
          %% for compatibility with 1.8 firmware
          fsm:run_event(MM, SM#sm{event=rcv}, {sync, Req, "OK"});
        {error, _}        ->
          fsm:run_event(MM, SM#sm{event=error}, Term)
      end;
    {timeout,Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {async,_,_} ->
      SM;
    {async,_} -> 
      SM;
    {error,Reason} ->
      ?WARNING(?ID, "error ~p~n", [Reason]),
      exit(Reason);
    {disconnected, _} ->
      fsm:cast(SM, at, {ctrl, {allow, self()}}),
      fsm:cast(SM, at, {ctrl, {filter, at}}),
      fsm:cast(SM, at, {ctrl, {mode, data}}),
      fsm:cast(SM, at, {ctrl, {waitsync, no}});
    {connected} ->
      fsm:cast(SM, at, {ctrl, {allow, self()}}),
      fsm:run_event(MM, SM#sm{event=internal}, {});
    {raw,<<"NET\r\n">>} ->
      %% special case for at/at_impl docking
      share:put(SM, raw_buffer, <<"">>),
      SM1 = fsm:cast(SM, at, {ctrl, {waitsync, no}}),
      fsm:run_event(MM, SM1#sm{event=error}, {});
    {raw,Bin} when SM#sm.state == idle ->
      Raw_buffer = share:get(SM,raw_buffer),
      Buffer = <<Raw_buffer/binary,Bin/binary>>,
      case match_message(Buffer,?EMSG) of
        {ok,_,_} ->
          %% force to clean waitsync state
          share:put(SM, raw_buffer, <<"">>),
          SM1 = fsm:cast(SM, at, {ctrl, {waitsync, no}}),
          fsm:run_event(MM, SM1#sm{event=error}, {});
        {more,_,Match_size} ->
          Part = binary:part(Buffer,{byte_size(Buffer),-Match_size}),
          share:put(SM, raw_buffer, Part),
          ?INFO(?ID, "Partially matched part: ~p~n", [Part]),
          SM
      end;
    {raw,_} ->
      SM;
    _Other ->
      ?ERROR(?ID, "Unhandled event: ~150p~n", [_Other]),
      SM
  end.

match_message(Bin,Msg) when is_binary(Bin), is_binary(Msg) ->
  match_message_helper(binary_to_list(Bin),binary_to_list(Msg),binary_to_list(Msg),0,0).

match_message_helper([],_,Msg,Match_size,Unmatch_offset) when length(Msg) == Match_size ->
  {ok,Unmatch_offset,Match_size};
match_message_helper([],_,_,Match_size,Unmatch_offset) ->
  {more,Unmatch_offset,Match_size};
match_message_helper(_,[],_,Match_size,Unmatch_offset) ->
  %% some async data after Msg
  {ok,Unmatch_offset,Match_size};
  %% match_message_helper(Bin,Msg,Msg,0,Unmatch_offset+Match_size);
match_message_helper([First|Bin_tail],[First|Msg_tail],Msg,Match_size,Unmatch_offset) ->
  match_message_helper(Bin_tail,Msg_tail,Msg,Match_size+1,Unmatch_offset);
match_message_helper(Bin,_,Msg,0,Unmatch_offset) ->
  match_message_helper(tl(Bin),Msg,Msg,0,Unmatch_offset+1);
match_message_helper(Bin,_,Msg,Match_size,Unmatch_offset) ->
  match_message_helper(Bin,Msg,Msg,0,Unmatch_offset+Match_size).

handle_idle(_MM, #sm{event = Event} = SM, _Term) ->
  case Event of
    internal      ->
      %% must be run optionally!
      share:put(SM, yars, [{at,"@ZF","1"},{at, "@ZX","1"},{at,"@ZU","1"},{at,"@ZA","1"}]),
      AT = {at, "?MODE", ""},
      fsm:set_event(
        fsm:set_timeout(
          fsm:cast(fsm:clear_timeouts(SM), at, {send, AT}), ?WAKEUP_TIMEOUT, answer_timeout), eps);
    answer_timeout ->
      fsm:cast(SM, at, {ctrl, {waitsync, no}}),
      fsm:send_at_command(SM, {at, "?MODE", ""});
    wrong_receive -> fsm:set_event(SM, eps);
    _             -> fsm:set_event(SM#sm{state = alarm}, internal)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_request_mode(_MM, SM, _Term) ->
  case SM#sm.event of
    error ->
      SM1 = fsm:cast(SM, at, {ctrl, {mode, command}}),
      fsm:send_at_command(fsm:clear_timeouts(SM1), {at, "?MODE", ""});
    _     -> SM#sm{event = internal, state = alarm}
  end.

handle_handle_modem(_MM, SM, Term) ->
  case {SM#sm.event, Term} of
    {rcv, {sync, "?MODE", "AT"}} ->
      SM1 = fsm:send_at_command(SM, {at, "O", ""}),
      fsm:cast(SM1#sm{event = internal}, at, {ctrl, {mode, data}});
    {rcv, {sync, "?MODE", "NET"}} ->
      fsm:cast(SM#sm{event = internal}, at, {ctrl, {filter, net}});
    {rcv, {sync, _, _}} -> SM#sm{event = wrong_receive};
    _                   -> SM#sm{event = internal, state = alarm}
  end.

handle_request_local_address(_MM, SM, _Term) ->
  case SM#sm.event of
    Event when Event =:= internal; Event =:= rcv ->
      fsm:send_at_command(fsm:clear_timeouts(SM), {at, "?AL", ""});
    wrong_receive -> SM#sm{event = eps};
    _             -> SM#sm{event = internal, state = alarm}
  end.

handle_request_max_address(_MM, SM, Term) ->
  case {SM#sm.event, Term} of
    {rcv, {sync, "?AL", Answer}} when is_list(Answer) ->
      share:put(SM, local_address, list_to_integer(Answer)),
      %% todo: сохранение параметра
      fsm:send_at_command(fsm:clear_timeouts(SM), {at, "?AM", ""});
    {rcv, {sync, _, _}} -> SM#sm{event = wrong_receive};
    _                   -> SM#sm{event = internal, state = alarm}
  end.

handle_handle_max_address(_MM, SM, Term) ->
  case {SM#sm.event, Term} of
    {rcv, {sync, "?AM", Answer}} when is_list(Answer) ->
      share:put(SM, max_address, list_to_integer(Answer)),
      fsm:clear_timeouts(SM#sm{event = yet_another_request});
    {rcv, {sync, _, _}} -> SM#sm{event = wrong_receive};
    _                   -> SM#sm{event = internal, state = alarm}
  end.

handle_request_pid(_MM, SM, Term) ->
  case {SM#sm.event, Term} of
    {yet_another_request, _} ->
      fsm:send_at_command(SM#sm{event = eps}, {at, "?PID", ""});
    _                   -> SM#sm{event = internal, state = alarm}
  end.

handle_handle_pid(MM, SM, Term) ->
  case {SM#sm.event, Term} of
    {rcv, {sync, "?PID", Answer}} when is_list(Answer) ->
      share:put(SM, {pid, MM}, list_to_integer(Answer)),
      fsm:clear_timeouts(SM#sm{event = yet_another_request});
    {rcv, {sync, _, _}} -> SM#sm{event = wrong_receive};
    _                   -> SM#sm{event = internal, state = alarm}
  end.

handle_handle_yar(_MM, SM, Term) ->
  case {SM#sm.event, Term} of
    {yet_another_request, _} ->
      L = share:get(SM, yars),
      case L of
        [] -> SM#sm{event = final};
        nothing -> SM#sm{event = final};
        _ ->
          share:put(SM, yars, tl(L)),
          fsm:send_at_command(fsm:clear_timeouts(SM), hd(L))
      end;
    {rcv, {sync, _, "OK"}} -> SM#sm{event = yet_another_request};
    {rcv, {sync, _, _}}    -> SM#sm{event = wrong_receive};
    _                      -> SM#sm{event = internal, state = alarm}
  end.

handle_final(_MM, SM, _Term) ->
  fsm:cast(SM, at, {ctrl, {allow, all}}),
  fsm:clear_timeouts(SM#sm{event = eps}).
