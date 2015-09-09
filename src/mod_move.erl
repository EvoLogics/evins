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
-module(mod_move).
-behaviour(fsm_worker).

-include("fsm.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) -> 
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
  {A1,A2,A3} = os:timestamp(),
  _Old = random:seed(A1, A2, A3),

  %% {movement,[{circle,...},{tide,...},{rocking,...},{brownian,...},{jitter,...}]}

  %% {circle, _C, _R, _V, Tau, _Phy} - optional
  %% {brownian, XMin, YMin, XMax, YMax}

  %% for circle and brownian
  %% {jitter, Jx, Jy, Jz} (2*J*random:uniform() - J)

  %% {tide, Tau, Pressure_offset, Amplitude, Phase, Period} 
  %% {rocking, Tau} - mock

  %% {lever_arm, [Forward, Right, Down]}
  [_,_,Z_lever_arm] = Lever_arm = case [Arm || {lever_arm, Arm} <- ArgS] of [] -> [0,0,0]; [Arm] -> Arm end,

  Pressure = case [P || {pressure,P} <- ArgS] of [] -> ?PAIR; [P] -> P end,
  Depth0 = (Pressure - ?PAIR) / ?DBAR_PRO_METER,
  Defaults = [{tide,1000,Depth0,0,0,1}, {rocking,1000},{jitter,0,0,0}],
  [Explicits] = [M || {movement, M} <- ArgS],

  Movements =
    lists:foldl(fun(M,Acc) -> 
                    ?TRACE(Mod_ID, "~p ~p~n", [element(1,M), lists:keyfind(element(1,M),1,Explicits)]),

                    case lists:keyfind(element(1,M),1,Explicits) of
                      false -> [M|Acc];
                      _ -> Acc
                    end
                end, Explicits, Defaults),

  Depth = lists:foldl(fun(M,DA) -> case M of {tide,_,D,_,_,_} -> D; _ -> DA end
                      end, Depth0, Movements),

  %% supporting only NMEA!
  Jitter = lists:keyfind(jitter,1,Movements),
  ?TRACE(Mod_ID, "Jitter: ~180p~n", [Jitter]),
  ets:insert(Share, {jitter, Jitter}),
  ets:insert(Share, {lever_arm, Lever_arm}),
  ?TRACE(Mod_ID, "Movements: ~140p~n", [Movements]),
  Roles =
    lists:foldl(
      fun(M,Acc) -> case M of
                      {jitter, _, _, _} ->
                        Acc;
                      {circle, _C, _R, _V, _Tau, _Phy} = Movement ->
                        [{geodetic, Lat, Lon, Alt}] = [R || {reference,R} <- ArgS],
                        Sea_level = Alt - Z_lever_arm + Depth,
                        ets:insert(Share, {sea_level, Sea_level}),
                        ets:insert(Share, {geodetic, [Lat, Lon, Alt]}),
                        ets:insert(Share, {circle, Movement}),
                        fsm_worker:role_info(Role_IDs, [scli]) ++ Acc;
                      {brownian, Tau, XMin, YMin, ZMin, XMax, YMax, ZMax} ->
                        [{geodetic, Lat, Lon, Alt}] = [R || {reference,R} <- ArgS],
                        Sea_level = Alt - Z_lever_arm + Depth,
                        ets:insert(Share, {sea_level, Sea_level}),
                        Xs = (random:uniform() * (XMax - XMin)) + XMin,
                        Ys = (random:uniform() * (YMax - YMin)) + YMin,
                        Zs = (random:uniform() * (ZMax - ZMin)) + ZMin,
                        ets:insert(Share, {geodetic, [Lat, Lon, Alt]}),
                        ets:insert(Share, {brownian, {brownian, Tau, XMin, YMin, ZMin, XMax, YMax, ZMax, Xs, Ys, Zs}}),
                        fsm_worker:role_info(Role_IDs, [scli]) ++ Acc;
                      {tide, _Tau, _Pr, _Amp, _Phy, _Period} = Movement ->
                        ets:insert(Share, {tide, Movement}),
                        Acc;
                      {rocking, _Tau} = Movement ->
                        ets:insert(Share, {rocking, Movement}),
                        Acc;
                      Unsupported ->
                        ?ERROR(Mod_ID, "Unsupported movement mode: ~p~n", [Unsupported]),
                        Acc
                    end
      end, fsm_worker:role_info(Role_IDs, [nmea,pressure]), Movements),
  [#sm{roles = Roles, module = fsm_move}].

