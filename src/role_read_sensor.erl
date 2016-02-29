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
-module(role_read_sensor).
-behaviour(role_worker).

-include("nl.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM).

ctrl(_,Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

split(L, Cfg) ->
  case re:run(L, "\r\n") of
    {match, [{_, _}]} ->
      case re:run(L, "(MEASUREMENT)(.*?)[\r\n]+(.*)", [dotall, {capture, [1, 2, 3], binary}]) of
        {match, [<<"MEASUREMENT">>, P, L1]} -> sensor_extract(P, L1, Cfg);
        nomatch ->
          case re:run(L, "(.*)[\r\n]+(.*)", [dotall, {capture, [1, 2], binary}]) of
            {match, [P, L1]} -> pressure_extract(P, L1, Cfg);
            nomatch -> [{format, error}]
          end
      end;
    nomatch -> [{more, L}]
  end.

from_term({string, S}, Cfg) -> [list_to_binary(S ++ "\n"), Cfg];
from_term({binary, B}, Cfg) -> [B, Cfg];
from_term({prompt}, Cfg)    -> [<<"> ">>, Cfg];
from_term(_, _)             -> {error, term_not_supported}.

sensor_extract(P, L1, Cfg) ->
  Payl = list_to_binary(["MEASUREMENT", P]),
  Res = test_oxygen(Payl, L1, Cfg),
  case Res of
    [{format, error}] ->
      test_conductivity(Payl, L1, Cfg);
    _ -> Res
  end.

test_oxygen(Payl, L1, Cfg) ->
  R1 = "^(MEASUREMENT)(.*)(O2Concentration\\[uM\\])(.*)(AirSaturation\\[\\%\\])(.*)(Temperature\\[Deg\\.C\\])(.*)",
  R2 = R1 ++ "(CalPhase\\[Deg\\])(.*)(TCPhase\\[Deg\\])(.*)(C1RPh\\[Deg\\])(.*)(C2RPh\\[Deg\\])(.*)",
  Regexp = R2 ++ "(C1Amp\\[mV\\])(.*)(C2Amp\\[mV\\])(.*)(RawTemp\\[mV\\])(.*)",
  Elms = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22],
  case re:run(Payl, Regexp, [dotall, {capture, Elms, binary}]) of
    {match,[<<"MEASUREMENT">>, _MEASUREMENT,
        <<"O2Concentration[uM]">>, _BConcentration,
        <<"AirSaturation[%]">>, _BAirSaturation,
        <<"Temperature[Deg.C]">>, _BTemperature,
        <<"CalPhase[Deg]">>, _BCalPhase,
        <<"TCPhase[Deg]">>, _BTCPhase,
        <<"C1RPh[Deg]">>, _BC4RPh,
        <<"C2RPh[Deg]">>, _BC2RPh,
        <<"C1Amp[mV]">>, _BC1Amp,
        <<"C2Amp[mV]">>, _BC2Amp,
        <<"RawTemp[mV]">>, _BRawTemp]} ->
      [{sensor_data, oxygen, Payl} | split(L1, Cfg)];
    nomatch -> [{format, error}]
  end.

test_conductivity(Payl, L1, Cfg) ->
  R = "^(MEASUREMENT)(.*)(Conductivity\\[mS\/cm\\])(.*)(Temperature\\[Deg\.C\\])(.*)(Conductance\\[mS\\])(.*)",
  Regexp = R ++ "(RawCond0\\[LSB\\])(.*)(RawCond1\\[LSB\\])(.*)(ZAmp\\[mV\\])(.*)(RawTemp\\[mV\\])(.*)",
  Elms = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
  case re:run(Payl, Regexp, [dotall, {capture, Elms, binary}]) of
    {match,[<<"MEASUREMENT">>, _MEASUREMENT,
        <<"Conductivity[mS/cm]">>, _BConductivity,
        <<"Temperature[Deg.C]">>, _BTemperature,
        <<"Conductance[mS]">>, _BConductance,
        <<"RawCond0[LSB]">>, _BRawCond0,
        <<"RawCond1[LSB]">>, _BRawCond1,
        <<"ZAmp[mV]">>, _BZAmp,
        <<"RawTemp[mV]">>, _BRawTemp]} ->
        [{sensor_data, conductivity, Payl} | split(L1, Cfg)];
    nomatch -> [{format, error}]
  end.

pressure_extract(P, L1, Cfg) ->
  case re:run(P, "[0-9]+.[0-9]+", [{capture, first, list}]) of
    {match, [BVal]} -> [{sensor_data, pressure, BVal} | split(L1, Cfg)];
    nomatch -> [{format, error}]
  end.
