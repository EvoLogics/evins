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
  _Old = rand:seed(exsplus, { A1, A2, A3 }),

  %% {movement,[{stationary,...},{circle,...},{tide,...},{rocking,...},{brownian,...},{jitter,...}]}

  %% {circle, _C, _R, _V, Tau, _Phy} - optional
  %% {brownian, XMin, YMin, XMax, YMax}
  %% {stationary, X, Y, Z, Tau}

  %% for circle, brownian and stationary
  %% {jitter, Jx, Jy, Jz} (2*J*random:uniform() - J)

  %% {tide, Tau, Depth, Amplitude, Phase, Period} or {pressure, P}
  %% {rocking, Tau} - mock

  %% {lever_arm, [Forward, Right, Down]}
  [_,_,_Z_lever_arm] = Lever_arm = case [Arm || {lever_arm, Arm} <- ArgS] of [] -> [0,0,0]; [Arm] -> Arm end,

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
  ShareID = #sm{share = Share},
  share:put(ShareID, lever_arm, Lever_arm),

  Decim =
  case lists:keyfind(decim, 1, ArgS) of
      {decim, Dec} -> Dec;
      _ -> 1
  end,
  share:put(ShareID, decim, Decim),
  share:put(ShareID, pos_decim, 0),

  ?TRACE(Mod_ID, "Movements: ~140p~n", [Movements]),
  lists:map(fun({jitter, _, _, _} = Movement) ->
                share:put(ShareID, jitter, Movement);
               ({tide, _Tau, _Pr, _Amp, _Phy, _Period} = Movement) ->
                share:put(ShareID, tide, Movement);
               ({rocking, _Tau} = Movement) ->
                share:put(ShareID, rocking, Movement);
               ({rotate, _Tau} = Movement) ->
                share:put(ShareID, rocking, Movement);
               ({freeze, _Tau} = Movement) ->
                share:put(ShareID, rocking, Movement);
               (_) ->
                nothing
            end, Movements),
  %% NOTE: if several movements provided, will be overwirtten with last one
  Init_movement = fun(Movement) ->
                      [{geodetic, Lat, Lon, Alt}] = [R || {reference,R} <- ArgS],
                      Sea_level = Alt + Depth,
                      share:put(ShareID, [{sea_level, Sea_level}, {geodetic, [Lat, Lon, Alt]}, {movement, Movement}])
                  end,
  lists:map(
    fun({stationary, _, _, _, _} = Movement) ->
        Init_movement(Movement);
       ({stationary, _, _, _} = Movement) ->
        Init_movement(Movement);
       ({circle, _C, _R, _V, _Tau, _Phy} = Movement) ->
        Init_movement(Movement);
       ({eight, _C, _R, _V, _Tau, _Phy} = Movement) ->
        Init_movement(Movement);
       ({brownian, Tau, XMin, YMin, ZMin, XMax, YMax, ZMax}) ->
        Xs = (rand:uniform() * (XMax - XMin)) + XMin,
        Ys = (rand:uniform() * (YMax - YMin)) + YMin,
        Zs = (rand:uniform() * (ZMax - ZMin)) + ZMin,
        Init_movement({brownian, Tau, XMin, YMin, ZMin, XMax, YMax, ZMax, Xs, Ys, Zs});
       (_) ->
        nothing
    end, Movements),
  [#sm{roles = fsm_worker:role_info(Role_IDs, [nmea,pressure,scli]), module = fsm_move}].

