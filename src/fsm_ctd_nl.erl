%% Copyright (c) 2015, Veronika Kebkal <veronika.kebkal@evologics.de>
%%                     Oleksiy Kebkal <lesha@evologics.de>
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

%% CTD NL - Sending sensor information through network;
%% 1. Connecting to ctd sensor and reading sensor data
%% 2. Encoding sensor data - C,T,D,S,VS to NL command
%% 3. Sending sensor data using flooding protocol
%% 4. On the receiver side :
%%      - decode sensor data
%%      - cast sensor data to an opened port in the same format
%%        as produced by the sensor
-module(fsm_ctd_nl).
-behaviour(fsm).

-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle}
                 ]},

                {alarm, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  LA = share:get(SM, local_address),
  ?INFO(?ID, "HANDLE EVENT  ~150p ~p LA ~p~n", [MM, Term, LA]),
  case Term of
     {connected} ->
      case MM#mm.role of
        nl ->
          [fsm:set_timeout(__, {s, 1}, get_address),
           fsm:cast(__, nl, {send, {nl, get, address}})
          ](SM);
        _ -> SM
      end;
    {timeout, {read_sensor, D}} ->
      Freq = share:get(SM, read_frequency),
      [send_sensor_data(__, D),
       fsm:set_timeout(__, {s, Freq}, {read_sensor, D}),
       fsm:cast(__, scli, {send, {binary, <<"\r\n">>}})
      ](SM);
    {timeout, get_address} ->
      [fsm:set_timeout(__, {s, 1}, get_address),
       fsm:cast(__, nl, {send, {nl, get, address}})
      ](SM);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {nl, address, A} ->
      [fsm:clear_timeout(__, get_address),
       share:put(__, local_address, A),
       fsm:cast(__, nl_impl, {send, Term})
      ](SM);
    {nl, send, A, Data = <<"start,sensor">>} ->
      P = <<1:1, 0:6, 1:1, Data/binary>>,
      Tuple = {nl, send, A, P},
      fsm:cast(SM, nl, {send, Tuple});
    {nl, send, A, Data = <<"stop,sensor">>} ->
      P = <<1:1, 0:6, 1:1, Data/binary>>,
      Tuple = {nl, send, A, P},
      fsm:cast(SM, nl, {send, Tuple});
    {nl, recv, _, _, _} ->
      decode(SM, Term);
    {nl, get, help} ->
      NHelp = string:concat(?MUXHELP, ?HELP),
      fsm:cast(SM, nl_impl, {send, {nl, help, NHelp}});
    {nl, error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {send_error, formError} when MM#mm.role == nl ->
      SM;
    Tuple when MM#mm.role == nl ->
      fsm:cast(SM, nl_impl, {send, Tuple});
    Tuple when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl, {send, Tuple});
    Sensor_data when MM#mm.role == scli ->
      handle_data(SM, Sensor_data);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p from ~p~n", [?MODULE, UUg, MM#mm.role]),
      SM
  end.

handle_idle(_MM, SM, _) ->
  fsm:set_event(SM, eps).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

%%--------------------------------Helper functions-------------------------------
send_sensor_data(SM, Dst) ->
  Last_sensor_data = env:get(SM, last_sensor_data),
  send_sensor_data(SM, Last_sensor_data, Dst).

send_sensor_data(SM, nothing, _) -> SM;
send_sensor_data(SM, L, Dst) ->
  BData =
  lists:foldr(fun (X, B) ->
                <<X:64/float, B/binary>>
              end, <<>>, L),
  S = <<1:1, 0:6, 1:1, BData/binary>>,
  fsm:cast(SM, nl, {send, {nl, send, Dst, S}}).

decode(SM, {nl, recv, Dst, _, <<1:1, 0:6, 1:1, "start,sensor">>}) ->
  Freq = share:get(SM, read_frequency),
  Read_sensor_tmo = fsm:check_timeout(SM, {read_sensor, Dst}),
  if Read_sensor_tmo == true ->
     fsm:set_event(SM, eps);
  true ->
    [fsm:clear_timeout(__, {read_sensor, Dst}),
     fsm:set_timeout(__, {s, Freq}, {read_sensor, Dst}),
     fsm:set_event(__, eps)
    ](SM)
  end;
decode(SM, {nl, recv, Dst, _, <<1:1, 0:6, 1:1, "stop,sensor">>}) ->
  [nl_hf:clear_spec_timeout(__, {read_sensor, Dst}),
   fsm:set_event(__, eps)
  ](SM);
decode(SM, Tuple = {nl, recv, Dst, Src, <<1:1, 0:6, 1:1, BData/binary>>}) ->
  try
    <<C:64/float, T:64/float, D:64/float, S:64/float, VS:64/float>> = BData,
    Str1 = io_lib:format("~.5f;~.5f;~.5f;~.5f;~.5f", [C, T, D, S, VS]),
    Str2 = io_lib:format("~.5f,~.5f,~.5f,~.5f,~.5f\r\n", [C, T, D, S, VS]),
    [fsm:cast(__, nl_impl, {send, {nl, recv, Dst, Src, list_to_binary(Str1)}}),
     fsm:cast(__, scli, {send, {binary, list_to_binary(Str2)}})
    ](SM)
  catch error:_Error ->
    fsm:cast(SM, nl_impl, {send, Tuple})
  end;
decode(SM, Tuple) ->
  fsm:cast(SM, nl_impl, {send, Tuple}).

handle_data(SM, Sensor_data) ->
  try
    {match, [BC, BT, CD, BS, BVS]} =
      re:run(Sensor_data,"([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)",
      [dotall, {capture, [1, 2, 3, 4, 5], binary}]),

    FL =
    lists:foldr(fun (X, A) ->
      [bin_to_num(X) | A]
    end, [], [BC, BT, CD, BS, BVS]),
    ?INFO(?ID, "Got sensor data ~p~n", [FL]),
    env:put(SM, last_sensor_data, FL)
  catch error:_Error -> SM
  end.

bin_to_num(Bin) ->
  try
    N = binary_to_list(Bin),
    case string:to_float(N) of
        {error,no_float} -> list_to_integer(N);
        {F,_Rest} -> F
    end
  catch error: _Reason ->
    0
  end.