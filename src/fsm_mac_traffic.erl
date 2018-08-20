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
-module(fsm_mac_traffic).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  share:put(SM, txgen, 0),
  share:put(SM, txcnt, 0).
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

%% TODO: put it to some library 
safe_binary_to_float(B) ->
  case (catch binary_to_float(B)) of
    V when is_number(V) -> V;
    _ ->
      try float(binary_to_integer(B))
      catch _:_ -> nothing end
  end.

safe_binary_to_float(B,Default) ->
  case safe_binary_to_float(B) of
    nothing -> Default;
    Value -> Value
  end.

inc_counter(SM, Name) ->
  share:update_with(SM, Name, fun(I) -> I + 1 end, 0).

inc_counter(SM, Name, Id) ->
  share:update_with(SM, Name, Id, fun(I) -> I + 1 end, 0).

read_counter(SM, Name) ->
  share:get(SM, nothing, Name, 0).

%% read_counter(SM, Name, Id) ->
%%   share:get(SM, Name, Id, 0).

clean_statistics(SM) ->
  io:format("clean stat~n"),
  [share:clean(SM,Key) || Key <- [txcnt, txgen, rxcnt, rxevents]],
  SM.

generate_report(SM) ->
  L = share:get(SM, packet_size),
  S = erlang:monotonic_time(seconds),
  LA = share:get(SM, local_address),
  RT = share:get(SM, run_start),
  Dur = share:get(SM, run_duration),
  io:format("Dur: ~p, S: ~p, RT: ~p~n", [Dur, S, RT]),
  RXLst = lists:sort(share:match(SM, {{rxcnt,'$1'},'$2'})),
  io:format("RXLst: ~p~n", [RXLst]),
  RXEvents = read_counter(SM, rxevents),
  Status = case fsm:check_timeout(SM, run_timeout) of
             true ->
               io_lib:format("Running ~p from ~p seconds, timestamp: ~p seconds~n", [Dur - (S-RT), Dur, S]);
             _ ->
               "Idle\n"
           end,
  Report =
    lists:flatten(
      [
       Status,
       io_lib:format("address: ~150p, rate: ~150p, len: ~150p, generated: ~150p, transmitted: ~150p, triggered: ~150p, received: ~150p, duration: ~150p~n",
                     [LA, share:get(SM, rate), L, read_counter(SM, txgen), read_counter(SM, txcnt),
                      RXEvents, lists:sum([RXCnt || [_,RXCnt] <- RXLst]), Dur]),
       [io_lib:format("RX: id: ~p, received: ~p~n",[ID,RXCnt]) || [ID,RXCnt] <- RXLst]
      ]),
  fsm:broadcast(SM,scli,{send, {string, Report}}),
  fsm:broadcast(SM,scli,{send, {prompt}}).

%% commands fo scli
%% clear - clear statistics
%% run <x> - run <x> seconds
%% stat - output statistics
%% stop - stop experiment
%% set <key> <value>

%% TODO: measure channel utilisation
%% TODO: measure fairness

%% time unit for rate is 1 second
next_time(SM) ->
  Rate = share:get(SM, rate),
  -math:log(1.0 - rand:uniform()) / Rate.

send_next_packet(SM) ->
  case fsm:check_timeout(SM, run_timeout) of
    true ->
      L = share:get(SM, packet_size),
      PID = share:get(SM, pid),
      Payl = list_to_binary(lists:seq(1,L)),
      AT = {at,{pid,PID},"*SENDIM",255,noack,Payl},
      fsm:maybe_send_at_command(SM, AT);
    _ ->
      ?INFO(?ID, "test is not running~n", []),
      SM
  end.

handle_event(MM, SM, Term) ->
  case Term of
    {timeout, run_timeout} ->
      [
       generate_report(__),
       fsm:clear_timeout(__, run_timeout)
      ] (SM);
    {timeout, next_time} ->
      T = next_time(SM),
      [
       send_next_packet(__), %% sends only if run_timeout is active
       fsm:clear_timeout(__, next_time),
       fsm:set_timeout(__, {s, T}, next_time)
      ] (SM);
    B when is_binary(B) ->
      %% command via scli
      case B of
        <<"">> ->
          fsm:broadcast(SM,scli,{send, {prompt}});
        <<"clear">> ->
          [
           clean_statistics(__),
           fsm:broadcast(__,scli,{send, {string, "ok"}}),
           fsm:broadcast(__,scli,{send, {prompt}})
          ] (SM);
        <<"stat">> ->
          generate_report(SM);
        <<"run ",Param/binary>> ->
          Duration = binary_to_integer(Param),
          share:put(SM,[
                        {run_start, erlang:monotonic_time(seconds)},
                        {run_duration, Duration}]),
          [
           clean_statistics(__),
           fsm:set_timeout(__, {s, Duration}, run_timeout),
           fsm:broadcast(__,scli,{send, {prompt}})
          ] (SM);
        <<"stop">> ->
          [
           fsm:clear_timeout(__, run_timeout),
           fsm:broadcast(__,scli,{send, {string, "ok"}}),
           fsm:broadcast(__,scli,{send, {prompt}})
          ] (SM);
        <<"set",Param/binary>> ->
          case re:split(Param, " +") of
            [_,BKey,BValue] ->
              Key = erlang:binary_to_atom(BKey,utf8),
              Value = safe_binary_to_float(BValue,0.0),
              case Key of
                rate when Value >= 0.001 ->
                  share:put(SM, Key, Value);
                _ ->
                  fsm:broadcast(SM,scli,{send, {string, "error: wrong parameters to set"}})
              end;
            _ ->
              fsm:broadcast(SM,scli,{send, {string, "error: exactly 2 parameters required"}})
          end,
          fsm:broadcast(SM,scli,{send, {prompt}});
        _ ->
          [
           fsm:broadcast(__,scli,{send, {string, "unknown command"}}),
           fsm:broadcast(__,scli,{send, {prompt}})
          ] (SM)
      end;
    {sync, "*SENDIM", "OK"} ->
      [
       inc_counter(__, txgen),
       fsm:clear_timeout(__, answer_timeout)
      ] (SM);
    {async, {sendstart,_,_,_,_}} ->
      inc_counter(SM, txcnt);
    {async, {recvstart}} ->
      inc_counter(SM, rxevents);
    %% FIXME: auto_lohi: why recvim with tone lohi is passed to the upper layer
    {async, _, {_,_,Src,_,_,_,_,_,_,Payl}} ->
      case {size(Payl),share:get(SM, packet_size)} of
        {L1,L2} when L1 == L2 ->
          inc_counter(SM, rxcnt, Src),
          RXLst = lists:sort(share:match(SM, {{rxcnt,'$1'},'$2'})),
          io:format("RXLst: ~p~n", [RXLst]),
          SM;
        _Other ->
          SM
      end;
    {allowed} ->
      Conf_pid = share:get(SM, {pid, MM}),
      share:put(SM, pid, Conf_pid),
      fsm:set_timeout(SM, {s, next_time(SM)}, next_time);
    {denied} ->
      share:put(SM, pid, nothing),
      fsm:clear_timeout(SM, next_time);
    {connected} when MM#mm.role == scli ->
      fsm:broadcast(SM,scli,{send, {prompt}});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.
