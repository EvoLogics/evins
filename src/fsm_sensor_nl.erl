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
-module(fsm_sensor_nl).
-behaviour(fsm).

-include("fsm.hrl").
-include("sensor.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3, handle_send/3, handle_recv/3, handle_alarm/3, handle_final/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {send_data, send},
                  {recv_data, recv}
                 ]},

                {send,
                 [{sent, idle}
                 ]},

                {recv,
                 [{recvd, idle},
                 {send_data, send}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------Handler Event----------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT~n", []),
  ?TRACE(?ID, "~p~n", [Term]),
  case Term of
    {timeout, answer_timeout} -> SM;
    {timeout, busy_timeout} ->
      T = nl_mac_hf:readETS(SM, last_sent),
      fsm:run_event(MM, SM#sm{event=send_data}, T);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {format, error} ->
      fsm:cast(SM, sensor_nl, {send, {string, "FORMAT ERROR"} });
    {rcv_ll, Protocol, {nl, recv, ISrc, IDst, Payload}} ->
      fsm:run_event(MM, SM#sm{event=recv_data}, {rcv_ll, Protocol, ISrc, IDst, Payload});
    {rcv_ll, {nl, ok}} ->
      nl_mac_hf:cleanETS(SM, last_sent),
      fsm:cast(SM, sensor_nl, {send, {string, "OK"} });
    {rcv_ll, {nl, busy}} ->
      fsm:set_timeout(SM, {ms, 500}, busy_timeout);
    {rcv_ul, Protocol, Dst, Payl} ->
      T = {rcv_ul, Protocol, Dst, get_data, Payl},
      fsm:run_event(MM, SM#sm{state=idle, event=send_data}, T);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

%%--------------------------------Handler functions-------------------------------
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_send(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  [Param_Term, SMP] = nl_mac_hf:event_params(SM, Term, rcv_ul),
  case Param_Term of
    {rcv_ul, Protocol, Dst, TypeMsg, Payl} ->
      nl_mac_hf:insertETS(SMP, last_sent, Param_Term),
      SM1 = send_sensor_command(SMP, Protocol, Dst, TypeMsg, Payl),
      SM1#sm{event = sent};
    _ ->
      SMP#sm{event = sent}
  end.

handle_recv(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case Term of
    {rcv_ll, Protocol, ISrc, _IDst, Payload} ->
      SensorData = extract_sensor_command(Payload),
      case SensorData of
        [get_data, _, _] ->
          Data = read_from_sensor(SM),
          io:format("!!!!!!!!!!! ~p~n", [Data]),
          T = {rcv_ul, Protocol, ISrc, recv_data, <<"12345667">>},
          SM#sm{event = send_data, event_params = T};
        [recv_data, _Sensor, _Data] ->
          fsm:cast(SM, sensor_nl, {send, {string, "SENSOR DATA"} }),
          SM#sm{event = recvd}
      end;
    _ ->
      SM#sm{event = recvd}
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------Helper functions-------------------------------

send_sensor_command(SM, Protocol, Dst, TypeMsg, Data) ->
  Sensor = nl_mac_hf:readETS(SM, sensor),
  Payl = create_payload_sensor(TypeMsg, Sensor, Data),
  fsm:cast(SM, nl, {send, {nl, send, Protocol, Dst, Payl}}).

%--------------- MAIN HEADER -----------------
%    2b        3b          6b    5b
%    TypeMsg  TypeSensor  SRC   ADD
%---------------------------------------------
create_payload_sensor(TM, TS, Data) ->
  CTypeMsg = nl_mac_hf:count_flag_bits(?TYPEMSGMAX),
  CTypeSensor = nl_mac_hf:count_flag_bits(?TYPESENSORMAX),

  TypeMsg = ?TYPEMSG2NUM(TM),
  BTMsg = <<TypeMsg:CTypeMsg>>,

  TypeSensor = ?TYPESENSOR2NUM(TS),
  BTSensor = <<TypeSensor:CTypeSensor>>,

  TmpData = <<BTMsg/bitstring, BTSensor/bitstring, Data/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = 8 - bit_size(TmpData) rem 8,
    <<BTMsg/bitstring, BTSensor/bitstring, 0:Add, Data/binary>>;
  true ->
    TmpData
  end.

extract_sensor_command(Payl) ->
  CTypeMsg = nl_mac_hf:count_flag_bits(?TYPEMSGMAX),
  CTypeSensor = nl_mac_hf:count_flag_bits(?TYPESENSORMAX),

  Data_bin = (bit_size(Payl) rem 8) =/= 0,
  <<BTypeMsg:CTypeMsg, BTypeSensor:CTypeSensor, Rest/bitstring>> = Payl,
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [?NUM2TYPEMSG(BTypeMsg), ?NUM2TYPESENSOR(BTypeSensor), Data];
  true ->
    [?NUM2TYPEMSG(BTypeMsg), ?NUM2TYPESENSOR(BTypeSensor), Rest]
  end.

read_from_sensor(SM) ->
  Sensor = nl_mac_hf:readETS(SM, sensor),
  Line = readlines("/usr/local/etc/sensor/sensor_data"),
  case Sensor of
    conductivity -> parse_conductivity(Line);
    _ -> nothing
  end.

parse_conductivity(Line) ->
  R = "^(MEASUREMENT)(.*)(Conductivity\\[mS\/cm\\])(.*)(Temperature\\[Deg\.C\\])(.*)(Conductance\\[mS\\])(.*)",
  Regexp = R ++ "(RawCond0\\[LSB\\])(.*)(RawCond1\\[LSB\\])(.*)(ZAmp\\[mV\\])(.*)(RawTemp\\[mV\\])(.*)",
  Elms = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
  case re:run(Line, Regexp, [dotall, {capture, Elms, binary}]) of
    {match,[<<"MEASUREMENT">>, MEASUREMENT,
        <<"Conductivity[mS/cm]">>, BConductivity,
        <<"Temperature[Deg.C]">>, BTemperature,
        <<"Conductance[mS]">>, BConductance,
        <<"RawCond0[LSB]">>, BRawCond0,
        <<"RawCond1[LSB]">>, BRawCond1,
        <<"ZAmp[mV]">>, BZAmp,
        <<"RawTemp[mV]">>, BRawTemp]} ->
        IConductivity = bin_to_float(BConductivity),
        ITemperature = bin_to_float(BTemperature),
        IConductance = bin_to_float(BConductance),
        IRawCond0 = bin_to_float(BRawCond0),
        IRawCond1 = bin_to_float(BRawCond1),
        IZAmp = bin_to_float(BZAmp),
        IRawTemp = bin_to_float(BRawTemp),
        {match, [MEASUREMENT1, MEASUREMENT2]} = re:run(MEASUREMENT, "[0-9]+", [global, {capture, all, binary}]),
        [M1] = MEASUREMENT1,
        [M2] = MEASUREMENT2,
        IM1 =  nl_mac_hf:bin_to_num(M1),
        IM2 =  nl_mac_hf:bin_to_num(M2),
        io:format("~p ~p ~p ~p ~p ~p ~p ~p ~p ~n", [IM1, IM2, IConductivity, ITemperature, IConductance, IRawCond0, IRawCond1, IZAmp, IRawTemp]);
    nomatch ->
      nothing
  end.

bin_to_float(Bin) ->
  L = re:replace(Bin, "(^\\s+)|(\\s+$)", "", [global,{return,list}]),
  nl_mac_hf:bin_to_num(L).

readlines(FileName) ->
  {ok, Device} = file:open(FileName, [read]),
  try get_all_lines(Device)
    after file:close(Device)
  end.

get_all_lines(Device) ->
  case io:get_line(Device, "") of
      eof  -> [];
      Line -> Line ++ get_all_lines(Device)
  end.