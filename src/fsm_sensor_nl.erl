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
  ?TRACE(?ID, "sensor state ~p ev ~p term ~p~n", [SM#sm.state, SM#sm.state, Term]),
  case Term of
    {timeout, answer_timeout} -> SM;
    {timeout, busy_timeout} ->
      T = nl_mac_hf:readETS(SM, last_sent),
      fsm:run_event(MM, SM#sm{event=send_data}, T);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {sensor_data, Sensor, L} ->
      nl_mac_hf:insertETS(SM, last_sensor_read, {Sensor, L});
    {format, error} ->
      fsm:cast(SM, sensor_nl, {send, {string, "FORMAT ERROR"} });
    {rcv_ll, Protocol, {nl, recv, ISrc, IDst, Payload}} ->
      fsm:run_event(MM, SM#sm{event=recv_data}, {rcv_ll, Protocol, ISrc, IDst, Payload});
    {rcv_ll, {nl, ok}} ->
      nl_mac_hf:cleanETS(SM, last_sent),
      fsm:cast(SM, sensor_nl, {send, {string, "OK"} });
    {rcv_ll, {nl, busy}} ->
      fsm:set_timeout(SM, {ms, 100}, busy_timeout);
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
    {rcv_ll, _, ISrc, _, Payload} ->
      SensorData = extract_sensor_command(Payload),
      case SensorData of
        [error, Sensor, Data] ->
          parse_recv_data(SM, Sensor, ISrc, Data);
        [get_data, _, _] ->
          parse_get_data(SM, Term);
        [recv_data, Sensor, Data] ->
          parse_recv_data(SM, Sensor, ISrc, Data)
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
parse_get_data(SM, {rcv_ll, Protocol, ISrc, _, _}) ->
  [_, Data] = read_from_sensor(SM),
  if (Data == nothing) ->
    ?ERROR(?ID, "Sensor Format is wrong, check configuration ! ~n", []),
    T = {rcv_ul, Protocol, ISrc, error, <<"">>},
    SM#sm{event = send_data, event_params = T};
  true ->
    ?TRACE(?ID, "Data read from sensor length: ~p, Data ~p~n", [byte_size(Data), Data]),
    T = {rcv_ul, Protocol, ISrc, recv_data, Data},
    SM#sm{event = send_data, event_params = T}
  end.

parse_recv_data(SM, Sensor, ISrc, Data) ->
  LSrc = integer_to_list(ISrc),
  PData = parse_sensor_data(SM, Sensor, Data),
  if (PData == nothing) ->
    ?ERROR(?ID, "Sensor Format is wrong, check configuration ! ~n", []),
    Str = "Remote sensor (node " ++ LSrc ++ ") data, format error!",
    fsm:cast(SM, sensor_nl, {send, {string, Str} }),
    SM#sm{event = recvd};
  true ->
    ?TRACE(?ID, "Data received from remote sensor ~p~n", [PData]),
    LSensor = atom_to_list(Sensor),
    Str = "Received data from node " ++ LSrc ++
          " with " ++ LSensor ++ " sensor" ++ "\n" ++ PData,
    save_data_to_file(SM, LSrc, PData),
    fsm:cast(SM, sensor_nl, {send, {string, Str} }),
    SM#sm{event = recvd}
  end.

save_data_to_file(SM, LSrc, PData) ->
  File = nl_mac_hf:readETS(SM, save_file),
  Str = io_lib:fwrite("~s : ~s.\n", [LSrc, PData]),
  case file:read_file_info(File) of
    {ok, _FileInfo} ->
      file:write_file(File, Str, [append]);
    {error, enoent} ->
      file:write_file(File, Str)
 end.

send_sensor_command(SM, Protocol, Dst, TypeMsg, D) ->
  File = nl_mac_hf:readETS(SM, sensor_file),
  [SRead, SData] = read_from_sensor(SM),
  {Sensor, Data} =
  if( (File == no_file) and
      (SData =/= nothing)) ->
    {SRead, SData};
  true ->
    S = nl_mac_hf:readETS(SM, sensor),
    {S, D}
  end,
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
  File = nl_mac_hf:readETS(SM, sensor_file),
  Last_sensor_read = nl_mac_hf:readETS(SM, last_sensor_read),

  {Sensor, Line} =
  case File of
    no_file when Last_sensor_read =/= not_inside ->
      Last_sensor_read;
    no_file ->
      S = nl_mac_hf:readETS(SM, sensor),
      {S, not_inside};
    _ ->
      S = nl_mac_hf:readETS(SM, sensor),
      {S, readlines(File)}
  end,

  case Sensor of
    _ when Line == not_inside ->
      [Sensor, nothing];
    conductivity ->
      [Sensor, create_payl_conductivity(Line)];
    oxygen ->
      [Sensor, create_payl_oxygen(Line)];
    pressure ->
      [Sensor, create_payl_pressure(Line)];
    _ ->
      [Sensor, nothing]
  end.

parse_sensor_data(SM, Sensor, Data) ->
  case Sensor of
    conductivity ->
      Str = extract_payl_conductivity(Data),
      ?TRACE(?ID, "Received string from remote sensor ~p~n", [Str]),
      Str;
    oxygen ->
      Str = extract_payl_oxygen(Data),
      ?TRACE(?ID, "Received string from remote sensor ~p~n", [Str]),
      Str;
    pressure ->
      Str = extract_payl_pressure(Data),
      ?TRACE(?ID, "Received string from remote sensor ~p~n", [Str]),
      Str;
    _ ->
      nothing
  end.

bin_to_float(Bin) when is_binary(Bin) ->
  L = re:replace(Bin, "(^\\s+)|(\\s+$)", "", [global,{return, list}]),
  nl_mac_hf:bin_to_num(L);
bin_to_float(Bin) ->
  nl_mac_hf:bin_to_num(Bin).

readlines(not_inside) ->
  not_inside;
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

%------------------------------ Create/extract functions sensors ------------------------
extract_payl_conductivity(Data) ->
  try
    <<BM1:16, BM2:16, BConductivity:32/float, BTemperature:32/float,
    BConductance:32/float, BRawCond0:16, BRawCond1:16, BZAmp:32/float, BRawTemp:32/float>> = Data,

    M1 = integer_to_list(BM1),
    M2 = integer_to_list(BM2),
    Conductivity = float_to_list(BConductivity, [{scientific, 6}]),
    Temperature = float_to_list(BTemperature, [{scientific, 6}]),
    Conductance = float_to_list(BConductance, [{scientific, 6}]),
    RawCond0 = integer_to_list(BRawCond0),
    RawCond1 = integer_to_list(BRawCond1),
    ZAmp = float_to_list(BZAmp, [{scientific, 6}]),
    RawTemp = float_to_list(BRawTemp, [{scientific, 6}]),

    "MEASUREMENT\t" ++ M1 ++ "\t" ++ M2 ++ "\t" ++
    "Conductivity[mS/cm]\t " ++ Conductivity ++ "\t" ++
    "Temperature[Deg.C]\t" ++ Temperature ++ "\t" ++
    "Conductance[mS]\t" ++ Conductance ++ "\t" ++
    "RawCond0[LSB]\t" ++ RawCond0 ++ "\t" ++
    "RawCond1[LSB]\t" ++ RawCond1 ++ "\t" ++
    "ZAmp[mV]\t" ++ ZAmp ++ "\t" ++
    "RawTemp[mV]\t" ++ RawTemp
  catch error: _Reason ->
    nothing
  end.

create_payl_conductivity(Line) ->
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
      {match, [MEASUREMENT1, MEASUREMENT2]} = re:run(MEASUREMENT, "[0-9]+",
                                              [global, {capture, all, binary}]),
      [M1] = MEASUREMENT1,
      [M2] = MEASUREMENT2,
      IM1 =  nl_mac_hf:bin_to_num(M1),
      IM2 =  nl_mac_hf:bin_to_num(M2),

      BStrM1 = <<IM1:16>>,
      BStrM2 = <<IM2:16>>,
      BStrRawCond0 = <<IRawCond0:16>>,
      BStrRawCond1 = <<IRawCond1:16>>,

      BStrConductivity = <<IConductivity:32/float>>,
      BStrTemperature = <<ITemperature:32/float>>,
      BStrConductance = <<IConductance:32/float>>,
      BStrZAmp = <<IZAmp:32/float>>,
      BStrRawTemp = <<IRawTemp:32/float>>,

      <<BStrM1/bitstring, BStrM2/bitstring, BStrConductivity/bitstring,
      BStrTemperature/bitstring, BStrConductance/bitstring,
      BStrRawCond0/bitstring, BStrRawCond1/bitstring,
      BStrZAmp/bitstring, BStrRawTemp/bitstring>>;
    nomatch ->
      nothing
  end.

extract_payl_oxygen(Data) ->
  try
    <<BM1:16, BM2:16, BConcentration:32/float, BAirSaturation:32/float,
    BTemperature:32/float, BCalPhase:32/float, BTCPhase:32/float, BC1RPh:32/float,
    BC2RPh:32/float, BC1Amp:32/float, BC2Amp:32/float, BRawTemp:32/float>> = Data,

    M1 = integer_to_list(BM1),
    M2 = integer_to_list(BM2),

    Concentration = io_lib:format("~.3f",[BConcentration]),
    AirSaturation = io_lib:format("~.3f",[BAirSaturation]),
    Temperature = io_lib:format("~.3f",[BTemperature]),
    CalPhase = io_lib:format("~.3f",[BCalPhase]),
    TCPhase = io_lib:format("~.3f",[BTCPhase]),
    C1RPh = io_lib:format("~.3f",[BC1RPh]),
    C2RPh = io_lib:format("~.3f",[BC2RPh]),
    C1Amp = io_lib:format("~.1f",[BC1Amp]),
    C2Amp = io_lib:format("~.1f",[BC2Amp]),
    RawTemp = io_lib:format("~.1f",[BRawTemp]),

    "MEASUREMENT\t" ++ M1 ++ "\t" ++ M2 ++ "\t" ++
    "O2Concentration(uM)\t" ++ Concentration ++ "\t" ++
    "AirSaturation(%)\t" ++ AirSaturation ++ "\t" ++
    "Temperature(Deg.C)\t" ++ Temperature ++ "\t" ++
    "CalPhase(Deg)\t" ++ CalPhase ++ "\t" ++
    "TCPhase(Deg)\t" ++ TCPhase ++ "\t" ++
    "C1RPh(Deg)\t" ++ C1RPh ++ "\t" ++
    "C2RPh(Deg)\t" ++ C2RPh ++ "\t" ++
    "C1Amp(mV)\t" ++ C1Amp ++ "\t" ++
    "C2Amp(mV)\t" ++ C2Amp ++ "\t" ++
    "RawTemp(mV)\t" ++ RawTemp
  catch error: _Reason ->
    nothing
  end.

create_payl_oxygen(Line) ->
  R1 = "^(MEASUREMENT)(.*)(O2Concentration\\(uM\\))(.*)(AirSaturation\\(\\%\\))(.*)(Temperature\\(Deg\\.C\\))(.*)",
  R2 = R1 ++ "(CalPhase\\(Deg\\))(.*)(TCPhase\\(Deg\\))(.*)(C1RPh\\(Deg\\))(.*)(C2RPh\\(Deg\\))(.*)",
  Regexp = R2 ++ "(C1Amp\\(mV\\))(.*)(C2Amp\\(mV\\))(.*)(RawTemp\\(mV\\))(.*)",
  Elms = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22],
  case re:run(Line, Regexp, [dotall, {capture, Elms, binary}]) of
    {match,[<<"MEASUREMENT">>, MEASUREMENT,
        <<"O2Concentration(uM)">>, BConcentration,
        <<"AirSaturation(%)">>, BAirSaturation,
        <<"Temperature(Deg.C)">>, BTemperature,
        <<"CalPhase(Deg)">>, BCalPhase,
        <<"TCPhase(Deg)">>, BTCPhase,
        <<"C1RPh(Deg)">>, BC1RPh,
        <<"C2RPh(Deg)">>, BC2RPh,
        <<"C1Amp(mV)">>, BC1Amp,
        <<"C2Amp(mV)">>, BC2Amp,
        <<"RawTemp(mV)">>, BRawTemp]} ->

      IConcentration = bin_to_float(BConcentration),
      IAirSaturation = bin_to_float(BAirSaturation),
      ITemperature = bin_to_float(BTemperature),
      ICalPhase = bin_to_float(BCalPhase),
      ITCPhase = bin_to_float(BTCPhase),
      IC1RPh = bin_to_float(BC1RPh),
      IC2RPh = bin_to_float(BC2RPh),
      IC1Amp = bin_to_float(BC1Amp),
      IC2Amp = bin_to_float(BC2Amp),
      IRawTemp = bin_to_float(BRawTemp),

      {match, [MEASUREMENT1, MEASUREMENT2]} = re:run(MEASUREMENT, "[0-9]+",
                                              [global, {capture, all, binary}]),
      [M1] = MEASUREMENT1,
      [M2] = MEASUREMENT2,
      IM1 =  nl_mac_hf:bin_to_num(M1),
      IM2 =  nl_mac_hf:bin_to_num(M2),

      BStrM1 = <<IM1:16>>,
      BStrM2 = <<IM2:16>>,

      BStrConcentration = <<IConcentration:32/float>>,
      BStrAirSaturation = <<IAirSaturation:32/float>>,
      BStrTemperature = <<ITemperature:32/float>>,
      BStrCalPhase = <<ICalPhase:32/float>>,
      BStrTCPhase = <<ITCPhase:32/float>>,
      BStrC1RPh = <<IC1RPh:32/float>>,
      BStrC2RPh = <<IC2RPh:32/float>>,
      BStrC1Amp = <<IC1Amp:32/float>>,
      BStrC2Amp = <<IC2Amp:32/float>>,
      BStrRawTemp = <<IRawTemp:32/float>>,

      <<BStrM1/bitstring, BStrM2/bitstring, BStrConcentration/bitstring,
      BStrAirSaturation/bitstring, BStrTemperature/bitstring,
      BStrCalPhase/bitstring, BStrTCPhase/bitstring,
      BStrC1RPh/bitstring, BStrC2RPh/bitstring,
      BStrC1Amp/bitstring, BStrC2Amp/bitstring, BStrRawTemp/bitstring>>;
    nomatch ->
      nothing
  end.

extract_payl_pressure(Data) ->
  try
    <<BVal:32/float>> = Data,
    Val = io_lib:format("~.4f",[BVal]),
    "PRESSURE\t" ++ Val
  catch error: _Reason ->
    nothing
  end.

create_payl_pressure(Line) ->
  case re:run(Line, "[0-9]+.[0-9]+", [{capture, first, list}]) of
    {match,[BVal]} ->
      IVal = bin_to_float(BVal),
      BStrVal = <<IVal:32/float>>,
      <<BStrVal/bitstring>>;
    nomatch ->
      nothing
  end.
