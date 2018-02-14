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
-module(fsm_move).
-behaviour(fsm).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-export([handle_idle/3, handle_moving/3, handle_alarm/3]).

-import(geometry, [ecef2geodetic/1, ned2ecef/2, enu2ecef/2]).

-define(TRANS, [
                {idle,
                 [{initial,idle},
                  {internal, moving}
                 ]},
                {moving,
                 [{tide, moving},
                  {brownian, moving},
                  {circle, moving},
                  {rocking, moving},
                  {stationary, moving}
                 ]},
                {alarm,
                 []}]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  P = [0,0,0],
  share:put(SM, tail, {tail, [P,P,P], 0.0,math:pi()/2,0.0}),
  share:put(SM, ahrs, {ahrs, [0,0,0]}),
  SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> initial.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  case Term of
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {disconnected, _} ->
      SM;
    _ ->
      ?ERROR(?ID, "Unhandle event: ~p~n", [Term]),
      SM
  end.

handle_idle(_MM, #sm{event = Event} = SM, _Term) ->
  case Event of
    initial -> 
      MS = [share:get(SM, T) || T <- [movement, tide, rocking]],
      ?TRACE(?ID, "MS: ~p~n", [MS]),
      lists:foldl(fun(M,SM_acc) ->
                      case M of
                        {tide, Tau, _Pr, _Amp, _Phy, _Period} -> fsm:set_interval(SM_acc, {ms, Tau}, tide);
                        {stationary, _, _, _} -> fsm:set_timeout(SM_acc, {ms, 1}, stationary);
                        {stationary, _, _, _, Tau} -> fsm:set_interval(SM_acc, {ms, Tau}, stationary);
                        {circle, _C, _R, _V, Tau, _Phy} -> fsm:set_interval(SM_acc, {ms, Tau / share:get(SM, decim)}, circle);
                        {brownian,Tau,_,_,_,_,_,_,_,_,_} -> fsm:set_interval(SM_acc, {ms, Tau}, brownian);
                        {rocking, Tau} -> fsm:set_interval(SM_acc, {ms, Tau}, rocking);
                        _ ->
                          ?TRACE(?ID, "Hmmm: ~p~n", [M]),
                          SM_acc
                      end
                  end, fsm:set_event(SM,internal), lists:filter(fun(M) -> M /= [] end, MS));
    _ ->
      fsm:set_event(SM#sm{state = alarm}, internal)
  end.

handle_moving(_MM, #sm{event = Event} = SM, _Term) ->
  case Event of
    internal ->
      fsm:set_event(SM, eps);
    tide ->
      %% Depth in meters
      {tide, Tau, Depth, A, Phy, Period} = share:get(SM, tide),
      Phy1 = Phy + 2*math:pi()*Tau/Period,
      Depth1 = Depth + A * math:sin(Phy1),
      share:put(SM, tide, {tide, Tau, Depth, A, Phy1, Period}),
      DBS = {dbs, Depth1},
      fsm:broadcast(SM, pressure, {send, {nmea, DBS}}),
      fsm:broadcast(fsm:set_event(SM, eps), nmea, {send, {nmea, DBS}});
    stationary ->
      P = case share:get(SM, movement) of
            {stationary, X, Y, Z, _Tau} -> [X, Y, Z];
            {stationary, X, Y, Z} -> [X, Y, Z]
          end,
      broadcast_position(SM, P),
      fsm:set_event(SM, eps);
    circle ->
      {circle, C, R, V, Tau, Phy} = share:get(SM, movement),
      {XO, YO, ZO} = C,
      Phy1 = Phy + V*(Tau/1000/share:get(SM, decim))/R,
      %% X,Y,Z in ENU reference frame
      Xn = XO + R * math:cos(Phy1),
      Yn = YO + R * math:sin(Phy1),
      Zn = ZO,
      broadcast_position(SM, [Xn,Yn,Zn]),
      share:put(SM, movement, {circle, C, R, V, Tau, Phy1}),
      fsm:set_event(SM, eps);
    brownian ->
      {brownian, Tau, XMin, YMin, ZMin, XMax, YMax, ZMax, X, Y, Z} = share:get(SM, movement),
      Xn = geometry:brownian_walk(XMin, XMax, X),
      Yn = geometry:brownian_walk(YMin, YMax, Y),
      Zn = geometry:brownian_walk(ZMin, ZMax, Z),
      broadcast_position(SM, [Xn,Yn,Zn]),
      share:put(SM, movement, {brownian, Tau, XMin, YMin, ZMin, XMax, YMax, ZMax, Xn, Yn, Zn}),
      fsm:set_event(SM, eps);
    rocking ->
      {ahrs, [Yaw, Pitch, Roll]} = share:get(SM, ahrs),
      [fsm:broadcast(fsm:set_event(__, eps), nmea, {send, {nmea, {tnthpr,Yaw,"N",Pitch,"N",Roll,"N"}}}),
       fsm:broadcast(fsm:set_event(__, eps), nmea, {send, {nmea, {smcs,Roll,Pitch,0.0}}}),
       fsm:broadcast(fsm:set_event(__, eps), nmea, {send, {nmea, {hdt,Yaw}}})](SM);
    {nmea, _} ->
      SM;
    _ ->
      fsm:set_event(SM#sm{state = alarm}, internal)
  end.

broadcast_position(SM, [Xn,Yn,Zn]) ->
  Lever_arm = share:get(SM, lever_arm),
  [Psi, Theta, Phi] = rock(SM, [Xn,Yn,Zn]),
  %% converting to global reference system
  [Xl,Yl,Zl] = geometry:rotate({sensor, Lever_arm}, [Psi, Theta, Phi]),
  %% lever_arm to transducer is taken into account by transducer movement in the emulator
  Ref = share:get(SM, geodetic),
  [_,_,Alt] = ecef2geodetic(enu2ecef([0,0,Zn+Zl], Ref)),
  Sea_level = share:get(SM, sea_level),
  Str = lists:flatten(io_lib:format("~p ~p ~p ~p ~p ~p", [Xn+Xl,Yn+Yl,Alt-Sea_level,Phi,Theta,Psi])),
  fsm:cast(SM, scli, {send, {string, Str}}),
  [Yaw, Pitch, Roll] = [V*180/math:pi() || V <- flip_rot([Psi, Theta, Phi])],
  share:put(SM, ahrs, {ahrs, [Yaw,Pitch,Roll]}),
  broadcast_nmea(SM, apply_jitter(SM, [Xn, Yn, Zn])).

hypot(X,Y) ->
  math:sqrt(X*X + Y*Y).

sign(A) when A < 0 -> -1;
sign(_) -> 1.

-ifndef(floor_bif).
floor(X) when X < 0 ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T - 1
    end;
floor(X) ->
    trunc(X).
-endif.

smod(X, M)  -> X - floor(X / M + 0.5) * M.
wrap_pi(A) -> smod(A, -2*math:pi()).
wrap_2pi(A) -> smod(A - math:pi(), 2*math:pi()) + math:pi().
lp_wrap(New, Old, K) -> Old + K*(wrap_pi(New - Old)).

flip_rot([ Heading, Pitch, Roll]) ->
    [ wrap_2pi(math:pi()/2 - Heading), wrap_pi(-Pitch), wrap_pi(Roll) ].

%% turning left - roll positive, otherwise negative
%% values in radians
rock(SM, [E2,N2,_]=P2) ->
  K = 0.1,
  {tail, [P1,P0,_], Pitch_phase, Heading_prev, Roll_prev} = share:get(SM, tail),
  Pitch_phase1 = Pitch_phase + 2 * math:pi() / 20 / share:get(SM, decim), %% freq dependend, here update each second
  Pitch = 5 * math:sin(Pitch_phase1) * math:pi() / 180,
  [E0,N0,_] = P0,
  [E1,N1,_] = P1,
  Heading = wrap_2pi(lp_wrap(math:atan2(N2-N1,E2-E1), Heading_prev, K)),
  A = hypot(E1-E0,N1-N0),
  B = hypot(E2-E1,N2-N1),
  C = hypot(E2-E0,N2-N0),
  Alpha = try math:acos((C*C-A*A-B*B)/(2*A*B)) catch _:_ -> 0 end,
  AlphaA = math:atan2(N1-N0,E1-E0),
  AlphaB = Heading,
  Sign = -sign(AlphaB - AlphaA),
  Roll = wrap_pi(lp_wrap((Sign * Alpha / 2), Roll_prev, K)),
  share:put(SM, tail, {tail, [P2,P1,P0], Pitch_phase1, Heading, Roll}),
  [Heading, Pitch, Roll].

broadcast_nmea(SM, [X, Y, Z]) ->
  try  {MS,S,US} = os:timestamp(),
       DecimMax = share:get(SM, decim),
       case share:get(SM, pos_decim) of
           N when N < DecimMax -> share:put(SM, pos_decim, N + 1);
           _ ->
               share:put(SM, pos_decim, 0),

               {{Year,Month,Day},{HH,MM,SS}} = calendar:now_to_universal_time({MS,S,US}),
               Timestamp = 60*(60*HH + MM) + SS + US / 1000000,
               Ref = share:get(SM, geodetic),
               [Lat,Lon,Alt] = ecef2geodetic(enu2ecef([X,Y,Z], Ref)),

               GGA = {gga, Timestamp, Lat, Lon, 4,nothing,nothing,Alt,nothing,nothing,nothing},
               ZDA = {zda, Timestamp, Day, Month, Year, 0, 0},
               fsm:broadcast(SM, nmea, {send, {nmea, GGA}}),
               fsm:broadcast(SM, nmea, {send, {nmea, ZDA}})
       end
  catch T:E -> ?ERROR(?ID, "~p:~p~n", [T,E])
  end.

apply_jitter(SM, [X, Y, Z]) ->
  {jitter, Jx, Jy, Jz} = share:get(SM, jitter),
  [X + (2*Jx*rand:uniform() - Jx),
   Y + (2*Jy*rand:uniform() - Jy),
   Z + (2*Jz*rand:uniform() - Jz)].

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  ?ERROR(?ID, "ALARM~n", []),
  exit({alarm, SM#sm.module}).
