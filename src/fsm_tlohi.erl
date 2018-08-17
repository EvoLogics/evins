%% Copyright (c) 2018, Oleksiy Kebkal <lesha@evologics.de>
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
-module(fsm_tlohi).
-behaviour(fsm).
%% -compile({parse_transform, pipeline,[{pipeline_verbose, true}]}).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-export([handle_idle/3, handle_alarm/3]).
-export([handle_maybe_blocking/3, handle_blocking/3, handle_contention/3, handle_prepare_backoff/3, handle_backoff/3, handle_send/3, handle_wait_listen/3]).

%%  http://www.eecs.harvard.edu/~mdw/course/cs263/papers/t-lohi-infocom08.pdf
%%  Comparison - http://www.isi.edu/~johnh/PAPERS/Syed08b.pdf
%%
%%  Nodes contend to reserve the channel to send data
%%
%%  Process:
%%  - each frame consists of reservation period (RP), followed by data transfer
%%  - each RP consists of a series of contention rounds (CR)
%%  - if a nodes receives no tones by the end of CR, it wins the contention and ends RP → start sending data
%%  - if multiple nodes compete in CR, each of them will hear the tones of each other and thus will backoff and try again in a later CR
%%  - the CR is long enough to allow nodes to detect (CTD) and count (CTC) contenders
%%  - frame length is provided in the data header → to compute end-of-frame
%%  - backoff_time = one single CR
%%
%%  Abbreviation:
%%  cr  - contention round
%%  rp  - reservation period
%%  ct  - contention tone
%%  ctd - contention detect
%%  ctc - contention counting
%%  Pmax    – the worst case one way propagation-time
%%  Tdetect – tone detection time

%% Events:
%% recvstart
%% ctd - contention detection
%% false_ctd - false contention detection
%% actuacontent
%% listen
%% busy
%% sendok
%% sendend
%% 
%%
%% Timout events:
%% frame_timeout
%% * backoff_timeout
%% * content_timeout
%% answer_timeout

