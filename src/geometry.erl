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
-module(geometry).

-export([norm/1, norm2/1, norm/2, norm2/2, normilize/1]).

-export([ecef2geodetic/3, ecef2geodetic/1, geodetic2ecef/3, geodetic2ecef/1]).
-export([ecef2enu/2, enu2ecef/2]).
-export([ecef2ned/2, ned2ecef/2]).

-export([rotate/2]).

-export([random_normal/2, brownian_walk/3]).

-import(lists, [reverse/1, map/2, zip/2, foldl/3, nth/2, last/1, seq/2, flatten/1, nthtail/2, sum/1]).
-import(math, [sqrt/1, pow/2, sin/1, cos/1, atan2/2]).

vdiff(V1,V2) -> map(fun({X1,X2}) -> X1-X2 end, zip(V1,V2)).

norm2(V) -> sum(map(fun(X) -> X*X end, V)).
norm(V) -> math:sqrt(norm2(V)).

norm2(V1,V2) -> norm2(vdiff(V1,V2)).
norm(V1,V2) -> norm(vdiff(V1,V2)).

normilize(V) -> N = norm(V), map(fun(I) -> I/N end, V).

random_normal(Mean, StdDev) ->
  U = rand:uniform(),
  V = rand:uniform(),
  Mean + StdDev * ( math:sqrt(-2 * math:log(U)) * math:cos(2 * math:pi() * V) ).

brownian_walk(Min, Max, Prev) when Max >= Min, Prev >= Min, Prev =< Max ->
  Rnd = random_normal(0, (Max - Min) / 100),
  if Prev + Rnd > Max -> Prev - 5 * abs(Rnd);
     Prev + Rnd < Min -> Prev + 5 * abs(Rnd);
     true -> Prev + Rnd
  end.

wgs84('a') -> 6378137;
wgs84('b') -> 6356752.3142;
wgs84('e^2') -> 6.69437999014e-3;
wgs84('e"^2') -> 6.73949674228e-3;
wgs84('1/f') -> 298.257223563;
wgs84('f') -> 1/wgs84('1/f').

%% Convert geodetic coordinates WGS84 to ECEF
geodetic2ecef([Lat, Lon, Alt]) -> geodetic2ecef(Lat, Lon, Alt).
geodetic2ecef(Lat, Lon, Alt) ->
  PI = math:pi(),
  RLat = Lat * PI / 180,
  RLon = Lon * PI / 180,
  N = wgs84('a') / sqrt(1-wgs84('e^2') * pow(sin(RLat),2)),
  X = (N + Alt) * cos(RLat) * cos(RLon),
  Y = (N + Alt) * cos(RLat) * sin(RLon),
  Z = (N * (1 - wgs84('e^2')) + Alt) * sin(RLat),
  [X, Y, Z].

ecef2geodetic([X,Y,Z]) -> ecef2geodetic(X,Y,Z).
ecef2geodetic(X,Y,Z) ->
  PI = math:pi(),
  %% Longitude
  Lambda = atan2(Y,X),

  %% Distance from Z-axis
  RHO = sqrt(X*X + Y*Y),

  %% Bowring's formula for initial parametric (beta) and geodetic (phi) latitudes
  Beta0 = atan2(Z, (1 - wgs84('f')) * RHO),
  Phi0 = atan2(Z + wgs84('b') * wgs84('e"^2') * pow(sin(Beta0),3),
               RHO - wgs84('a') * wgs84('e^2') * pow(cos(Beta0),3)),

  %% Fixed-point iteration with Bowring's formula
  %% (typically converges within two or three iterations)
  BetaNew0 = atan2((1-wgs84('f'))*sin(Phi0), cos(Phi0)),

  {_, Phi, _} = foldl(fun(_,{Beta1,_,BetaNew1}) ->
                          Phi2 = atan2(Z + wgs84('b') * wgs84('e"^2') * pow(sin(Beta1),3),
                                       RHO - wgs84('a') * wgs84('e^2') * pow(cos(Beta1),3)),
                          {BetaNew1,
                           Phi2, 
                           atan2((1-wgs84('f'))*sin(Phi2), cos(Phi2))}
                      end, {Beta0, Phi0, BetaNew0}, seq(1,3)),

  %% Calculate ellipsoidal height from the final value for latitude
  Sin_phi = sin(Phi),
  N = wgs84('a') / sqrt(1 - wgs84('e^2') * pow(Sin_phi, 2)),
  Alt = RHO * cos(Phi) + (Z + wgs84('e^2') * N * Sin_phi) * Sin_phi - N,
  [Phi * 180 / PI, Lambda * 180 / PI, Alt].

