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
%%
%% Simple inverted USBL module
-module(fsm_siusbl).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-define(TRANS, []).
-define(MODE,xyz).
%% -define(MODE,enu).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  Env = maps:merge(SM#sm.env, #{mode => ?MODE}),
  SM#sm{env = Env}.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(_MM, SM, Term) ->
  ?INFO(?ID, "Term: ~p~n", [Term]),
  case Term of
    {allowed} ->
      fsm:cast(SM, at, {send, {at, "?S", ""}}),
      fsm:send_at_command(SM, encode_sendim(SM));
    {disconnected, _} ->
      fsm:clear_timeouts(SM);
    {timeout, answer_timeout} ->
      fsm:send_at_command(SM, encode_sendim(SM));
    {async, {Report, _}} when Report == deliveredim; Report == failedim ->
      fsm:send_at_command(SM, encode_sendim(SM));
    {async, {usbllong,_,_,Src,X,Y,Z,E,N,U,_,_,_,_,_,_,_}} ->
      Env = maps:merge(SM#sm.env, #{position => {Src,X,Y,Z,E,N,U}}),
      SM#sm{env = Env};
    _UUg ->
      ?TRACE(?ID, "Unhandled event: ~p~n", [_UUg]),
      SM
  end.

encode_sendim(SM) ->
  #{target := Target} = SM#sm.env,
  Payload = encode_position(SM),
  {at, {pid,0}, "*SENDIM", Target, ack, Payload}.

encode_position(#sm{env = #{mode := xyz, position := {_,Xm,Ym,Zm,_,_,_}}}) ->
  [X, Y, Z] = [round(V*10) || V <- [Xm,Ym,Zm]],
  <<"X", X:16/little, Y:16/little, Z:16/little>>;
encode_position(#sm{env = #{mode := enu, position := {_,_,_,_,Em,Nm,Um}}}) ->
  [E, N, U] = [round(V*10) || V <- [Em,Nm,Um]],
  <<"E", E:16/little, N:16/little, U:16/little>>;
encode_position(_) ->
  <<"N">>.

