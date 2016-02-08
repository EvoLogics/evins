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
-module(mod_sensor_nl).
-behaviour(fsm_worker).

-include("fsm.hrl").
-include("sensor.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
    fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(Mod_ID, Role_IDs, Share, ArgS) ->
    Sensor = parse_conf(ArgS, Share),

    InsideList = lists:filter(fun(X) -> X =:= Sensor end, ?LIST_ALL_SENSORS),
    if InsideList =:= [] ->
      ?ERROR(Mod_ID, "!!!  ERROR, no defined sensor with the name ~p~n", [Sensor]),
      io:format("!!! ERROR, no defined sensor with the name ~p~n", [Sensor]);
    true ->
      ?TRACE(Mod_ID, "Name of current sensor ~p~n", [Sensor])
    end,

    Roles = fsm_worker:role_info(Role_IDs, [nl, read_sensor, sensor_nl]),
    [#sm{roles = Roles, module = fsm_sensor_nl}].

parse_conf(ArgS, Share) ->
  SensorSet      = [S     || {sensor, S} <- ArgS],
  FileSet      = [S     || {file, S} <- ArgS],

  Sensor         = set_params(SensorSet, no_sensor),
  File         = set_params(FileSet, no_file),

  ets:insert(Share, [{sensor, Sensor}]),
  ets:insert(Share, [{sensor_file, File}]),
  Sensor.

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.