%% Converts ECEF coordinate pos into local-tangent-plane ENU
%% coordinates relative to another ECEF coordinate ref. Returns a tuple
%% (East, North, Up).
%% pos geocentric point location
%% ref geodetic point location
ecef2enu(ECEF_Pos, Geodetic_Ref) ->
  [Phi0, Lambda0, Alt0] = Geodetic_Ref,
  [XR, YR, ZR] = geodetic2ecef(Phi0, Lambda0, Alt0),
  [XP, YP, ZP] = ECEF_Pos,
  [DX, DY, DZ] = [XP - XR, YP - YR, ZP - ZR],

  PI = math:pi(),
  Cos_lambda = cos(Lambda0 * PI / 180),
  Sin_lambda = sin(Lambda0 * PI / 180),
  Cos_phi = cos(Phi0 * PI / 180),
  Sin_phi = sin(Phi0 * PI / 180),

  E = -Sin_lambda * DX + Cos_lambda * DY,
  N = -Sin_phi * Cos_lambda * DX - Sin_phi * Sin_lambda * DY + Cos_phi * DZ,
  U = Cos_phi * Cos_lambda * DX + Cos_phi * Sin_lambda * DY + Sin_phi * DZ,
  [E, N, U].

ecef2ned(ECEF_Pos, Geodetic_Ref) ->
  [E, N, U] = ecef2enu(ECEF_Pos, Geodetic_Ref),
  [N, E, -U].

enu2ecef(ENU_Pos, Geodetic_Ref) ->
  [Phi0, Lambda0, Alt0] = Geodetic_Ref,
  [XR, YR, ZR] = geodetic2ecef(Phi0, Lambda0, Alt0),
  [X, Y, Z] = ENU_Pos,

  PI = math:pi(),
  Cos_lambda = cos(Lambda0 * PI / 180),
  Sin_lambda = sin(Lambda0 * PI / 180),
  Cos_phi = cos(Phi0 * PI / 180),
  Sin_phi = sin(Phi0 * PI / 180),

  XP = XR + (-Sin_lambda*X - Sin_phi*Cos_lambda*Y + Cos_phi*Cos_lambda*Z),
  YP = YR + (Cos_lambda*X - Sin_phi*Sin_lambda*Y + Cos_phi*Sin_lambda*Z),
  ZP = ZR + (Cos_phi*Y + Sin_phi*Z),
  [XP, YP, ZP].

ned2ecef(NED_Pos, Geodetic_Ref) ->
  [N,E,D] = NED_Pos,
  enu2ecef([E,N,-D], Geodetic_Ref).

%% the sensor coordinate system to the global reference system
%% angles in degrees
rotate({sensor, [X, Y, Z]}, [Psi, Theta, Phi]) ->
  XG = X * cos(Theta) * cos(Psi) +
    Y * (sin(Theta) * sin(Phi) * cos(Psi) - cos(Phi) * sin(Psi)) +
    Z * (sin(Theta) * cos(Psi) * cos(Phi) + sin(Phi) * sin(Psi)),

  YG = X * cos(Theta) * sin(Psi) +
    Y * (sin(Theta) * sin(Psi) * sin(Phi) + cos(Phi) * cos(Psi)) +
    Z * (sin(Theta) * cos(Phi) * sin(Psi) - sin(Phi) * cos(Psi)),

  ZG = -X * sin(Theta) +
    Y * cos(Theta) * sin(Phi) +
    Z * cos(Theta) * cos(Phi),
  [XG, YG, ZG];

%% the global reference system to the sensor coordinate system
%% angles in degrees
rotate({global, [X, Y, Z]}, [Psi, Theta, Phi]) ->
  XS = X * cos(Theta) * cos(Psi) +
    Y * cos(Theta) * sin(Psi) +
    -Z * sin(Theta),

  YS = X * (sin(Theta) * sin(Phi) * cos(Psi) - cos(Phi) * sin(Psi)) +
    Y * (sin(Theta) * sin(Psi) * sin(Phi) + cos(Phi) * cos(Psi)) +
    Z * cos(Theta) * sin(Phi),

  ZS = X * (sin(Theta) * cos(Psi) * cos(Phi) + sin(Phi) * sin(Psi)) +
    Y * (sin(Theta) * cos(Phi) * sin(Psi) - sin(Phi) * cos(Psi)) +
    Z * cos(Theta) * cos(Phi),
  [XS, YS, ZS].
