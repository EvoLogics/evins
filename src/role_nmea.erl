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
-module(role_nmea).
-behaviour(role_worker).

-include("fsm.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

-import(lists,[map/2,flatten/1,zip/2,foldl/3]).

stop(_) -> ok.

%% params: [{out,all}] or [{out,[gga,zda,rmc]}] or [{out,except,[gga]}]
%% params: [{in,all}] or [{in,[gga,zda,rmc]}] or [{in,except,[gga]}]
%% TODO: test in fsm_mod_supervisor, that #mm.params is list
start(Role_ID, Mod_ID, MM) ->
  Out =
    case lists:keyfind(out,1,MM#mm.params) of
      {out,OutRule} -> #{out => {white,OutRule}};
      {out,except,OutRule} -> #{out => {black,OutRule}};
      false -> #{out => all}
    end,
  In =
    case lists:keyfind(in,1,MM#mm.params) of
      {in,InRule} -> #{in => {white,InRule}};
      {in,except,InRule} -> #{in => {black,InRule}};
      false -> #{in => all}
    end,
  Cfg = maps:merge(Out,In),
  {ok, RParse} = re:compile("^\\\$((P|..)([^,]+),([^*]+))(\\\*(..)|)",[dotall]),
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg#{re => RParse}).

ctrl(_,Cfg) -> Cfg.

to_term(Tail, Chunk, #{in := InRule} = Cfg) ->
  [Terms | Rest] =
    role_worker:to_term(?MODULE, Tail, Chunk, Cfg),

  NewTerms =
    lists:filter(fun({nmea, Sentense}) ->
                     is_filtered(Sentense, InRule)
                 end, Terms),

  [NewTerms | Rest].

safe_binary_to_integer(B) -> try binary_to_integer(B) catch _:_ -> nothing end.

safe_binary_to_float(B) ->
  case (catch binary_to_float(B)) of
    V when is_number(V) -> V;
    _ ->
      try float(binary_to_integer(B))
      catch _:_ -> nothing end
  end.

checksum([]) -> 0;
checksum(<<>>) -> 0;
checksum([H|T]) -> H bxor checksum(T);
checksum(<<H,T/binary>>) -> H bxor checksum(T).

split(L, #{re := RParse} = Cfg) ->
  case binary:split(L,[<<"\r\n">>, <<"\n">>]) of
    [Sentense,Rest] ->
      %% NMEA checksum might be optional
      case re:run(Sentense,RParse,[{capture,[1,3,4,6],binary}]) of
        {match, [Raw,Cmd,Params,XOR]} ->
          CS = checksum(Raw),
          Flag = case binary_to_list(XOR) of
                   [] -> true;
                   LCS -> try CS == list_to_integer(LCS, 16) catch _:_ -> false end
                 end,
          if Flag ->
             [extract_nmea(Cmd, Params) | split(Rest, Cfg)];
             true -> [{error, {checksum, CS, XOR, Raw}} | split(Rest, Cfg)]
          end;
        _ -> [{error, {nomatch, L}} | split(Rest, Cfg)]
      end;
    _ ->
      [{more, L}]
  end.

extract_utc(nothing) ->
  nothing;
extract_utc(BUTC) ->
  <<BHH:2/binary,BMM:2/binary,BSS/binary>> = BUTC,
  SS = case binary:split(BSS,<<".">>) of
         [_,_] -> binary_to_float(BSS);
         _ -> binary_to_integer(BSS)
       end,
  [HH,MM] = [safe_binary_to_integer(X) || X <- [BHH,BMM]],
  60*(60*HH + MM) + SS.

safe_extract_geodata(BUTC, BLat, BN, BLon, BE) ->
  try extract_geodata(BUTC, BLat, BN, BLon, BE)
  catch _:_ -> [nothing, nothing, nothing]
  end.

extract_geodata(BUTC, BLat, BN, BLon, BE) ->
  <<BLatHH:2/binary,BLatMM/binary>> = BLat,
  <<BLonHH:3/binary,BLonMM/binary>> = BLon,
  [LatHH,LonHH] = [safe_binary_to_integer(X) || X <- [BLatHH,BLonHH]],
  [LatMM,LonMM] = [safe_binary_to_float(X) || X <- [BLatMM,BLonMM]],
  LatK = case BN of <<"N">> -> 1; _ -> -1 end,
  LonK = case BE of <<"E">> -> 1; _ -> -1 end,
  Lat = LatK * (LatHH+LatMM/60),
  Lon = LonK * (LonHH+LonMM/60),
  [extract_utc(BUTC), Lat, Lon].

%% $--RMC,UTC,Status,Lat,a,Lon,a,Speed,Tangle,Date,Magvar,a[,FAA]
%% UTC     hhmmss.ss UTC of position
%% Status  a_        Status A=active or V=Void.
%% Lat     x.x       Latitude, degrees
%% N or S  a_
%% Lon     x.x       Longitude, degrees
%% E or W  a_
%% Speed   x.x       Speed of ground in knots
%% Tangle  x.x       Track angle in degrees, True
%% Date    ddmmyy    Date
%% Magvar  x.x       Magnetic Variation
%% E or W  a_
%% Example: $GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
extract_nmea(<<"RMC">>, Params) ->
  try
    [BUTC,BStatus,BLat,BN,BLon,BE,BSpeed,BTangle,BDate,BMagvar,BME] =
      lists:sublist(binary:split(Params,<<",">>,[global]),11),
    Status = case BStatus of <<"A">> -> active; _ -> void end,
    [UTC, Lat, Lon] = extract_geodata(BUTC, BLat, BN, BLon, BE),
    [Speed,Tangle,MagvarV] = [safe_binary_to_float(X) || X <- [BSpeed,BTangle,BMagvar]],
    MagvarS = case BME of <<"E">> -> 1; _ -> -1 end,
    Magvar = case MagvarV of
               nothing -> nothing;
               _ -> MagvarS * MagvarV
             end,
    <<BDD:2/binary,BMM:2/binary,BYY/binary>> = BDate,
    [DD,MM,YY] = [safe_binary_to_integer(X) || X <- [BDD,BMM,BYY]],
    Date = {2000 + YY, MM, DD},
    {nmea,{rmc, UTC, Status, Lat, Lon, Speed, Tangle, Date, Magvar}}
  catch error:_ -> {error, {parseError, rmc, Params}}
  end;

%% hhmmss.ss,llll.ll,a,yyyyy.yy,a,x,xx,x.x,x.x,M, x.x,M,x.x,xxxx
%% 1    = UTC of Position
%% 2    = Latitude
%% 3    = N or S
%% 4    = Longitude
%% 5    = E or W
%% 6    = GPS quality indicator (0=invalid; 1=GPS fix; 2=Diff. GPS fix)
%% 7    = Number of satellites in use [not those in view]
%% 8    = Horizontal dilution of position
%% 9    = Antenna altitude above/below mean sea level (geoid)
%% 10   = Meters  (Antenna height unit)
%% 11   = Geoidal separation (Diff. between WGS-84 earth ellipsoid and
%%        mean sea level.  -=geoid is below WGS-84 ellipsoid)
%% 12   = Meters  (Units of geoidal separation)
%% 13   = Age in seconds since last update from diff. reference station
%% 14   = Diff. reference station ID#
extract_nmea(<<"GGA">>, Params) ->
  try
    [BUTC,BLat,BN,BLon,BE,BQ,BSat,BHDil,BAlt,<<"M">>,BGeoid,<<"M">>,BAge,BID] = binary:split(Params,<<",">>,[global]),
    [UTC, Lat, Lon] = extract_geodata(BUTC, BLat, BN, BLon, BE),
    [Q,Sat,ID] = [safe_binary_to_integer(X) || X <- [BQ,BSat,BID]],
    [HDil,Alt,Geoid,Age] = [safe_binary_to_float(X) || X <- [BHDil,BAlt,BGeoid,BAge]],
    {nmea,{gga, UTC, Lat, Lon, Q, Sat, HDil, Alt, Geoid, Age, ID}}
  catch
    error:_ -> {error, {parseError, gga, Params}}
  end;

%% llll.ll,a,yyyyy.yy,a,hhmmss.ss,A,a
%% 1    = Latitude
%% 2    = N or S
%% 3    = Longitude
%% 4    = E or W
%% 5    = UTC of Position
%% 6    = GPS quality indicator (0=invalid; 1=GPS fix; 2=Diff. GPS fix)
%% 7    = Status
%% 8    = Mode
extract_nmea(<<"GLL">>, Params) ->
  try
    [BLat,BN,BLon,BE,BUTC,BStatus,BMode] = binary:split(Params,<<",">>,[global]),
    [UTC, Lat, Lon] = extract_geodata(BUTC, BLat, BN, BLon, BE),
    Status = case BStatus of <<"A">> -> active; _ -> void end,
    Mode = case BMode of
                <<"A">> -> auto;
                <<"D">> -> differential;
                <<"E">> -> estimated;
                <<"M">> -> manual;
                <<"S">> -> simulated;
                _ -> none
            end,
    {nmea, {gll,Lat,Lon,UTC,Status,Mode}}
  catch
    error:_ -> {error, {parseError, gga, Params}}
  end;

%% $--ZDA,hhmmss.ss,xx,xx,xxxx,xx,xx
%% hhmmss.ss = UTC
%% xx = Day, 01 to 31
%% xx = Month, 01 to 12
%% xxxx = Year
%% xx = Local zone description, 00 to +/- 13 hours
%% xx = Local zone minutes description (same sign as hours)
extract_nmea(<<"ZDA">>, Params) ->
  try
    [BUTC,BD,BM,BY,BZD,BZM] = binary:split(Params,<<",">>,[global]),
    <<BHH:2/binary,BMM:2/binary,BSS/binary>> = BUTC,
    SS = case binary:split(BSS,<<".">>) of
           [_,_] -> binary_to_float(BSS);
           _ -> binary_to_integer(BSS)
         end,
    [HH,MM,D,M,Y,ZD,ZM] = [safe_binary_to_integer(X) || X <- [BHH,BMM,BD,BM,BY,BZD,BZM]],
    UTC = 60*(60*HH + MM) + SS,
    {nmea,{zda, UTC, D, M, Y, ZD, ZM}}
  catch
    error:_ -> {error, {parseError, zda, Params}}
  end;

%% LBL location
%% $-EVOLBL,Type,Frame,Loc_no,Ser_no,Lat,Lon,Alt,Pressure,CF1,CF2,CF2
%% Alt - meters
%% Pressure - dbar
%% Type: I or C
%% Frame: N (ned), G (geod), L (local), r (reserved)
%% I - initialized georeferenced position
%% C - calibrated georeferenced position
%% D - undefined position
extract_nmea(<<"EVOLBL">>, Params) ->
  try
    [BType,BFrame,BLoc,BSer,BLat,BLon,BAlt,BPressure,_,_,_] = binary:split(Params,<<",">>,[global]),
    Type = binary_to_list(BType),
    Frame = binary_to_list(BFrame),
    [Loc,Ser] = [safe_binary_to_integer(X) || X <- [BLoc,BSer]],
    [Lat,Lon,Alt,Pressure] = [safe_binary_to_float(X) || X <- [BLat,BLon,BAlt,BPressure]],
    {nmea, {evolbl, Type, Frame, Loc, Ser, Lat, Lon, Alt, Pressure, nothing, nothing, nothing}}
  catch
    error:_ -> {error, {parseError, evolbl, Params}}
  end;

%% LBL position
%% $-EVOLBP,Timestamp,Tp_array,Type,Status,Frame,Lat,Lon,Alt,Pressure,Major,Minor,Direction,SMean,Std
%% Timestamp hhmmss.ss
%% Tp_array c--c %% B01B02B04 %% our case 1:2:3:4
%% Type a- %% R1 or T1 %% in our case just address
%% Status A %% OK | or others
%% Frame: N (ned), G (geod), L (local), r (reserved)
extract_nmea(<<"EVOLBP">>, Params) ->
  try
    [BUTC,BArray,BAddress,BStatus,BFrame,BLat,BLon,BAlt,BPressure,BMa,BMi,BDir,Bsmean,Bstd] = binary:split(Params,<<",">>,[global]),
    Frame = binary_to_list(BFrame),
    Basenodes = if BArray == <<>> -> [];
                   true -> [binary_to_integer(Bnode) || Bnode <- binary:split(BArray, <<":">>, [global])]
                end,
    <<BHH:2/binary,BMM:2/binary,BSS/binary>> = BUTC,
    SS = case binary:split(BSS,<<".">>) of
           [_,_] -> binary_to_float(BSS);
           _ -> binary_to_integer(BSS)
         end,
    [HH,MM] = [safe_binary_to_integer(X) || X <- [BHH,BMM]],
    UTC = 60*(60*HH + MM) + SS,
    Status = binary_to_list(BStatus),
    Address = binary_to_integer(BAddress),
    [Lat,Lon,Alt,Pressure,SMean,Std,Ma,Mi,Dir] = [safe_binary_to_float(X) || X <- [BLat,BLon,BAlt,BPressure,Bsmean,Bstd,BMa,BMi,BDir]],
    {nmea, {evolbp, UTC, Basenodes, Address, Status, Frame, Lat, Lon, Alt, Pressure, Ma, Mi, Dir, SMean, Std}}
  catch
    error:_ -> {error, {parseError, evolbp, Params}}
  end;

%%
%% $-SIMSVT,Description,TotalPoints,Index,Depth1,Sv1,Depth2,Sv2,Depth3,Sv3,Depth4,Sv4
%% Only "P" supported
%% Description  a_  "P" indicates profile used. "M" for manual parameters. "R" indicates request for data.
%% TotalPoints  x   Total number of points in the sound profile
%% Index        x   The index for the first point in this telegram, a range from 0 to (TotalPoints -1)
%% Depth[1-4]   x.x Depth for the next sound velocity [m].
%% Sv[1-4]      x.x Sound velocity for the previous depth [m/s].
extract_nmea(<<"SIMSVT">>, Params) ->
  try
    [<<"P">>,BTotal,BIdx,BD1,DS1,BD2,BS2,BD3,BS3,BD4,BS4] = binary:split(Params,<<",">>,[global]),
    [Total,Idx] = [binary_to_integer(X) || X <- [BTotal,BIdx]],
    Lst = foldl(fun({BD,BS},Acc) ->
                    case {safe_binary_to_float(BD),safe_binary_to_float(BS)} of
                      {D,S} when is_float(D), is_float(S) -> [{D,S} | Acc];
                      _ -> Acc
                    end
                end, [], [{BD1,DS1},{BD2,BS2},{BD3,BS3},{BD4,BS4}]),
    {nmea, {simsvt, Total, Idx, Lst}}
  catch
    error:_ -> {error, {parseError, simsvt, Params}}
  end;

%% $PSXN,10,Tok,Roll,Pitch,Heave,UTC,*xx
%% 10      x         Message type (Roll, Pitch and Heave)
%% Roll    x.x       Roll in degrees. Positive with port side up.
%% Pitch   x.x       Pitch in degrees. Positive is bow up. (NED)
%% Heave   x.x       Heave in meters. Positive is down.
%% $PSXN,23,Roll,Pitch,Heading,Heave
%% 23      x         Message type (Roll, Pitch, Heading and Heave)
%% Roll    x.x       Roll in degrees. Positive with port side up.
%% Pitch   x.x       Pitch in degrees. Positive is bow up. (NED)
%% Heading x.x       Heading in degrees true.
%% Heave   x.x       Heave in meters. Positive is down.
%% Example: $PSXN,23,0.02,-0.76,330.56,*0B
extract_nmea(<<"SXN">>, Params) ->
  try
    [Type | Rest] = binary:split(Params,<<",">>,[global]),
    case Type of
      <<"10">> ->
        [BTok,BRoll,BPitch,BHeave,BUTC | _] = Rest,
        R2D = 180.0 / math:pi(),
        {ok,[Roll],[]} = io_lib:fread("~f", binary_to_list(BRoll)),
        {ok,[Pitch],[]} = io_lib:fread("~f", binary_to_list(BPitch)),
        {ok,[Heave],[]} = io_lib:fread("~f", binary_to_list(BHeave)),
        {ok,[UTC],[]} = io_lib:fread("~f", binary_to_list(BUTC)),
        Tok = safe_binary_to_integer(BTok),
        {nmea, {sxn, 10, Tok, Roll * R2D, Pitch * R2D, Heave, UTC, nothing}};
      <<"23">> ->
        [Roll, Pitch, Heading, Heave] = [safe_binary_to_float(X) || X <- Rest],
        {nmea, {sxn, 23, Roll, Pitch, Heading, Heave}};
      _ -> {error, {unsupported, sxn, Params}}
    end
  catch error:_ -> {error, {parseError, sxn, Params}}
  end;

%% $PSAT,HPR,TIME,HEADING,PITCH,ROLL,TYPE*CC<CR><LF>
%% UTC     hhmmss.ss UTC of position
%% Heading x.x       Heading in degrees true.
%% Pitch   x.x       Pitch in degrees. Positive is bow up. (NED)
%% Roll    x.x       Roll in degrees. Positive with port side up.
%% Type    a_        Type N=gps or G=Gyro.
extract_nmea(<<"SAT">>, Params) ->
  try
    [Type | Rest] = lists:sublist(binary:split(Params,<<",">>,[global]),6),
    case Type of
      <<"HPR">> ->
        [BUTC,BHeading,BPitch,BRoll,BType] = Rest,
        [Roll,Pitch,Heading] = [safe_binary_to_float(X) || X <- [BRoll,BPitch,BHeading]],
        UTC = extract_utc(BUTC),
        MType = case BType of <<"N">> -> gps; <<"G">> -> gyro; _ -> unknown end,
        {nmea, {sat, hpr, UTC, Heading, Pitch, Roll, MType}};
      _ -> {error, {parseError, sat_hpr, Params}}
    end
  catch error:_ -> {error, {parseError, sat_hpr, Params}}
  end;

%% format desc from:
%%      https://github.com/rock-drivers/drivers-phins_ixsea/blob/master/src/PhinsStandardParser.cpp
%%
%% $PIXSE,ATITUD,Roll,Pitch
%% Roll     x.x     Roll in degrees
%% Pitch    x.x     Pitch in degrees
%%
%% $PIXSE,POSITI,Lat,Lon,Alt*71
%% Lat     x.x     Latitude in degrees
%% Lon     x.x     Longitude in degrees
%% Alt     x.x     Altitude in meters
%%
%% $PIXSE,ATITUD,-1.641,-0.490*6D
%% $PIXSE,POSITI,53.10245714,8.83994382,-0.115*71
extract_nmea(<<"IXSE">>, Params) ->
  try
    [Type | Rest] = lists:sublist(binary:split(Params,<<",">>,[global]),4),
    case Type of
      <<"ATITUD">> ->
        [BRoll,BPitch] = Rest,
        [Roll,Pitch] = [safe_binary_to_float(X) || X <- [BRoll,BPitch]],
        {nmea, {ixse, atitud, Roll, Pitch}};
      <<"POSITI">> ->
        [BLat,BLon,BAlt] = Rest,
        [Lat,Lon,Alt] = [safe_binary_to_float(X) || X <- [BLat,BLon,BAlt]],
        {nmea, {ixse, positi, Lat, Lon, Alt}};
      _ -> {error, {parseError, ixse, Params}}
    end
  catch error:_ -> {error, {parseError, ixse, Params}}
  end;

%% $PASHR,hhmmss.ss,HHH.HH,T,RRR.RR,PPP.PP,---,rr.rrr,pp.ppp,hh.hhh,1,1*32
%% hhmmss.ss    -- UTC-time
%% HHH.HH       -- Heading (inertial azimuth from IMU gyros and SPAN filters)
%% T            -- True heading is relative to true north
%% RRR.RR       -- Roll. ± is always displayed
%% PPP.PP       -- Pitch. ± is always displayed
%% ---          -- Reserverd
%% rr.rrr       -- Roll STD
%% pp.ppp       -- Pitch STD
%% hh.hhh       -- Heading STD
%% 1            -- GPS quality (0 -- no pos, 1 -- non-rtk, 2 -- rtk)
%% 1            -- INS status (0 -- All SPAN pre-alignment, 1 -- post-alignment)
%%
%% $PASHR,,,,,,,,,,0,0*74 (empty)
%% $PASHR,200345.00,78.00,T,-3.00,+2.00,+0.00,1.000,1.000,1.000,1,1*32
extract_nmea(<<"ASHR">>, Params) ->
  try
    [BUTC,BHeading,BTrue,BRoll,BPitch,BRes,BRollSTD,BPitchSTD,BHeadingSTD,BGPSq | LINSq] = binary:split(Params,<<",">>,[global]),
    UTC = extract_utc(BUTC),
    [Heading,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD] = [safe_binary_to_float(X) || X <- [BHeading,BRoll,BPitch,BRes,BRollSTD,BPitchSTD,BHeadingSTD]],
    GPSq = safe_binary_to_integer(BGPSq),
    INSq = case LINSq of
               [BINSq] -> safe_binary_to_integer(BINSq);
               _ -> nothing
           end,
    True = case BTrue of <<"T">> -> true; _ -> false end,
    {nmea, {ashr,UTC,Heading,True,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq}}
  catch
    error:_ -> {error, {parseError, ashr, Params}}
  end;

%% $PRDID,PPP.PP,RRR.RR,xxx.xx
%% PPP.PP  x.x       Pitch in degrees
%% RRR.RR  x.x       Roll in degrees
%% xxx.xx  x.x       Heading in degrees true.
extract_nmea(<<"RDID">>, Params) ->
  try
    [Pitch,Roll,Heading] = [safe_binary_to_float(X) || X <- lists:sublist(binary:split(Params,<<",">>,[global]),3)],
    {nmea, {rdid, Pitch, Roll, Heading}}
  catch error:_ -> {error, {parseError, rdid, Params}}
  end;

%% $PHOCT,01,hhmmss.sss,G,AA,HHH.HHH,N,eRRR.RRR,L,ePP.PPP,K,eFF.FFF,M,eHH.HHH,eSS.SSS,eWW.WWW,eZZ.ZZZ,eYY.YYY,eXX.XXX,eQQQ.QQ
%% 01       xx      Protovol version id
%% hhmmss.sss   s   UTC-time
%% G            c   UTC status (T -- valid, E -- invalid)
%% AA           xx  INS latency (03)
%% HHH.HHH      x.x Heading
%% N            c   Heading status (T -- valid, E -- invalid, I -- initializing)
%% eRRR.RRR     x.x Roll in deg (± always shown, positive -- port up)
%% L            c   Roll status (T -- valid, E -- invalid, I -- initializing)
%% ePPP.PPP     x.x Pitch in deg (± always shown, positive -- bow down)
%% K            c   Pitch status (T -- valid, E -- invalid, I -- initializing)
%% eFF.FFF      x.x Heave (primary lever-arms )in meters (± always shown, positive -- up)
%% K            c   Heave,surge,sway,speed status (T -- valid, E -- invalid, I -- initializing)
%% eHH.HHH      x.x Heave (chosen lever-arms) in meters (± always shown, positive -- up)
%% eSS.SSS      x.x Surge (chosen lever-arms) in meters (± always shown)
%% eWW.WWW      x.x Sway (chosen lever-arms) in meters (± always shown)
%% eZZ.ZZZ      x.x Heave speed in meters (± always shown)
%% eYY.YYY      x.x Surge speed in meters (± always shown)
%% eXX.XXX      x.x Sway speed in meters (± always shown)
%% eQQQQ.QQ     x.x Heading rate of turns in deg/min (± always shown)
extract_nmea(<<"HOCT">>, Params) ->
  S = fun(<<"T">>) -> valid; (<<"E">>) -> invalid; ("I") -> initialization; (_) -> unknown end,
  try
    [Ver | Rest] = lists:sublist(binary:split(Params,<<",">>,[global]),19),
    case Ver of
      <<"01">> ->
        [BUTC,BTmS,BLt,BHd,BHdS,BRl,BRlS,BPt,BPtS,BHvI,BHvS,BHv,BSr,BSw,BHvR,BSrR,BSwR,BHdR] = Rest,
        UTC = extract_utc(BUTC),
        [Hd,Rl,Pt,HvI,Hv,Sr,Sw,HvR,SrR,SwR,HdR] = [safe_binary_to_float(X) || X <- [BHd,BRl,BPt,BHvI,BHv,BSr,BSw,BHvR,BSrR,BSwR,BHdR]],
        Lt = safe_binary_to_integer(BLt),
        TmS = S(BTmS),
        HdS = S(BHdS),
        RlS = S(BRlS),
        PtS = S(BPtS),
        HvS = S(BHvS),
        {nmea, {hoct,1,UTC,TmS,Lt,Hd,HdS,Rl,RlS,Pt,PtS,HvI,HvS,Hv,Sr,Sw,HvR,SrR,SwR,HdR}};
      _ -> {error, {parseError, hoct_01, Params}}
    end
  catch error:_ -> {error, {parseError, hoct_01, Params}}
  end;

%% $PEVO,Request
%% Request c--c NMEA senstence request
extract_nmea(<<"EVO">>, Params) ->
  try
    BName = Params,
    {nmea, {'query', evo, binary_to_list(BName)}}
  catch
    error:_ -> {error, {parseError, evo, Params}}
  end;

%% $-EVOTAP,Forward,Right,Down,Spare1,Spare2,Spare3
%% Forward x.x forward offset in meters
%% Right   x.x rights(starboard) offset in meters
%% Down    x.x downwards offset in meters
extract_nmea(<<"EVOTAP">>, Params) ->
  try
    [BForward,BRight,BDown,_,_,_] = binary:split(Params,<<",">>,[global]),
    [Forward,Right,Down] = [safe_binary_to_float(X) || X <- [BForward,BRight,BDown]],
    {nmea, {evotap,Forward,Right,Down}}
  catch
    error:_ -> {error, {parseError, evotap, Params}}
  end;

%% $-EVOTDP,Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll
%% Transceiver x    Transceiver address
%% Max_range   x    in meters
%% Sequence    c__c ":" separated address sequence
%% LAx         x.x  lever_arm forward offset in meters
%% LAy         x.x  lever_arm rights(starboard) offset in meters
%% LAz         x.x  lever_arm downwards offset in meters
%% HL          x.x  housing arm from pressure sensor to transducer in meters (down is positive)
%% Yaw         x.x  NED reference frame adjustment, yaw in degrees   (Spare)
%% Pitch       x.x  NED reference frame adjustment, pitch in degrees (Spare)
%% Roll        x.x  NED reference frame adjustment, roll in degrees  (Spare)
extract_nmea(<<"EVOTDP">>, Params) ->
  try
    [BTransceiver,BMax_range,BSequence,BLAx,BLAy,BLAz,BHL,BYaw,BPitch,BRoll] = binary:split(Params,<<",">>,[global]),
    [Transceiver,Max_range] = [safe_binary_to_integer(X) || X <- [BTransceiver,BMax_range]],
    [LAx,LAy,LAz,HL,Yaw,Pitch,Roll] = [safe_binary_to_float(X) || X <- [BLAx,BLAy,BLAz,BHL,BYaw,BPitch,BRoll]],
    Sequence = [safe_binary_to_integer(X) || X <- binary:split(BSequence,<<":">>, [global])],
    {nmea, {evotdp, Transceiver, Max_range, Sequence, LAx,LAy,LAz,HL,Yaw,Pitch,Roll}}
  catch
    error:_ -> {error, {parseError, evotdp, Params}}
  end;

%% $-EVOTPC,Pair,Praw,Ptrans,PtransS,Yaw,Pitch,Roll,S_ahrs,HL
%% Pair       x.x air pressure in dBar
%% Praw       x.x pressure sensor reading in dBar
%% Ptrans     x.x pressure sensor on the transducer level in dBar
%% PtransS    a_  ''/'R'/'I'/'N' for undefined/raw/interpolated/ready
%% Yaw        x.x NED reference frame, yaw in degrees
%% Pitch      x.x NED reference frame, pitch in degrees
%% Roll       x.x NED reference frame, roll in degrees
%% S_ahrs     a_  ''/'R'/'I'/'N' for undefined/raw/interpolated/ready
%% HL         x.x housing arm from pressure sensor to transducer in meters (down is positive)
extract_nmea(<<"EVOTPC">>, Params) ->
  try
    [BPair,BPraw,BPtrans,BTransS,BYaw,BPitch,BRoll,BAHRSS,BHL] = binary:split(Params,<<",">>,[global]),
    [Pair,Praw,Ptrans,HL,Yaw,Pitch,Roll] = [safe_binary_to_float(X) || X <- [BPair,BPraw,BPtrans,BHL,BYaw,BPitch,BRoll]],
    Status = fun(<<"">>) -> undefined;
                (<<$R>>) -> raw;
                (<<$I>>) -> interpolated;
                (<<$N>>) -> ready
             end,
    PS = Status(BTransS),
    AHRSS = Status(BAHRSS),
    {nmea, {evotpc,Pair,Praw,{Ptrans,PS},{Yaw,Pitch,Roll,AHRSS},HL}}
  catch
    error:_ -> {error, {parseError, evotpc, Params}}
  end;

%% $-EVORCM,RX,RX_phy,Src,P_src,TS,A1:...:An,TS1:...:TSn,TD1:...TDn,TDOA1:...:TDOAn
%% static or dynamic related to the transudcer, not to Src or A1:...:An
%% RX              hhmmss.ss UTC of reception
%% RX_phy          x         Physical clock value of the reception
%% Src             x       Source address
%% RSSI            x         RSSI of the received signal
%% Int             x         Signal integrity
%% P_src           x.x       Pressure @ Src
%% TS              x       Propagation time in us, static
%% A1:...:An       x:x:...:x Other addresses, ":" separated related to Src
%% TS1:...:TSn     x:x:...:x Propagation time to Ai, us, static
%% TD1:...TDn      x:x:...:x Propagation time to Ai, us, dynamic
%% TDOA1:...:TDOAn x:x:...:x Time difference of arrival between Src and Ai
extract_nmea(<<"EVORCM">>, Params) ->
  try
    [BRX,BRXP,BSrc,BRSSI,BInt,BPSrc,BTS,BAS,BTSS,BTDS,BTDOAS] = binary:split(Params,<<",">>,[global]),
    RX_utc = extract_utc(BRX),
    [RX_phy,Src,TS,RSSI,Int] = [safe_binary_to_integer(X) || X <- [BRXP,BSrc,BTS,BRSSI,BInt]],
    PSrc = safe_binary_to_float(BPSrc),
    [AS,TSS,TDS,TDOAS] = [[safe_binary_to_integer(X) || X <- binary:split(Y,<<":">>, [global])]
                          || Y <- [BAS,BTSS,BTDS,BTDOAS]],
    {nmea, {evorcm,RX_utc,RX_phy,Src,RSSI,Int,PSrc,TS,AS,TSS,TDS,TDOAS}}
  catch
    error:_ -> {error, {parseError, evorcm, Params}}
  end;

%% $-EVOSEQ,sid,total,maddr,range,seq
%% sid - sequence id (0..total-1)
%% total - number of sequences
%% maddr - master address
%% range - range in meters
%% seq - sequence of addresses
%% $PEVOSEQ,0,2,7,6000,1:2:3:4:5:6
%% $PEVOSEQ,1,2,8,6000,1:2:3:4:5:6
%% reset existing sequences on reception of sid 0,
%% store sequences on reception of total-1
extract_nmea(<<"EVOSEQ">>, Params) ->
  try
    [BSID,BTotal,BMaddr,BRange,BSeq] = binary:split(Params,<<",">>,[global]),
    [Sid,Total,MAddr,Range] = [safe_binary_to_integer(X) || X <- [BSID,BTotal,BMaddr,BRange]],
    Seq = [safe_binary_to_integer(X) || X <- binary:split(BSeq,<<":">>, [global])],
    {nmea, {evoseq,Sid,Total,MAddr,Range,Seq}}
  catch error:_ -> {error, {parseError, evoseq, Params}}
  end;

%% $-EVORCT,TX,TX_phy,Lat,LatS,Lon,LonS,Alt,S_gps,Pressure,S_pressure,Yaw,Pitch,Roll,S_ahrs,LAx,LAy,LAz,HL
%% TX         hhmmss.ss UTC of transmittion
%% TX_phy     x         Physical clock value of the transmission
%% Lat        x.x       Transducer coordinates: Latitude, degrees
%% N or S     a_
%% Lon        x.x       Longitude, degrees
%% E or W     a_
%% Alt        x.x       Antenna altitude above/below mean sea level (geoid)
%% S_gps      a_        ''/'R'/'I'/'N' for undefined/raw/interpolated/ready
%% Pressure   x.x       Pressure on transducer in dBar
%% S_pressure a_        ''/'R'/'I'/'N' for undefined/raw/interpolated/ready
%% Yaw        x.x       in degrees
%% Pitch      x.x       in degrees
%% Roll       x.x       in degrees
%% S_ahrs     a_        ''/'R'/'I'/'N' for undefined/raw/interpolated/ready
%% LAx        x.x       lever_arm forward offset in meters
%% LAy        x.x       lever_arm rights(starboard) offset in meters
%% LAz        x.x       lever_arm downwards offset in meters
%% HL         x.x       housing arm from pressure sensor to transducer in meters (down is positive)
extract_nmea(<<"EVORCT">>, Params) ->
  try
    [BTX,BTXP,BLat,BN,BLon,BE,BAlt,BGPSS,BP,BPS,BYaw,BPitch,BRoll,BAHRSS,BLx,BLy,BLz,BHL] = binary:split(Params,<<",">>,[global]),
    [TX_utc, Lat, Lon] = extract_geodata(BTX, BLat, BN, BLon, BE),
    Status = fun(<<"">>) -> undefined;
                (<<$R>>) -> raw;
                (<<$I>>) -> interpolated;
                (<<$N>>) -> ready
             end,
    [GPSS, PS, AHRSS] = [Status(X) || X <- [BGPSS,BPS,BAHRSS]],
    TX_phy = safe_binary_to_integer(BTXP),
    [Alt,P,Yaw,Pitch,Roll,Lx,Ly,Lz,HL] = [safe_binary_to_float(X) || X <- [BAlt,BP,BYaw,BPitch,BRoll,BLx,BLy,BLz,BHL]],
    GPS = {Lat, Lon, Alt, GPSS},
    Pressure = {P, PS},
    AHRS = {Yaw, Pitch, Roll, AHRSS},
    Lever_arm = {Lx,Ly,Lz},
    {nmea, {evorct,TX_utc,TX_phy,GPS,Pressure,AHRS,Lever_arm,HL}}
  catch
    error:_ -> {error, {parseError, evorct, Params}}
  end;

%% $-EVORCP,Type,Status,Substatus,Int_interval,Mode,Cycles,Broadcast,Spare1,Spare2
%% Type         a_   "S" indicates standard interogation loop
%%                   "G" indicates georeferencing interogation
%%                   "Rn" remote interogation loop start
%%                   "Cn" remote interogation loop start with calibrated basenode position transmission
%% Status       a_   "A" indicates activate , "D" indicates deactivate,
%%                   "U" undefined state (activation or deactivation failed)
%% Substatus    c__c Transciever status: "SWITCH" for "A"/"D" or some Message (to be defined)
%%                   "SWITCH" indicates switch to activate/deactivate remote interogation
%% Int_interval x.x  in "P" mode: interrogation interval [s], 0.0 indicates fast as possible
%%                   in "R" mode: mean interrogation interval [s]
%% Mode         a_   "P" for sequential interrogation
%%                   "R" for random interrogation
%% Cycles       x    Number of interrogation cycles, non-stop if undefined
%% Broadcast    a_   Broadcast own position, "B" to activate, otherwise empty field
%%
%% Example: $PEVORCP,G,A,,0.0,P,,,,
%%          $PEVORCP,S,D,,,,,,
%%          $PEVORCP,S,A,,0.0,P,,B,,
extract_nmea(<<"EVORCP">>, Params) ->
  try
    [BType,BStatus,BSub,BInt,BMode,BCycles,BCast,_,_] = binary:split(Params,<<",">>,[global]),
    Type = case BType of
             <<"G">> -> georeference;
             <<"S">> -> standard;
             <<"R",BAddr/binary>> -> {remote, safe_binary_to_integer(BAddr)};
             <<"C",BAddr/binary>> -> {remote_calibrated, safe_binary_to_integer(BAddr)};
             _ -> nothing
           end,
    Substatus = binary_to_list(BSub),
    case BStatus of
      <<"A">> ->
        Status = activate,
        Interval = safe_binary_to_float(BInt),
        Mode = case BMode of
                 <<"P">> -> pa;
                 <<"R">> -> ra
               end,
        Broadcast = case BCast of
                      <<"B">> -> broadcast;
                      _ -> nothing
                    end,
        Cycles = case safe_binary_to_integer(BCycles) of
                   nothing -> inf;
                   V -> V
                 end,
        {nmea, {evorcp, Type, Status, Substatus, Interval, Mode, Cycles, Broadcast, nothing, nothing}};
      <<"D">> ->
        Status = deactivate,
        {nmea, {evorcp, Type, Status, Substatus}};
      <<"U">> ->
        {nmea, {evorcp, Type, undefined, Substatus}} %% for remote operation
    end
  catch
    error:_ -> {error, {parseError, evorcp, Params}}
  end;

%% $-EVOACA,UTC,DID,action,duration
%% UTC hhmmss.ss
%% DID transceiver ID
%% action - action
extract_nmea(<<"EVOACA">>, Params) ->
  try
    [BUTC,BDID,BAction,BDuration] =
      lists:sublist(binary:split(Params,<<",">>,[global]),4),
    UTC = extract_utc(BUTC),
    DID = safe_binary_to_integer(BDID),
    Duration = safe_binary_to_integer(BDuration),
    Action = case BAction of
                 <<"S">> -> send;
                 <<"R">> -> recv
             end,
    {nmea, {evoaca, UTC, DID, Action, Duration}}
  catch
    error:_ -> {error, {parseError, evoaca, Params}}
  end;

%% $PEVOSSB,UTC,TID,DID,CF,OP,Tr,X,Y,Z,Acc,RSSI,Integrity,ParamA,ParamB
%% UTC hhmmss.ss
%% TID transponder ID
%% DID transceiver ID
%% CF coordinate frame: T (transceiver frame), B (body frame, xyz), H (horizontal, head-up), N (north-up), E (east-up), G (geodetic, wgs84)
%% OP origin point: T (transceiver), V (vessel CRP)
%% Tr transformations: R (raw), T (raytraced), P (pressure aided)
%% X,Y,Z coordinates
%% Acc accuracy in meters
%% RSSI, Integrity: signal parameters
%% ParamA, ParamB:
%%    for B,*,T: ray-len, tgt-elevation
%%    for *,*,P: top-pressure, bottom-pressure
%%    for H,*,*: roll, pitch
%%    for N,*,*: heading
extract_nmea(<<"EVOSSB">>, Params) ->
  try
    [BUTC,BTID,BDID,BCF,BOP,BTr,BX,BY,BZ,BAcc,BRSSI,BInt,BParmA,BParmB] =
      lists:sublist(binary:split(Params,<<",">>,[global]),14),
    UTC = extract_utc(BUTC),
    [TID,DID,RSSI,Int] = [safe_binary_to_integer(V) || V <- [BTID,BDID,BRSSI,BInt]],
    [X,Y,Z,Acc,ParmA,ParmB] = [safe_binary_to_float(V) || V <- [BX,BY,BZ,BAcc,BParmA,BParmB]],
    CF = case BCF of
             <<"T">> -> transceiver;
             <<"B">> -> xyz;
             <<"H">> -> xyd;
             <<"N">> -> ned;
             <<"E">> -> enu;
             <<"G">> -> geod
         end,
    OP = case BOP of
             <<"T">> -> transceiver;
             <<"V">> -> crp;
             <<"">> -> nothing
         end,
    Tr = case BTr of
           <<"U">> -> unprocessed;
           <<"R">> -> raw;
           <<"T">> -> raytraced;
           <<"P">> -> pressure;
           <<"F">> -> filtered;
           <<"">> -> nothing
         end,
    {nmea, {evossb, UTC, TID, DID, CF, OP, Tr, X, Y, Z, Acc, RSSI, Int, ParmA, ParmB}}
  catch
    error:_ -> {error, {parseError, evossb, Params}}
  end;

%% $PEVOSSA,UTC,TID,CF,Tr,B,E,Acc,RSSI,Integrity,ParamA,ParamB
%% UTC hhmmss.ss
%% TID transponder ID
%% DID transceiver ID
%% CF coordinate frame: T (transceiver frame), B (body frame, xyz), H (horizontal, head-up), N (north-up), E (east-up)
%% Tr transformations: R (raw), T (raytraced), P (pressure aided)
%% B,E bearing and elevation angles [degrees]
%% Acc accuracy in meters
%% RSSI
%% Integrity
%% ParamA,ParamB: Pr, Vel
%%      Pr pressure in dBar (blank, if not available)
%%      Vel velocity in m/s
extract_nmea(<<"EVOSSA">>, Params) ->
  try
    [BUTC,BTID,BDID,BCF,BTr,BB,BE,BAcc,BRSSI,BInt,BParmA,BParmB] =
      lists:sublist(binary:split(Params,<<",">>,[global]),12),
    UTC = extract_utc(BUTC),
    [TID,DID,RSSI,Int] = [safe_binary_to_integer(V) || V <- [BTID,BDID,BRSSI,BInt]],
    [B,E,Acc,ParmA,ParmB] = [safe_binary_to_float(V) || V <- [BB,BE,BAcc,BParmA,BParmB]],
    CF = case BCF of
             <<"T">> -> transceiver;
             <<"B">> -> xyz;
             <<"H">> -> xyd;
             <<"N">> -> ned;
             <<"E">> -> enu
         end,
    Tr = case BTr of
           <<"U">> -> unprocessed;
           <<"R">> -> raw;
           <<"T">> -> raytraced;
           <<"P">> -> pressure
         end,
    {nmea, {evossa, UTC, TID, DID, CF, Tr, B, E, Acc, RSSI, Int, ParmA, ParmB}}
  catch
    error:_ -> {error, {parseError, evossa, Params}}
  end;

%% $PEVOGPS,UTC,TID,DID,M,Lat,LatPole,Lon,LonPole,Alt
%% UTC hhmmss.ss
%% TID point ID (FTID)
%% DID device ID
%% M mode: M measured, C computed, F filtered
%% Lat Latitude
%% LatPole N or S
%% Lon Longitude
%% LonPole E or W
%% Alt Altitude over Geoid
extract_nmea(<<"EVOGPS">>, Params) ->
  try
    [BUTC,BTID,BDID,BM,BLat,BN,BLon,BE,BAlt] =
      lists:sublist(binary:split(Params,<<",">>,[global]),9),
    [UTC, Lat, Lon] = extract_geodata(BUTC, BLat, BN, BLon, BE),
    TID = safe_binary_to_integer(BTID),
    DID = safe_binary_to_integer(BDID),
    Alt = safe_binary_to_float(BAlt),
    Mode = case BM of
           <<"M">> -> measured;
           <<"F">> -> filtered;
           <<"C">> -> computed
         end,
    {nmea, {evogps, UTC, TID, DID, Mode, Lat, Lon, Alt}}
  catch
    error:_ -> {error, {parseError, evogps, Params}}
  end;

%% $PEVORPY,UTC,TID,DID,M,Roll,Pitch,Yaw
%% UTC hhmmss.ss
%% TID point ID (FTID)
%% DID device ID
%% M mode: M measured, C computed, F filtered
extract_nmea(<<"EVORPY">>, Params) ->
  try
    [BUTC,BTID,BDID,BM,BRoll,BPitch,BYaw] =
      lists:sublist(binary:split(Params,<<",">>,[global]),7),
    UTC = extract_utc(BUTC),
    TID = safe_binary_to_integer(BTID),
    DID = safe_binary_to_integer(BDID),
    [Roll, Pitch, Yaw] = [safe_binary_to_float(X) || X <- [BRoll, BPitch, BYaw]],
    Mode = case BM of
           <<"M">> -> measured;
           <<"F">> -> filtered;
           <<"C">> -> computed
         end,
    {nmea, {evorpy, UTC, TID, DID, Mode, Roll, Pitch, Yaw}}
  catch
    error:_ -> {error, {parseError, evorpy, Params}}
  end;

%% $PEVOCTL,BUSBL,...
%% ID - configuration id (BUSBL/SBL...)
%% $PEVOCTL,BUSBL,Lat,N,Lon,E,Alt,Mode,IT,MP,AD
%% Lat/Lon/Alt x.x reference coordinates
%% Mode        a   interrogation mode (S = silent / T  = transponder / <I1>:...:<In> = interrogation sequence / T:<I> transition to <I>)
%% IT          x   interrogation period in us
%% MP          x   max pressure id dBar (must be equal on all the modems)
%% AD          x   answer delays in us
extract_nmea(<<"EVOCTL">>, <<"BUSBL,",Params/binary>>) ->
  try
    [BLat,BN,BLon,BE,BAlt,BMode,BIT,BMP,BAD] =
      lists:sublist(binary:split(Params,<<",">>,[global]),9),
    [_, Lat, Lon] = safe_extract_geodata(nothing, BLat, BN, BLon, BE),
    Alt = safe_binary_to_float(BAlt),
    Mode = case BMode of
             <<>> -> nothing;
             <<"S">> -> silent;
             <<"T:",BV/binary>> -> {transitional, binary_to_integer(BV)};
             <<"T">> -> transponder;
             _ -> [binary_to_integer(BI) || BI <- binary:split(BMode, <<":">>, [global])]
           end,
    [IT, MP, AD] = [safe_binary_to_integer(X) || X <- [BIT, BMP, BAD]],
    {nmea, {evoctl, busbl, {Lat, Lon, Alt, Mode, IT, MP, AD}}}
  catch
    error:_ ->
      {error, {parseError, evoctl, Params}}
  end;
%% $PEVOCTL,SBL,X,Y,Z,Mode,IT,MP,AD
%% X,Y,Z           x.x coordinates of SBL node in local frame in meters
%% Mode            a   interrogation mode (S = silent / T  = transponder / <I1>:...:<In> = interrogation sequence)
%% IT              x   interrogation timeout in us
%% MP              x   max pressure id dBar (must be equal on all the modems)
%% AD              x   answer delays in us
extract_nmea(<<"EVOCTL">>, <<"SBL,",Params/binary>>) ->
  %% try
    [BX,BY,BZ,BMode,BIT,BMP,BAD] =
      lists:sublist(binary:split(Params,<<",">>,[global]),9),
    [X,Y,Z] = [safe_binary_to_float(BV) || BV <- [BX, BY, BZ]],
    Mode = case BMode of
             <<>> -> nothing;
             <<"S">> -> silent;
             <<"T">> -> transponder;
             _ -> [binary_to_integer(BI) || BI <- binary:split(BMode, <<":">>, [global])]
           end,
    [IT, MP, AD] = [safe_binary_to_integer(Item) || Item <- [BIT, BMP, BAD]],
    {nmea, {evoctl, sbl, {X, Y, Z, Mode, IT, MP, AD}}};
  %% catch
  %%   error:_ ->{error, {parseError, evoctl, Params}}
  %% end;
%% $PEVOCTL,SUSBL,Seq,MRange,SVel
%% Seq             a   interrogation sequence (<I1>:...:<In>)
%% MRange          x   max range in m
%% SVel            x   sound velocity
extract_nmea(<<"EVOCTL">>, <<"SUSBL,",Params/binary>>) ->
  try
    [BMRange, BSVel, BSeq] =
      lists:sublist(binary:split(Params,<<",">>,[global]), 3),
    [MRange,SVel] = [safe_binary_to_float(BV) || BV <- [BMRange, BSVel]],
    Seq = case BSeq of
            <<>> -> nothing;
            _ -> [binary_to_integer(BI) || BI <- binary:split(BSeq, <<":">>, [global])]
          end,
    {nmea, {evoctl, susbl, {Seq, MRange, SVel}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
%% $PEVOCTL,TIMESYNC,Mode,Shift
%% Mode            a   L - use local time, R - remote time is synchronized
%% Shift           x   Time shift
extract_nmea(<<"EVOCTL">>, <<"TIMESYNC,",Params/binary>>) ->
  try
    [BMode,BShift] = lists:sublist(binary:split(Params,<<",">>,[global]), 2),
    Mode =
    case BMode of
        <<"L">> -> local;
        <<"R">> -> remote;
        _ -> unknown
    end,
    Shift = safe_binary_to_integer(BShift),
    {nmea, {evoctl, timesync, {Mode, Shift}}}
  catch
    error:_ ->{error, {parseError, evoctl_timesync, Params}}
  end;
%% $PEVOCTL,SINAPS,DID,Cmd,Arg
%% DID             x   device id
%% Cmd             a   command (start,stop,georef,selfpos,pos)
%% Arg             a   argument for a command (addr for pos)
extract_nmea(<<"EVOCTL">>, <<"SINAPS,",Params/binary>>) ->
  try
    [BDID,BCmd, BArg] = lists:sublist(binary:split(Params,<<",">>,[global]), 3),
    DID = binary_to_integer(BDID),
    {nmea, {evoctl, sinaps, {DID, BCmd, BArg}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
%% PEVOCTL,QLBL,CFG,<key1>,<value1>[,...,[<keyN>,<valueN>]]
%% N <= 3, keys: H (Hz), M (amap), S (source level)
extract_nmea(<<"EVOCTL">>, <<"QLBL,CFG,",Params/binary>>) ->
  try
    BLst = binary:split(Params,<<",">>,[global]),
    {nmea, {evoctl, qlbl,
            lists:foldl(fun(Idx,Map) ->
                            [BName,BValue] = lists:sublist(BLst, (Idx - 1) * 2 + 1, 2),
                            case BName of
                              <<"H">> -> Map#{freq => safe_binary_to_integer(BValue)};
                              <<"M">> ->
                                AMap = [safe_binary_to_integer(X) || X <- binary:split(BValue,<<":">>, [global])],
                                Map#{amap => AMap};
                              <<"S">> -> Map#{source_level => safe_binary_to_integer(BValue)};
                              _ -> Map
                            end
                        end, #{command => config}, lists:seq(1,length(BLst) div 2))}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
%% PEVOCTL,QLBL,REF,<lat>,<lon>,<alt>
extract_nmea(<<"EVOCTL">>, <<"QLBL,REF,",Params/binary>>) ->
  try
    BLst = lists:sublist(binary:split(Params,<<",">>,[global]), 3),
    [Lat,Lon,Alt] = [safe_binary_to_float(X) || X <- BLst],
    {nmea, {evoctl, qlbl, #{command => reference, lat => Lat, lon => Lon, alt => Alt}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
%% PEVOCTL,QLBL,TX,<src>,<code>,<counter>
extract_nmea(<<"EVOCTL">>, <<"QLBL,TX,",Params/binary>>) ->
  try
    BLst = lists:sublist(binary:split(Params,<<",">>,[global]), 3),
    [Src, Code, Cnt] = [binary_to_integer(V) || V <- BLst],
    {nmea, {evoctl, qlbl, #{command => transmit, source => Src, code => Code, counter => Cnt}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
%% PEVOCTL,QLBL,RX
extract_nmea(<<"EVOCTL">>, <<"QLBL,RX">>) ->
  {nmea, {evoctl, qlbl, #{command => stop}}};
%% PEVOCTL,QLBL,RST
extract_nmea(<<"EVOCTL">>, <<"QLBL,RST">>) ->
  {nmea, {evoctl, qlbl, #{command => reset}}};
%% PEVOCTL,QLBL,CAL,<frame>
extract_nmea(<<"EVOCTL">>, <<"QLBL,CAL,",Params/binary>>) ->
  try
    Frame = binary_to_atom(Params, utf8),
    {nmea, {evoctl, qlbl, #{frame => Frame, command => calibrate}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}    
  end;
extract_nmea(<<"EVOCTL">>, Params) ->
  {error, {parseError, evoctl, Params}};

extract_nmea(<<"EVOERR">>, Params) ->
  {nmea, {evoerr, Params}};

%% $--HDG,Heading,Devitaion,D_sign,Variation,V_sign
%% Heading        x.x magnetic sensor heading in degrees
%% Deviation      x.x deviation, degrees
%% D_sign         a   deviation direction, E = Easterly, W = Westerly
%% Variation      x.x variation, degrees
%% V_sign         a   variation direction, E = Easterly, W = Westerly
%%
%% Example: $HCHDG,271.1,10.7,E,12.2,W*52
extract_nmea(<<"HDG">>, Params) ->
  try
    [BHeading,BDev,BDevS,BVar,BVarS] = binary:split(Params,<<",">>,[global]),
    [Heading,Dev,Var] = [safe_binary_to_float(X) || X <- [BHeading,BDev,BVar]],
    DevS = case BDevS of <<"E">> -> 1; _ -> -1 end,
    VarS = case BVarS of <<"E">> -> 1; _ -> -1 end,
    {nmea, {hdg, Heading, DevS * Dev, VarS * Var}}
  catch
    error:_ -> {error, {parseError, hdg, Params}}
  end;

%% $--HDT,Heading,T
%% Heading        x.x heading in degrees, true
%%
%% Example: $HCHDT,86.2,T*15
extract_nmea(<<"HDT">>, Params) ->
  try
    [BHeading,<<"T">>] = binary:split(Params,<<",">>,[global]),
    Heading = safe_binary_to_float(BHeading),
    {nmea, {hdt, Heading}}
  catch
    error:_ -> {error, {parseError, hdt, Params}}
  end;

%% $--XDR,a,x.x,a,c--c, .....
%%  Type   a
%%  Data   x.x
%%  Units  a
%%  Name   c--c
%%  More of the same .....
%%
%% Example: $HCXDR,A,-0.8,D,PITCH,A,0.8,D,ROLL,G,122,,MAGX,G,1838,,MAGY,G,-667,,MAGZ,G,1959,,MAGT*11
extract_nmea(<<"XDR">>, Params) ->
  try
    BLst = binary:split(Params,<<",">>,[global]),
    Lst = lists:map(fun(Idx) ->
                        [BType,BData,BUnits,BName] = lists:sublist(BLst, Idx, 4),
                        Data = safe_binary_to_float(BData),
                        {binary_to_list(BType), Data, binary_to_list(BUnits), binary_to_list(BName)}
                    end, lists:seq(1, length(BLst) div 4)),
    {nmea, {xdr, Lst}}
  catch
    error:_ -> {error, {parseError, xdr, Params}}
  end;

%% $--VTG,<TMGT>,T,<TMGM>,M,<Knots>,N,<KPH>,[FAA,]K
%% TMGT  x.x Track made good (degrees true), track made good is relative to true north
%% TMGM  x.x Track made good (degrees magnetic), track made good is relative to magnetic north
%% Knots x.x speed is measured in knots
%% KPH   x.x speed over ground is measured in kph
%% FAA mode is optional
%%
%% Example: $GPVTG,054.7,T,034.4,M,005.5,N,010.2,K*48
extract_nmea(<<"VTG">>, Params) ->
  try
    [BTMGT,<<"T">>,BTMGM,<<"M">>,BKnots,<<"N">>,BKPH,<<"K">>] = lists:sublist(binary:split(Params,<<",">>,[global]),8),
    %% optional FAA mode dropped
    %% KPH = Knots * 0.539956803456
    [TMGT,TMGM,Knots,_KPH] = [safe_binary_to_float(X) || X <- [BTMGT,BTMGM,BKnots,BKPH]],
    {nmea, {vtg, TMGT,TMGM,Knots}}
  catch
    error:_ -> {error, {parseError, vtg, Params}}
  end;

%% $-TNTHPR,Heading,HStatus,Pitch,PStatus,Roll,RStatus
%% Heading x.x in degrees or mils
%% HStatus a   L/M/N/O/P/C
%% Pitch   x.x in degrees or mils
%% PStatus a   L/M/N/O/P/C
%% Roll    x.x in degrees or mils
%% RStatus a   L/M/N/O/P/C
%% Status: L = low alarm,    M = low warning, N = normal,
%%         O = high warning, P = high alarm,  C = Tuning analog circuit
%%
%% Examples:
%% $PTNTHPR,354.9,N,5.2,N,0.2,N*3A
%% $PTNTHPR,90,N,29,N,15,N*1C
extract_nmea(<<"TNTHPR">>, Params) ->
  try
    [BHeading,BHStatus,BPitch,BPStatus,BRoll,BRStatus] = binary:split(Params,<<",">>,[global]),
    [Heading, Pitch, Roll] = [case binary:split(X, <<".">>) of
                                [<<>>]  -> nothing;
                                [_I]    -> binary_to_integer(X) * 360 / 64000;  %% NATO mils to degrees
                                [_I,_F] -> binary_to_float(X);
                                _      -> nothing
                              end || X <- [BHeading,BPitch,BRoll]],
    [HStatus, PStatus, RStatus] = [binary_to_list(X) || X <- [BHStatus, BPStatus, BRStatus]],
    {nmea, {tnthpr, Heading, HStatus, Pitch, PStatus, Roll, RStatus}}
  catch
    error:_ -> {error, {parseError, tnthpr, Params}}
  end;

extract_nmea(<<"SMCS">>, Params) ->
  try
    [BRoll,BPitch,BHeave] = binary:split(Params,<<",">>,[global]),
    [Roll, Pitch, Heave] = [ safe_binary_to_float(X) || X <- [BRoll,BPitch,BHeave]],
    {nmea, {smcs, Roll, Pitch, Heave}}
  catch
    error:_ -> {error, {parseError, smcs, Params}}
  end;

extract_nmea(<<"SMCM">>, Params) ->
  try
    [BRoll,BPitch,BHeading,BSurge,BSway,BHeave,BRRoll,BRPitch,BRHeading,BAccX,BAccY,BAccZ] = binary:split(Params,<<",">>,[global]),
    [Roll,Pitch,Heading,Surge,Sway,Heave,RRoll,RPitch,RHeading,AccX,AccY,AccZ] =
        [ safe_binary_to_float(X) || X <- [BRoll,BPitch,BHeading,BSurge,BSway,BHeave,BRRoll,BRPitch,BRHeading,BAccX,BAccY,BAccZ]],
    {nmea, {smcm, Roll, Pitch, Heading, Surge, Sway, Heave, RRoll, RPitch, RHeading, AccX, AccY, AccZ}}
  catch
    error:_ -> {error, {parseError, smcm, Params}}
  end;

%% $PSIMSSB,UTC,B01,A,,C,H,M,X,Y,Z,Acc,N,,
extract_nmea(<<"SIMSSB">>, Params) ->
  try
    [BUTC,BSAddr,BS,Err,BCS,BHS,BFS,BX,BY,BDepth,BAcc,AddT,BAdd1,BAdd2] = binary:split(Params,<<",">>,[global]),
    UTC = extract_utc(BUTC),
    Addr = case BSAddr of <<"B", BAddr/binary>> -> safe_binary_to_integer(BAddr); _ -> nothing end,
    S = case BS of <<"A">> -> ok; _ -> nok end,
    {CS, DS} = case {BCS, BHS} of
                   {<<"C">>, <<"H">>} -> {lf, 1};
                   {<<"C">>, <<"E">>} -> {enu, 1};
                   {<<"C">>, <<"N">>} -> {ned, 1};
                   {<<"R">>, <<"G">>} -> {geod, -1}
               end,
    FS = case BFS of
             <<"M">> -> measured;
             <<"F">> -> filtered;
             <<"R">> -> reconstructed
         end,

    [X, Y, Depth, Acc, Add1, Add2] = [safe_binary_to_float(X) || X <- [BX, BY, BDepth, BAcc, BAdd1, BAdd2]],
    Z = case Depth of nothing -> nothing; _ -> Depth * DS end,

    {nmea, {simssb,UTC,Addr,S,Err,CS,FS,X,Y,Z,Acc,AddT,Add1,Add2}}
  catch
    error:_ -> {error, {parseError, simssb, Params}}
  end;

% $PHTRO,x.xx,a,y.yy,b*hh<CR><LF>
%   x.xx is the pitch in degrees
%       a is ‘M’ for bow up
%       a is ‘P’ for bow down
%   y.yy is the roll in degrees
%       b is ‘B’ for port down
%       b is ‘T’ for port up
%
% $PHTRO,0.16,M,0.01,T*4E
% $PHTRO,0.09,M,0.12,B*54
extract_nmea(<<"HTRO">>, Params) ->
  try
    [BPitch, PitchSign, BRoll, RollSign] = binary:split(Params,<<",">>,[global]),
    PitchFactor = case PitchSign of <<"P">> -> -1.0; _ -> 1.0 end,
    RollFactor = case RollSign of <<"B">> -> -1.0; _ -> 1.0 end,
    [Roll, Pitch] = [safe_binary_to_float(X) || X <- [BRoll, BPitch]],
    {nmea, {htro, Pitch * PitchFactor, Roll * RollFactor}}
  catch
    error:_ -> {error, {parseError, htro, Params}}
  end;

%% $--DBS,<Df>,f,<DM>,M,<DF>,F
%% Depth below surface (pressure sensor)
%% Df x.x Depth in feets
%% DM x.x Depth in meters
%% DF x.x Depth in fathoms
%%
%% Example: $SDDBS,2348.56,f,715.78,M,391.43,F*4B
extract_nmea(<<"DBS">>, Params) ->
  try
    [_BDf,<<"f">>,BDM,<<"M">>,_BDF,<<"F">>] = binary:split(Params,<<",">>,[global]),
    DM = safe_binary_to_float(BDM),
    {nmea, {dbs, DM}}
  catch
    error:_ -> {error, {parseError, dbs, Params}}
  end;

%% $--DBT,<Df>,f,<DM>,M,<DF>,F
%% Depth Below Transducer (echolot)
%% Water depth referenced to the transducer’s position. Depth value expressed in feet, metres and fathoms.
%% Df x.x Depth in feets
%% DM x.x Depth in meters
%% DF x.x Depth in fathoms
%%
%% Example: $SDDBT,8.1,f,2.4,M,1.3,F*0B
extract_nmea(<<"DBT">>, Params) ->
  try
    [_BDf,<<"f">>,BDM,<<"M">>,_BDF,<<"F">>] = binary:split(Params,<<",">>,[global]),
    DM = safe_binary_to_float(BDM),
    {nmea, {dbt, DM}}
  catch
    error:_ -> {error, {parseError, dbt, Params}}
  end;

extract_nmea(Cmd, _) ->
  {error, {notsupported, Cmd}}.

safe_fmt(Fmts,Values) ->
  lists:map(fun({_,nothing}) -> "";
               ({[$~, $+ | Fmt],V}) ->
                T = hd(lists:reverse(Fmt)),
                Value = case T of $f -> float(V); _ -> V end,
                SFmt = if V >= 0 -> [$+,$~|Fmt]; true -> [$~|Fmt] end,
                (io_lib:format(SFmt,[Value]));
               ({Fmt,V}) ->
                T = hd(lists:reverse(Fmt)),
                Value = case T of $f -> float(V); _ -> V end,
                (io_lib:format(Fmt,[Value]))
            end, lists:zip(Fmts,Values)).

safe_fmt(Fmts, Values, Join) ->
  Z = lists:reverse(lists:zip(Fmts,Values)),
  lists:foldl(fun({_,nothing},Acc) -> [Join, "" | Acc];
                 ({[$~, $+ | Fmt],V}, Acc) ->
                  T = hd(lists:reverse(Fmt)),
                  Value = case T of $f -> float(V); _ -> V end,
                  SFmt = if V >= 0 -> [$+,$~|Fmt]; true -> [$~|Fmt] end,
                  [Join, (io_lib:format(SFmt,[Value])) | Acc];
                 ({Fmt,V},Acc)     ->
                  T = hd(lists:reverse(Fmt)),
                  Value = case T of $f -> float(V); _ -> V end,
                  [Join, (io_lib:format(Fmt,[Value])) | Acc]
              end, "", Z).


utc_format(nothing) ->
  ",";
utc_format(UTC) ->
  S = erlang:trunc(UTC),
  MS = UTC - S + 0.0,
  SS = S rem 60,
  Min = erlang:trunc(S/60) rem 60,
  HH = erlang:trunc(S/3600) rem 24,
  io_lib:format(",~2.10.0B~2.10.0B~5.2.0f",[HH,Min,float(SS+MS)]).

lat_format(nothing) -> ",,";
lat_format(Lat) ->
  N = case Lat < 0 of true -> "S"; _ -> "N" end,
  LatHH = erlang:trunc(abs(Lat)),
  LatMM = (abs(Lat) - LatHH)*60,
  io_lib:format(",~2.10.0B~10.7.0f,~s",[LatHH,float(LatMM),N]).

lon_format(nothing) -> ",,";
lon_format(Lon) ->
  E = case Lon < 0 of true -> "W"; _ -> "E" end,
  LonHH = erlang:trunc(abs(Lon)),
  LonMM = (abs(Lon) - LonHH)*60,
  io_lib:format(",~3.10.0B~10.7.0f,~s",[LonHH,float(LonMM),E]).

%% hhmmss.ss,xx,xx,xxxx,xx,xx
%% hhmmss.ss = UTC
%% xx = Day, 01 to 31
%% xx = Month, 01 to 12
%% xxxx = Year
%% xx = Local zone description, 00 to +/- 13 hours
%% xx = Local zone minutes description (same sign as hours)
build_zda(UTC,DD,MM,YY,Z1,Z2) ->
  SUTC = utc_format(UTC),
  SDate = io_lib:format(",~2.10.0B,~2.10.0B,~4.10.0B,~2.10.0B,~2.10.0B", [DD,MM,YY,Z1,Z2]),
  (["GPZDA", SUTC, SDate]).

%% Example: $GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
build_rmc(UTC,Status,Lat,Lon,Speed,Tangle,Date,Magvar) ->
  SUTC = utc_format(UTC),
  SStatus = case Status of active -> ",A"; _ -> ",V" end,
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  {YY,MM,DD} = Date,
  SDate = io_lib:format("~2.10.0B~2.10.0B~2.10.0B",[DD,MM,YY rem 100]),
  {AMagvar, ME} =
    case Magvar of
      nothing -> {nothing, nothing};
      _ when Magvar < 0 -> {-Magvar, "W"};
      _ -> {Magvar, "E"}
    end,
  SRest = safe_fmt(["~.3.0f","~.3.0f","~s","~.3.0f","~s"], [Speed,Tangle,SDate,AMagvar,ME], ","),
  (["GPRMC",SUTC,SStatus,SLat,SLon,SRest]).

%% hhmmss.ss,llll.ll,a,yyyyy.yy,a,x,xx,x.x,x.x,M, x.x,M,x.x,xxxx
build_gga(UTC,Lat,Lon,Q,Sat,HDil,Alt,Geoid,Age,ID) ->
  SUTC = utc_format(UTC),
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  SRest = safe_fmt(["~B","~2.10.0B","~.1.0f","~.1.0f","~s","~.1.0f","~s","~.1.0f","~4.10.0B"],
                   [Q,Sat,HDil,Alt,"M",Geoid,"M",Age,ID],","),
  (["GPGGA",SUTC,SLat,SLon,SRest]).

%% llll.ll,a,yyyyy.yy,a,hhmmss.ss,A,a
build_gll(Lat,Lon,UTC,Status,Mode) ->
  SUTC = utc_format(UTC),
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  SStatus = case Status of active -> "A"; _ -> "V" end,
  SMode = case Mode of
              auto -> "A";
              differential -> "D";
              estimated -> "E";
              manual -> "M";
              simulated -> "S";
              _ -> "N"
          end,
  (["GPGLL",SLat,SLon,SUTC,SStatus,SMode]).

build_evolbl(Type,Frame,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure,CF1,CF2,CF3) ->
  S = safe_fmt(["~s","~s","~B","~B","~.7.0f","~.7.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f"],
               [Type,Frame,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure,CF1,CF2,CF3],","),
  (["PEVOLBL",S]).

build_evolbp(UTC, Basenodes, Address, Status, Frame, Lat_rad, Lon_rad, Alt, Pressure, Ma, Mi, Dir, SMean, Std) ->
  S = erlang:trunc(UTC),
  MS = UTC - S + 0.0,
  SS = S rem 60,
  MM = erlang:trunc(S/60) rem 60,
  HH = erlang:trunc(S/3600) rem 24,
  SUTC = io_lib:format(",~2.10.0B~2.10.0B~5.2.0f",[HH,MM,float(SS+MS)]),

  SNodes = if Basenodes == [] -> [","];
              Basenodes == nothing -> [","];
              true -> foldl(fun(Id,Acc) -> Acc ++ ":" ++ integer_to_list(Id) end, "," ++ integer_to_list(hd(Basenodes)), tl(Basenodes))
           end,
  SStd = case Std of
           nothing -> "";
           _ -> (io_lib:format("~.3.0f",[float(Std)]))
         end,
  SRest = safe_fmt(["~B","~s","~s","~.7.0f","~.7.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.3.0f","~s"],
                   [Address,Status,Frame,Lat_rad,Lon_rad,Alt,Pressure,Ma,Mi,Dir,SMean,SStd],","),
  (["PEVOLBP",SUTC,SNodes,SRest]).

build_simsvt(Total, Idx, Lst) ->
  SPoints = lists:map(fun({D,S}) ->
                          safe_fmt(["~.2.0f","~.2.0f"], [D, S], ",")
                      end, Lst),
  STail = lists:map(fun(_) -> ",," end,
                    try lists:seq(1,4-length(Lst)) catch _:_ -> [] end),
  SHead = io_lib:format(",~B,~B", [Total, Idx]),
  (["PSIMSVT,P",SHead,SPoints,STail]).

%% Example: $PSXN,10,019,5.100e-2,-5.1e-2,1.234e+0,771598427
build_sxn(10,Tok,Roll,Pitch,Heave,UTC,nothing) ->
  D2R = math:pi() / 180.0,
  SRest = safe_fmt(["~B","~.4e","~.4e","~.4e","~.4e"],
                   [Tok,Roll*D2R,Pitch*D2R,Heave,UTC], ","),
  (["PSXN,10",SRest,","]).

%% Example: $PSXN,23,0.02,-0.76,330.56,*0B
build_sxn(23,Roll,Pitch,Heading,Heave) ->
  SRest = safe_fmt(["~.2f","~.2f","~.2f","~.2f"],
                   [Roll,Pitch,Heading,Heave], ","),
  (["PSXN,23",SRest]).

%% $PSAT,HPR,TIME,HEADING,PITCH,ROLL,TYPE*CC<CR><LF>
build_sat(hpr,UTC,Heading,Pitch,Roll,Type) ->
  SUTC = utc_format(UTC),
  SHPR = safe_fmt(["~.2f","~.2f","~.2f"], [Heading,Pitch,Roll], ","),
  SType = case Type of gps -> ",N"; gyro -> ",G"; _ -> "," end,
  % почему не ставится запятая перед SType? почему она ставится перед SUTC и SHPR?
  (["PSAT,HPR",SUTC,SHPR,SType]).

%% $PIXSE,ATITUD,-1.641,-0.490*6D
build_ixse(atitud,Roll,Pitch) ->
  SPR = safe_fmt(["~.3f","~.3f"], [Roll,Pitch], ","),
  (["PIXSE,ATITUD",SPR]).

%% $PIXSE,POSITI,53.10245714,8.83994382,-0.115*71
build_ixse(positi,Lat,Lon,Alt) ->
  SPR = safe_fmt(["~.8f","~.8f","~.3f"], [Lat,Lon,Alt], ","),
  (["PIXSE,POSITI",SPR]).

%% $PASHR,200345.00,78.00,T,-3.00,+2.00,+0.00,1.000,1.000,1.000,1,1*32
build_ashr(UTC,Heading,True,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq) ->
  SUTC = utc_format(UTC),
  STrue = case True of true -> ",T"; _ -> "," end,
  SHeading = safe_fmt(["~.2f"], [Heading], ","),
  % how to printf("%+.2f", Roll); with io:format()?
  RollFmt = case Roll of N when N >= 0 -> "+~.2f"; _ -> "~.2f" end,
  PitchFmt = case Pitch of M when M >= 0 -> "+~.2f"; _ -> "~.2f" end,
  HeadingFmt = case Heading of K when K >= 0 -> "+~.2f"; _ -> "~.2f" end,
  SRest =
  case INSq of
      nothing -> safe_fmt([RollFmt,PitchFmt,HeadingFmt,"~.3f","~.3f","~.3f","~B"], [Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq], ",");
      _ -> safe_fmt([RollFmt,PitchFmt,HeadingFmt,"~.3f","~.3f","~.3f","~B","~B"], [Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq], ",")
  end,
  (["PASHR",SUTC,SHeading,STrue,SRest]).

%% $PRDID,PPP.PP,RRR.RR,xxx.xx
build_rdid(Pitch,Roll,Heading) ->
  SPRH = safe_fmt(["~.2f","~.2f","~.2f"], [Pitch,Roll,Heading], ","),
  (["PRDID",SPRH]).

%% $PHOCT,01,hhmmss.sss,G,AA,HHH.HHH,N,eRRR.RRR,L,ePP.PPP,K,eFF.FFF,M,eHH.HHH,eSS.SSS,eWW.WWW,eZZ.ZZZ,eYY.YYY,eXX.XXX,eQQQ.QQ
%% NOTE: UTC format has no microseconds (hhmmss.ss)
build_hoct(1,UTC,TmS,Lt,Hd,HdS,Rl,RlS,Pt,PtS,HvI,HvS,Hv,Sr,Sw,HvR,SrR,SwR,HdR) ->
  F = fun(Val, Fmt) when Val >= 0 -> "+" ++ Fmt; (_, Fmt) -> Fmt end,
  S = fun(valid) -> ",T"; (invalid) -> ",E"; (initializing) -> ",I"; (_) -> "," end,

  SUTC = utc_format(UTC),
  SLt  = safe_fmt(["~2.10.0B"], [Lt], ","),
  SHd  = safe_fmt([F(Hd ,"~6.3.0f")], [Hd], ","),
  SRl  = safe_fmt([F(Rl ,"~6.3.0f")], [Rl], ","),
  SPt  = safe_fmt([F(Pt ,"~6.3.0f")], [Pt], ","),
  SHvI = safe_fmt([F(HvI,"~6.3.0f")], [HvI],","),
  SRest = safe_fmt([F(Hv,"~6.3.0f"),F(Sr,"~6.3.0f"),F(Sw,"~6.3.0f"),F(HvR,"~6.3.0f"),F(SrR,"~6.3.0f"),F(SwR,"~6.3.0f"),F(HdR,"~7.2.0f")],
                   [Hv,Sr,Sw,HvR,SrR,SwR,HdR], ","),
  (["PHOCT,01",SUTC,S(TmS),SLt,SHd,S(HdS),SRl,S(RlS),SPt,S(PtS),SHvI,S(HvS),SRest]).

build_evo(Request) ->
  "PEVO," ++ Request.

%% $-EVOTDP,Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll
build_evotdp(Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll) ->
  SLst =
  case Sequence of
      nothing -> "";
      _ ->
         lists:reverse(
           lists:foldl(fun(nothing,Acc) -> Acc;
                          (V,[])  -> [integer_to_list(V)];
                          (V,Acc) -> [integer_to_list(V),":"|Acc]
                       end, "", Sequence))
  end,
  (["PEVOTDP",
           safe_fmt(["~B","~B","~s","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f"],
                    [Transceiver,Max_range,(SLst),LAx,LAy,LAz,HL,Yaw,Pitch,Roll],",")]).

%% $-EVORCM,RX,RX_phy,Src,RSSI,Int,P_src,TS,A1:...:An,TS1:...:TSn,TD1:...TDn,TDOA1:...:TDOAn
build_evorcm(RX_utc,RX_phy,Src,RSSI,Int,PSrc,TS,AS,TSS,TDS,TDOAS) ->
  SFun = fun(nothing) -> "";
            (Lst) -> (
                       lists:reverse(
                         lists:foldl(fun(V,[])  -> [safe_fmt(["~B"],[V])];
                                        (V,Acc) -> [safe_fmt(["~B"],[V]),":"|Acc]
                                     end, "", Lst))) end,
  SRX = utc_format(RX_utc),
  (["PEVORCM",SRX,
           safe_fmt(["~B","~B","~B","~B","~.2.0f","~B","~s","~s","~s","~s"],
                    [RX_phy,Src,RSSI,Int,PSrc,TS,SFun(AS),SFun(TSS),SFun(TDS),SFun(TDOAS)],",")]).

%% $-EVOSEQ,sid,total,maddr,range,seq
build_evoseq(Sid,Total,MAddr,Range,Seq) ->
  SFun = fun(nothing) -> "";
            (Lst) -> (
                       lists:reverse(
                         lists:foldl(fun(V,[])  -> [safe_fmt(["~B"],[V])];
                                        (V,Acc) -> [safe_fmt(["~B"],[V]),":"|Acc]
                                     end, "", Lst))) end,
  (["PEVOSEQ",safe_fmt(["~B","~B","~B","~B","~s"],
                              [Sid,Total,MAddr,Range,SFun(Seq)],",")]).

%% $-EVOCTL,BUSBL,Lat,N,Lon,E,Alt,Mode,IT,MP,AD
build_evoctl(busbl, {Lat, Lon, Alt, Mode, IT, MP, AD}) ->
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  SMode = case Mode of
            silent -> "S";
            transponder -> "T";
            {transitional, TID} -> "T:" ++ integer_to_list(TID);
            Seq when is_list(Seq) ->
              foldl(fun(Id,Acc) ->
                        Acc ++ ":" ++ integer_to_list(Id)
                    end, integer_to_list(hd(Seq)), tl(Seq));
            _ -> ""
          end,
  (["PEVOCTL,BUSBL",SLat,SLon,
           safe_fmt(["~.1.0f","~s","~B","~B","~B"],
                    [Alt,SMode,IT,MP,AD],",")]);
%% $PEVOCTL,SBL,X,Y,Z,Mode,IT,MP,AD
build_evoctl(sbl, {X, Y, Z, Mode, IT, MP, AD}) ->
  SMode = case Mode of
            silent -> "S";
            transponder -> "T";
            Seq when is_list(Seq) ->
              foldl(fun(Id,Acc) ->
                        Acc ++ ":" ++ integer_to_list(Id)
                    end, integer_to_list(hd(Seq)), tl(Seq));
            _ -> ""
          end,
  (["PEVOCTL,SBL",
           safe_fmt(["~.3.0f","~.3.0f","~.3.0f","~s","~B","~B","~B"],
                    [X,Y,Z,SMode,IT,MP,AD],",")]);
%% $PEVOCTL,TIMESYNC,L,Shift
build_evoctl(timesync, {Mode, Shift}) ->
  SMode = case Mode of
            local -> "L";
            remote -> "R";
            _ -> ""
          end,
  (["PEVOCTL,TIMESYNC",
           safe_fmt(["~s","~B"],
                    [SMode, Shift],",")]);
%% $PEVOCTL,SUSBL,Seq,MRange,SVel
build_evoctl(susbl, {Seq, MRange, SVel}) ->
    SSeq = foldl(fun(Id,Acc) ->
                         Acc ++ ":" ++ integer_to_list(Id)
                 end, integer_to_list(hd(Seq)), tl(Seq)),
  (["PEVOCTL,SUSBL",
           safe_fmt(["~s","~.1.0f","~.1.0f"],
                    [SSeq,MRange,SVel],",")]);
%% $PEVOCTL,SUSBL,Seq,MRange,SVel
build_evoctl(sinaps, {DID, Cmd, Arg}) ->
    SCmd = binary_to_list(Cmd),
    SArg = case Arg of
               I when is_integer(I) -> integer_to_list(I);
               F when is_float(F) -> float_to_list(F);
               B when is_binary(B) -> binary_to_list(B);
               _ -> Arg
           end,
  (["PEVOCTL,SINAPS",
           safe_fmt(["~B","~s","~s"],
                    [DID,SCmd,SArg],",")]);
build_evoctl(qlbl, #{command := config} = Map) ->
  SFun = fun(nothing) -> "";
            (Lst) -> (
                       lists:reverse(
                         lists:foldl(fun(V,[])  -> [safe_fmt(["~B"],[V])];
                                        (V,Acc) -> [safe_fmt(["~B"],[V]),":"|Acc]
                                     end, "", Lst))) end,
  {FL, VL} = 
    lists:unzip(
      lists:filtermap(fun(freq = K) -> {true, {"H,~B",maps:get(K,Map)}};
                         (source_level = K) -> {true, {"S,~B",maps:get(K,Map)}};
                         (amap = K) -> {true, {"M,~s",SFun(maps:get(K,Map))}};
                         (_) -> false
                      end, maps:keys(Map))),
  ["PEVOCTL,QLBL,CFG", safe_fmt(FL, VL, ",")];
build_evoctl(qlbl, #{command := reference, lat := Lat, lon := Lon, alt := Alt}) ->
  ["PEVOCTL,QLBL,REF",
   safe_fmt(["~.7.0f","~.7.0f","~.2.0f"],
            [Lat, Lon, Alt], ",")];
build_evoctl(qlbl, #{command := transmit, source := Src, code := Code, counter := Cnt}) ->
  ["PEVOCTL,QLBL,TX",
   safe_fmt(["~B","~B","~B"],
            [Src,Code,Cnt],",")];
build_evoctl(qlbl, #{command := stop}) ->
  ["PEVOCTL,QLBL,RX"];
build_evoctl(qlbl, #{command := reset}) ->
  ["PEVOCTL,QLBL,RST"];
build_evoctl(qlbl, #{frame := Frame, command := calibrate}) ->
  ["PEVOCTL,QLBL,CAL",
   safe_fmt(["~p"],[Frame],",")].

%% $-EVORCT,TX,TX_phy,Lat,LatS,Lon,LonS,Alt,S_gps,Pressure,S_pressure,Yaw,Pitch,Roll,S_ahrs,LAx,LAy,LAz,HL
build_evorct(TX_utc,TX_phy,{Lat,Lon,Alt,GPSS},{P,PS},{Yaw,Pitch,Roll,AHRSS},{Lx,Ly,Lz},HL) ->
  SStatus = fun(undefined)    -> "";
               (raw)          -> "R";
               (interpolated) -> "I";
               (ready)        -> "N"
            end,
  STX = utc_format(TX_utc),
  STX_phy = safe_fmt(["~B"],[TX_phy],","),
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  (["PEVORCT",STX,STX_phy,SLat,SLon,
           safe_fmt(["~.2.0f","~s","~.2.0f","~s","~.1.0f","~.1.0f","~.1.0f","~s","~.2.0f","~.2.0f","~.2.0f","~.2.0f"],
                    [Alt,SStatus(GPSS),P,SStatus(PS),Yaw,Pitch,Roll,SStatus(AHRSS),Lx,Ly,Lz,HL], ",")]).

%% $-EVOTAP,Forward,Right,Down,Spare1,Spare2,Spare3
build_evotap(Forward, Right, Down) ->
  (["PEVOTAP",
           safe_fmt(["~.2.0f","~.2.0f","~.2.0f"], [Forward,Right,Down], ","),
           ",,,"]).

%% $-EVOTPC,Pair,Praw,Ptrans,S_ptrans,Yaw,Pitch,Roll,S_arhs,HL
build_evotpc(Pair,Praw,{Ptrans,S_trans},{Yaw,Pitch,Roll,S_ahrs},HL) ->
  SStatus = fun(undefined)    -> "";
               (raw)          -> "R";
               (interpolated) -> "I";
               (ready)        -> "N"
            end,
  (["PEVOTPC",
           safe_fmt(["~.2.0f","~.2.0f","~.2.0f","~s","~.2.0f","~.2.0f","~.2.0f","~s","~.2.0f"],
                    [Pair,Praw,Ptrans,SStatus(S_trans),Yaw,Pitch,Roll,SStatus(S_ahrs),HL], ",")]).

build_evorcp(Type, Status, Substatus, Interval, Mode, Cycles, Broadcast) ->
  SType = case Type of
            georeference              -> "G";
            standard                  -> "S";
            {remote, Addr}            -> "R" ++ integer_to_list(Addr);
            {remote_calibrated, Addr} -> "C" ++ integer_to_list(Addr);
            _ -> nothing
          end,
  SStatus = case Status of
              activate                -> "A";
              deactivate              -> "D";
              undefined               -> "U";
              _ -> nothing
            end,
  SMode = case Mode of
            pa -> "P";
            ra -> "R";
            _ -> nothing
          end,
  SCast = case Broadcast of
            broadcast -> "B";
            _ -> nothing
          end,
  NCycles = case Cycles of
              inf -> nothing;
              _ -> Cycles
            end,
  (["PEVORCP",
           safe_fmt(["~s","~s","~s","~.2.0f","~s","~B","~s"], [SType, SStatus, Substatus, Interval, SMode, NCycles, SCast], ","),
           ",,"]).

%% $-EVOACA,UTC,DID,action,duration
build_evoaca(UTC, DID, Action, Duration) ->
  SUTC = utc_format(UTC),
  SAction = case Action of
                send -> "S";
                recv -> "R"
            end,
  (["PEVOACA",SUTC,safe_fmt(["~3.10.0B","~s", "~B"], [DID,SAction,Duration], ",")]).


%% $PEVOSSB,UTC,TID,DID,CF,OP,Tr,X,Y,Z,Acc,RSSI,Integrity,ParamA,ParamB
build_evossb(UTC,TID,DID,CF,OP,Tr,X,Y,Z,Acc,RSSI,Int,ParmA,ParmB) ->
  SUTC = utc_format(UTC),
  {SCF,Fmt} = case CF of
                  transceiver -> {<<"T">>,"~.2.0f"};
                  xyz -> {<<"B">>,"~.2.0f"};
                  xyd -> {<<"H">>,"~.2.0f"};
                  ned -> {<<"N">>,"~.2.0f"};
                  enu -> {<<"E">>,"~.2.0f"};
                  geod -> {<<"G">>,"~.6.0f"}
              end,
  SOP = case OP of
            transceiver -> <<"T">>;
            crp -> <<"V">>;
            nothing -> <<"">>
        end,
  STr = case Tr of
            unprocessed -> <<"U">>;
            raw -> <<"R">>;
            raytraced -> <<"T">>;
            pressure -> <<"P">>;
            filtered -> <<"F">>;
            nothing -> <<"">>
        end,
  (["PEVOSSB",SUTC,
           safe_fmt(["~3.10.0B","~3.10.0B","~s","~s","~s",Fmt,Fmt,"~.2.0f","~.2.0f","~B","~B","~.2.0f","~.2.0f"],
                    [TID, DID, SCF, SOP, STr, X, Y, Z, Acc, RSSI, Int, ParmA, ParmB], ",")
          ]).

%% $PEVOSSA,UTC,TID,DID,CF,Tr,B,E,Acc,RSSI,Integrity,ParamA,ParamB
build_evossa(UTC,TID,DID,CF,Tr,B,E,Acc,RSSI,Int,ParmA,ParmB) ->
  SUTC = utc_format(UTC),
  SCF = case CF of
            transceiver -> <<"T">>;
            xyz -> <<"B">>;
            xyd -> <<"H">>;
            ned -> <<"N">>;
            enu -> <<"E">>
        end,
  STr = case Tr of
            unprocessed -> <<"U">>;
            raw -> <<"R">>;
            raytraced -> <<"T">>;
            pressure -> <<"P">>
        end,
  (["PEVOSSA",SUTC,
           safe_fmt(["~3.10.0B","~3.10.0B","~s","~s","~.1.0f","~.1.0f","~.2.0f","~B","~B","~.2.0f","~.2.0f"],
                    [TID, DID, SCF, STr, B, E, Acc, RSSI, Int, ParmA, ParmB], ",")
          ]).

build_evogps(UTC,TID,DID,Mode,Lat,Lon,Alt) ->
  SUTC = utc_format(UTC),
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  SMode = case Mode of
              measured -> ",M";
              filtered -> ",F";
              computed -> ",C"
          end,
  [STID, SDID, SAlt] = safe_fmt(["~3.10.0B","~3.10.0B","~.2.0f"],[TID, DID, Alt]),
  (["PEVOGPS",SUTC,",",STID,",",SDID,SMode,SLat,SLon,",",SAlt]).

build_evorpy(UTC,TID,DID,Mode,Roll,Pitch,Yaw) ->
  SUTC = utc_format(UTC),
  SMode = case Mode of
              measured -> "M";
              filtered -> "F";
              computed -> "C"
          end,
  (["PEVORPY",SUTC,
           safe_fmt(["~3.10.0B","~3.10.0B","~s","~.2.0f","~.2.0f","~.2.0f"],
                    [TID, DID, SMode, Roll, Pitch, Yaw], ",")
          ]).

build_evoerr(Report) ->
  Msg = 
    case Report of
      out_of_range -> "out of range";
      out_of_context -> "out of context";
      _ when is_atom(Report) -> atom_to_list(Report);
      _ when is_list(Report) -> Report;
      _ when is_binary(Report) -> binary_to_list(Report);
      _ -> io_lib:format("~p",[Report])
    end,
  ["PEVOERR,",re:replace(Msg,"[$*\r\n]","", [global,{return,list}])].

build_hdg(Heading,Dev,Var) ->
  F = fun(V) -> case V < 0 of true -> {"W",-V}; _ -> {"E",V} end end,
  {DevS,DevA} = F(Dev),
  {VarS,VarA} = F(Var),
  (["HCHDG",safe_fmt(["~.1.0f","~.1.0f","~s","~.1.0f","~s"],[Heading,DevA,DevS,VarA,VarS],",")]).

build_hdt(Heading) ->
  (["HCHDT", safe_fmt(["~.1.0f"],[Heading],","),",T"]).

build_xdr(Lst) ->
  F = fun(V) -> if is_integer(V) -> "~B"; true -> "~.2.0f" end end,
  (["HCXDR", lists:map(fun({Type,Data,Units,Name}) ->
                                  safe_fmt(["~s",F(Data),"~s","~s"],[Type,Data,Units,Name],",")
                              end, Lst)]).

build_vtg(TMGT,TMGM,Knots) ->
  KMH = if is_number(Knots) -> Knots*0.539956803456; true -> nothing end,
  Fields = safe_fmt(["~5.1.0f","~5.1.0f","~5.1.0f","~5.1.0f"],[TMGT,TMGM,Knots,KMH]),
  (io_lib:format("GPVTG,~s,T,~s,M,~s,N,~s,K",Fields)).

build_tnthpr(Heading,HStatus,Pitch,PStatus,Roll,RStatus) ->
  (["PTNTHPR",
           safe_fmt(["~.1.0f","~s","~.1.0f","~s","~.1.0f","~s"],
                    [Heading,HStatus,Pitch,PStatus,Roll,RStatus], ",")]).

build_smcs(Roll,Pitch,Heave) ->
  (["PSMCS",
           safe_fmt(["~.1.3f","~.1.3f","~.1.2f"],
                    [Roll,Pitch,Heave], ",")]).

build_smcm(Roll, Pitch, Heading, Surge, Sway, Heave, RRoll, RPitch, RHeading, AccX, AccY, AccZ) ->
  (["PSMCM",
           safe_fmt(["~+.2.5f","~+.2.5f","~+.2.5f","~+.2.5f","~+.2.5f","~+.2.5f","~+.2.5f","~+.2.5f","~+.2.5f","~+.6.3f","~+.6.3f","~+.6.3f"],
                    [Roll, Pitch, Heading, Surge, Sway, Heave, RRoll, RPitch, RHeading, AccX, AccY, AccZ], ",")]).

build_htro(Pitch, Roll) ->
  PitchSign = case Pitch of P when P >= 0.0 -> "M"; _ -> "P" end,
  RollSign = case Roll of R when R >= 0.0 -> "T"; _ -> "B" end,
  (["PHTRO",
           safe_fmt(["~.2f","~s","~.2f","~s"],
                    [Pitch, PitchSign, Roll, RollSign], ",")]).

build_dbs(Depth) ->
  Fmts = ["~.2.0f","~.2.0f","~.2.0f"],
  Fields = safe_fmt(Fmts, case Depth of
                            nothing -> [nothing, nothing, nothing];
                            _ -> [Depth * 3.2808399, Depth, Depth * 0.546806649]
                          end),
  (io_lib:format("SDDBS,~s,f,~s,M,~s,F",Fields)).

build_dbt(Depth) ->
  Fmts = ["~.2.0f","~.2.0f","~.2.0f"],
  Fields = safe_fmt(Fmts, case Depth of
                            nothing -> [nothing, nothing, nothing];
                            _ -> [Depth * 3.2808399, Depth, Depth * 0.546806649]
                          end),
  (io_lib:format("SDDBT,~s,f,~s,M,~s,F",Fields)).

%% $PSIMSSB,UTC,B01,A,,C,H,M,X,Y,Z,Acc,N,,
build_simssb(UTC,Addr,S,Err,CS,FS,X,Y,Z,Acc,AddT,Add1,Add2) ->
  SUTC = utc_format(UTC),
  SS = case S of
         ok -> "A";
         nok -> "V"
       end,
  {SCS,SHS,Fmt,Depth} = case CS of
                lf -> {<<"C">>,<<"H">>,"~.2.0f",Z};
                enu -> {<<"C">>,<<"E">>,"~.2.0f",Z};
                ned -> {<<"C">>,<<"N">>,"~.2.0f",Z};
                geod -> {<<"R">>,<<"G">>,"~.6.0f",-Z}
        end,
  SFS = case FS of
          measured -> <<"M">>;
          filtered -> <<"F">>;
          reconstructed -> <<"R">>
        end,
  (["PSIMSSB",SUTC,
           safe_fmt(["B~2.10.0B","~s","~s","~s","~s","~s",Fmt,Fmt,"~.2.0f","~.2.0f","~s","~.2.0f","~.2.0f"],
                    [Addr, SS, Err, SCS, SHS, SFS, X, Y, Depth, Acc, AddT, Add1, Add2], ",")
          ]).

from_term_helper(Sentense) ->
  case Sentense of
    {rmc,UTC,Status,Lat,Lon,Speed,Tangle,Date,Magvar} ->
      build_rmc(UTC,Status,Lat,Lon,Speed,Tangle,Date,Magvar);
    {gga,UTC,Lat,Lon,Q,Sat,HDil,Alt,Geoid,Age,ID} ->
      build_gga(UTC,Lat,Lon,Q,Sat,HDil,Alt,Geoid,Age,ID);
    {zda,UTC,DD,MM,YY,Z1,Z2} ->
      build_zda(UTC,DD,MM,YY,Z1,Z2);
    {gll,Lat,Lon,UTC,Status,Mode} ->
      build_gll(Lat,Lon,UTC,Status,Mode);
    {evolbl,Type,Frame,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure,CF1,CF2,CF3} ->
      build_evolbl(Type,Frame,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure,CF1,CF2,CF3);
    {evolbp,UTC,Basenodes,Address,Status,Frame,Lat_rad,Lon_rad,Alt,Pressure,Ma,Mi,Dir,SMean,Std} ->
      build_evolbp(UTC,Basenodes,Address,Status,Frame,Lat_rad,Lon_rad,Alt,Pressure,Ma,Mi,Dir,SMean,Std);
    {simsvt,Total,Idx,Lst} ->
      build_simsvt(Total, Idx, Lst);
    {'query',evo,Name} ->
      build_evo(Name);
    {evotdp,Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll} ->
      build_evotdp(Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll);
    {evorcp,Type,Status,Substatus} ->
      build_evorcp(Type,Status,Substatus,nothing,nothing,nothing,nothing);
    {evorcp,Type,Status,Substatus,Interval,Mode,Cycles,Broadcast,_,_} ->
      build_evorcp(Type,Status,Substatus,Interval,Mode,Cycles,Broadcast);
    {evotap,Forward,Right,Down} ->
      build_evotap(Forward, Right, Down);
    {evotpc,Pair,Praw,{Ptrans,S_trans},{Yaw,Pitch,Roll,S_ahrs},HL} ->
      build_evotpc(Pair,Praw,{Ptrans,S_trans},{Yaw,Pitch,Roll,S_ahrs},HL);
    {evorct,TX_utc,TX_phy,GPS,Pressure,AHRS,Lever_arm,HL} ->
      build_evorct(TX_utc,TX_phy,GPS,Pressure,AHRS,Lever_arm,HL);
    {evorcm,RX_utc,RX_phy,Src,RSSI,Int,PSrc,TS,AS,TSS,TDS,TDOAS} ->
      build_evorcm(RX_utc,RX_phy,Src,RSSI,Int,PSrc,TS,AS,TSS,TDS,TDOAS);
    {evoaca,UTC,DID,Action,Duration} ->
      build_evoaca(UTC,DID,Action,Duration);
    {evossb,UTC,TID,DID,CF,OP,Tr,X,Y,Z,Acc,RSSI,Int,ParmA,ParmB} ->
      build_evossb(UTC,TID,DID,CF,OP,Tr,X,Y,Z,Acc,RSSI,Int,ParmA,ParmB);
    {evossa,UTC,TID,DID,CF,Tr,B,E,Acc,RSSI,Int,ParmA,ParmB} ->
      build_evossa(UTC,TID,DID,CF,Tr,B,E,Acc,RSSI,Int,ParmA,ParmB);
    {evogps,UTC,TID,DID,Mode,Lat,Lon,Alt} ->
      build_evogps(UTC,TID,DID,Mode,Lat,Lon,Alt);
    {evorpy,UTC,TID,DID,Mode,Roll,Pitch,Yaw} ->
      build_evorpy(UTC,TID,DID,Mode,Roll,Pitch,Yaw);
    {evoseq,Sid,Total,MAddr,Range,Seq} ->
      build_evoseq(Sid,Total,MAddr,Range,Seq);
    {evoctl, busbl, {Lat, Lon, Alt, Mode, IT, MP, AD}} ->
      build_evoctl(busbl, {Lat, Lon, Alt, Mode, IT, MP, AD});
    {evoctl, sbl, {X, Y, Z, Mode, IT, MP, AD}} ->
      build_evoctl(sbl, {X, Y, Z, Mode, IT, MP, AD});
    {evoctl, timesync, Args} ->
      build_evoctl(timesync, Args);
    {evoctl, susbl, Args} ->
      build_evoctl(susbl, Args);
    {evoctl, sinaps, Args} ->
      build_evoctl(sinaps, Args);
    {evoctl, qlbl, Args} ->
      build_evoctl(qlbl, Args);
    {evoerr, Report} ->
      build_evoerr(Report);
    {hdg,Heading,Dev,Var} ->
      build_hdg(Heading,Dev,Var);
    {hdt,Heading} ->
      build_hdt(Heading);
    {xdr,Lst} ->
      build_xdr(Lst);
    {vtg,TMGT,TMGM,Knots} ->
      build_vtg(TMGT,TMGM,Knots);
    {tnthpr, Heading, HStatus, Pitch, PStatus, Roll, RStatus} ->
      build_tnthpr(Heading,HStatus,Pitch,PStatus,Roll,RStatus);
    {smcs, Roll, Pitch, Heave} ->
      build_smcs(Roll, Pitch, Heave);
    {smcm, Roll, Pitch, Heading, Surge, Sway, Heave, RRoll, RPitch, RHeading, AccX, AccY, AccZ} ->
      build_smcm(Roll, Pitch, Heading, Surge, Sway, Heave, RRoll, RPitch, RHeading, AccX, AccY, AccZ);
    {htro,Pitch,Roll} ->
       build_htro(Pitch,Roll);
    {sxn,10,Tok,Roll,Pitch,Heave,UTC,nothing} ->
      build_sxn(10,Tok,Roll,Pitch,Heave,UTC,nothing);
    {sxn,23,Roll,Pitch,Heading,Heave} ->
      build_sxn(23,Roll,Pitch,Heading,Heave);
    {sat,hpr,UTC,Heading,Pitch,Roll,Type} ->
      build_sat(hpr,UTC,Heading,Pitch,Roll,Type);
    {dbs,Depth} ->
      build_dbs(Depth);
    {dbt,Depth} ->
      build_dbt(Depth);
    {ixse, atitud, Roll, Pitch} ->
      build_ixse(atitud,Roll,Pitch);
    {ixse, positi, Lat, Lon, Alt} ->
      build_ixse(positi,Lat,Lon,Alt);
    {ashr,UTC,Heading,True,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq} ->
      build_ashr(UTC,Heading,True,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq);
    {rdid, Pitch, Roll, Heading} ->
      build_rdid(Pitch,Roll,Heading);
    {hoct,1,UTC,TmS,Lt,Hd,HdS,Rl,RlS,Pt,PtS,HvI,HvS,Hv,Sr,Sw,HvR,SrR,SwR,HdR} ->
      build_hoct(1,UTC,TmS,Lt,Hd,HdS,Rl,RlS,Pt,PtS,HvI,HvS,Hv,Sr,Sw,HvR,SrR,SwR,HdR);
    {simssb, UTC,Addr,S,Err,CS,FS,X,Y,Z,Acc,AddT,Add1,Add2} ->
      build_simssb(UTC,Addr,S,Err,CS,FS,X,Y,Z,Acc,AddT,Add1,Add2);
    _ -> ""
  end.

%% TODO: code Lat/Lon N/E with sign?
from_term({nmea, Sentense}, Cfg) ->
  #{out := OutRule} = Cfg,
  Flag = is_filtered(Sentense, OutRule),
  Body = if Flag -> flatten(from_term_helper(Sentense));
            true -> ""
         end,
  case length(Body) of
    0 -> [<<>>, Cfg];
    _ ->
      CS = checksum(Body),
      [list_to_binary((["$",Body,"*",io_lib:format("~2.16.0B",[CS]),"\r\n"])), Cfg]
  end;
from_term(_, Cfg) -> [<<>>, Cfg].

is_filtered(Sentense, Rule) ->
  [F,S|_] = tuple_to_list(Sentense),
  case Rule of
    all -> true;
    {white, Lst} ->
      lists:member(F, Lst)
        orelse (F == is_atom('query') and lists:member(S, Lst));
    {black, Lst} ->
      not (
        lists:member(F, Lst)
        orelse (F == is_atom('query') and lists:member(S, Lst)))
  end.