-define(TRANS, [
                {idle
                ,[
                  {recvstart, maybe_blocking},
                  {content, contention},
                  {busy, wait_listen},
                  {ctd, idle},
                  {false_ctd, idle},
                  {sendok, idle},
                  {sendend, idle}
                 ]},
                {maybe_blocking
                ,[
                  {recvstart, maybe_blocking},
                  {busy, maybe_blocking},
                  {ctd, blocking},
                  {false_ctd, idle},
                  {sendok, maybe_blocking},
                  {sendend, maybe_blocking}
                 ]},
                {blocking
                ,[
                  {recvstart, blocking},
                  {busy, blocking},
                  {ctd, blocking},
                  {false_ctd, blocking},
                  {sendok, blocking},
                  {sendend, blocking},
                  {frame_timeout, idle}
                 ]},
                {contention
                ,[
                  {recvstart, contention},
                  {busy, wait_listen},
                  {ctd, prepare_backoff},
                  {false_ctd, contention},
                  {sendok, contention},
                  {sendend, contention},
                  {content_timeout, send}
                 ]},
                {prepare_backoff
                ,[
                  {recvstart, prepare_backoff},
                  {busy, prepare_backoff},
                  {ctd, prepare_backoff},
                  {false_ctd, prepare_backoff},
                  {sendok, prepare_backoff},
                  {sendend, idle},
                  {content_timeout, backoff}
                 ]},
                {backoff
                ,[
                  {recvstart, backoff},
                  {busy, backoff},
                  {ctd, blocking},
                  {false_ctd, backoff},
                  {sendok, backoff},
                  {sendend, backoff},
                  {backoff_timeout, contention}
                 ]},
                {send
                ,[
                  {recvstart, send},
                  {busy, wait_listen},
                  {ctd, send},
                  {false_ctd, send},
                  {sendok, send},
                  {sendend, idle}
                 ]},
                {wait_listen
                ,[
                  {recvstart, wait_listen},
                  {busy, wait_listen},
                  {ctd, wait_listen},
                  {false_ctd, wait_listen},
                  {listen, idle},
                  {sendok, wait_listen},
                  {sendend, wait_listen}
                 ]},
                {alarm
                ,[
                 ]}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

content_detector(_, {async,{recvend,_,_,_,Integrity}}) when Integrity > 90 ->
  ctd;
content_detector(_, _) ->
  false_ctd.

content_actuator(SM, {at,{pid,_},"*SENDIM",_,noack,_}) when SM#sm.state == idle ->
  content;
content_actuator(_, _) ->
  eps.

listen_detector(SM, {sync, "?S", Status}) when SM#sm.state == wait_listen ->
  case string:str(Status, "INITIATION LISTEN") of
    true -> listen;
    _ -> eps
  end;
listen_detector(_, _) ->
  eps.

run_hook_handler(MM, SM, {sync, Cmd, _} = Term, Event) ->
  Handle_cache =
    fun(LSM, nothing) -> LSM;
       (LSM, Next) ->
        [
         share:put(__, cached_command, nothing),
         fsm:send_at_command(__, Next)
        ] (LSM)
    end,
  Handle_cast =
    fun(LSM) when Cmd == "?S" ->
        case share:get(LSM, cast_status) of
          true ->
            share:put(LSM, cast_status, false),
            fsm:cast(LSM, at_impl, {send, Term});
          _ -> LSM
        end;
       (LSM) when Cmd == "*SENDIM" ->
        LSM;
       (LSM) ->
        fsm:cast(LSM, at_impl, {send, Term})
    end,
  [
   Handle_cast(__),
   fsm:clear_timeout(__, answer_timeout),
   Handle_cache(__, share:get(SM, cached_command)),
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ] (SM);
run_hook_handler(MM, SM, Term, Event) ->
  [
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ] (SM).

handle_event(MM, SM, Term) ->
  Pid = share:get(SM, pid),
  case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, at_impl, {send, {async, {error, "ANSWER TIMEOUT"}}});
    {timeout, status_timeout} ->
      fsm:maybe_send_at_command(SM, {at, "?S", ""});
    {timeout, E} when E == frame_timeout; E == content_timeout ->
      run_hook_handler(MM, SM, Term, E);
    {connected} when MM#mm.role == at_impl ->
      case share:get(SM, pid) of
        nothing -> SM;
        Conf_pid ->
          fsm:cast(SM, at_impl, {ctrl, {pid, Conf_pid}})
      end;
    {allowed} when MM#mm.role == at ->
      Conf_pid = share:get(SM, {pid, MM}),
      fsm:broadcast(SM, at_impl, {ctrl, {pid, Conf_pid}}),
      share:put(SM, pid, Conf_pid),
      env:put(SM, connection, allowed);
    {denied} when MM#mm.role == at ->
      share:put(SM, pid, nothing),
      case fsm:check_timeout(SM, answer_timeout) of
        true ->
          [
           fsm:clear_timeout(__, answer_timeout),
           fsm:cast(__, at_impl,  {send, {async, {error, "DISCONNECTED"}}})
          ] (SM);
        _ ->
          SM
      end,
      env:put(SM, connection, denied);
    {at, Cmd, _} when Cmd == "Z"; Cmd == "H" ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {at, Cmd, _} ->
      Handle_cache =
        fun(LSM,blocked) ->
            case share:get(LSM, cached_command) of
              nothing -> share:put(LSM, cached_command, Term);
              _ -> fsm:cast(LSM, at_impl,  {send, {async, {error, "SEQUENCE_ERROR"}}})
            end;
           (LSM, ok) -> LSM
        end,
      case Cmd of
        "?S" -> share:put(SM, cast_status, true);
        _ -> nothing
      end,
      fsm:maybe_send_at_command(SM, Term, Handle_cache);
    {at,{pid,P},"*SENDIM",Dst,noack,Bin} ->
      %% TODO: check whether connected to at
      Hdr = <<0:5,(?FLAG2NUM(data)):3>>, %% TODO: move to nl_mac_hf?
      Tx = {at,{pid,P},"*SENDIM",Dst,noack,<<Hdr/binary,Bin/binary>>},
      share:put(SM, tx, Tx),
      fsm:cast(SM, at_impl,  {send, {sync, "*SENDIM", "OK"}}),
      run_hook_handler(MM, SM, Term, content_actuator(SM, Term));
    %% TODO: add support of other message types
    {at,{pid,_},Cmd,_,_} ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {at,{pid,_},Cmd,_,_,_} ->
      fsm:cast(SM, at_impl,  {send, {sync, Cmd, {error, "NOT SUPPORTED"}}});
    {sync, "?S", _} ->
      run_hook_handler(MM, SM, Term, listen_detector(SM, Term));
    {sync, "*SENDIM", "OK"} ->
      run_hook_handler(MM, SM, Term, sendok);
    {sync, _, {error, _}} ->
      run_hook_handler(MM, SM, Term, eps);
    {sync, _, {busy, _}} ->
      run_hook_handler(MM, SM, Term, busy);
    {sync, _Req, _Answer} ->
      run_hook_handler(MM, SM, Term, eps);
    {async, {pid, Pid}, {recvim, Len, P1, P2, P3, P4, P5, P6, P7, Bin}} ->
      %% TODO: generate tone as <<_:5,1:3>>
      [_, Flag_code, Data, HLen] = nl_mac_hf:extract_payload_mac_flag(Bin),
      Flag = nl_mac_hf:num2flag(Flag_code, mac),
      Extracted = {recvim, Len - HLen, P1, P2, P3, P4, P5, P6, P7, Data},
      case Flag of
        tone -> SM;
        data ->
          fsm:cast(SM, at_impl, {send, {async, {pid, Pid}, Extracted}});
        _ -> ?ERROR(?ID, "Unsupported flag: ~p~n", [Flag]), SM
      end;
    {async,{sendend,_,_,_,_}} ->
      fsm:cast(SM, at_impl, {send, Term}),
      run_hook_handler(MM, SM, Term, sendend);
    {async, {recvstart}} ->
      fsm:cast(SM, at_impl, {send, Term}),
      run_hook_handler(MM, SM, Term, recvstart);
    {async,{recvend,_,_,_,_}} ->
      fsm:cast(SM, at_impl, {send, Term}),
      Event = content_detector(SM, Term),
      run_hook_handler(MM, SM, Term, Event);
    {async, _, _} ->
      fsm:cast(SM, at_impl, {send, Term});
    {async, _} ->
      fsm:cast(SM, at_impl, {send, Term});
    {raw, _Raw} ->
      fsm:cast(SM, at_impl,  {send, {async, {error, "WRONG FORMAT"}}});
    _Other ->
      ?ERROR(?ID, "Unhandled event: ~150p~n", [_Other]),
      SM
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_idle(_MM, SM, _Term) ->
  [
   fsm:clear_timeouts(__, [frame_timeout, backoff_timeout, content_timeout, status_timeout]),
   fsm:set_event(__, eps)
  ] (SM).

handle_maybe_blocking(_MM, SM, _Term) ->
  fsm:set_event(SM, eps).

handle_blocking(_MM, SM, _Term) ->
  case SM#sm.event of
    ctd ->
      Frame = share:get(SM, cr_time),
      [
       fsm:set_event(__, eps),
       fsm:clear_timeout(__, frame_timeout),
       fsm:set_timeout(__, {ms, Frame}, frame_timeout)
      ] (SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_contention(_MM, SM, _Term) ->
  case SM#sm.event of
    E when E == content; E == backoff_timeout ->
      share:put(SM, ctc, 0),
      Pid = share:get(SM, pid),
      Hdr = <<0:5,(?FLAG2NUM(tone)):3>>, %% TODO: move to nl_mac_hf?
      Term = {at,{pid,Pid},"*SENDIM",255,noack,Hdr},

      Transmittion_handler =
        fun(LSM, blocked) -> fsm:set_event(LSM, busy);
           (LSM, ok) ->
            CR = share:get(SM, cr_time),
            [
             fsm:clear_timeout(__, content_timeout),
             fsm:set_timeout(__, {ms, CR}, content_timeout),
             fsm:set_event(__, eps)
            ] (LSM)
        end,
      fsm:maybe_send_at_command(SM, Term, Transmittion_handler);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_prepare_backoff(_MM, SM, _Term) ->
  case SM#sm.event of
    ctd ->
      share:update_with(SM, ctc, fun(I) -> I + 1 end, 0),
      fsm:set_event(SM, eps);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_backoff(_MM, SM, _Term) ->
  case SM#sm.event of
    content_timeout ->
      CTC = share:get(SM, nothing, ctc, 1),
      CR = share:get(SM, cr_time),
      R = rand:uniform(CTC * CR),
      [
       fsm:set_timeout(__, {ms, R}, backoff_timeout),
       fsm:set_event(__, eps)
      ] (SM);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_send(_MM, SM, _Term) ->
  TX = share:get(SM, tx),
  case SM#sm.event of
    content_timeout when TX == nothing ->
      fsm:set_event(SM, sendend);
    content_timeout ->
      Transmittion_handler =
        fun(LSM, blocked) -> fsm:set_event(LSM, busy);
           (LSM, ok) ->
            share:clean(SM, tx),
            fsm:set_event(LSM, eps)
        end,
      fsm:maybe_send_at_command(SM, TX, Transmittion_handler);
    _ ->
      fsm:set_event(SM, eps)
  end.

handle_wait_listen(_MM, SM, _Term) ->
  case SM#sm.event of
    busy ->
      [
       fsm:maybe_send_at_command(__, {at, "?S", ""}),
       fsm:set_interval(__, {s, 1}, status_timeout),
       fsm:set_event(__, eps)
      ] (SM);
    _ ->
      fsm:set_event(SM, eps)
  end.
