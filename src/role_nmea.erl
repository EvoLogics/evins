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
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

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

split(L, Cfg) ->
  case re:split(L,"\r?\n",[{parts,2}]) of
    [Sentense,Rest] ->
      %% NMEA checksum might be optional
      case re:run(Sentense,"^\\\$((P|..)([^,]+),([^*]+))(\\\*(..)|)",[dotall,{capture,[1,3,4,6],binary}]) of
        {match, [Raw,Cmd,Params,XOR]} ->
          CS = checksum(Raw),
          Flag = case binary_to_list(XOR) of
                   [] -> true;
                   LCS -> CS == list_to_integer(LCS, 16)
                 end,
          if Flag -> 
              case Cmd of
                <<"GGA">>    -> [extract_gga(Params)    | split(Rest, Cfg)];
                <<"RMC">>    -> [extract_rmc(Params)    | split(Rest, Cfg)];
                <<"ZDA">>    -> [extract_zda(Params)    | split(Rest, Cfg)];
                <<"EVOLBL">> -> [extract_evolbl(Params) | split(Rest, Cfg)];
                <<"EVOLBP">> -> [extract_evolbp(Params) | split(Rest, Cfg)];
                <<"SIMSVT">> -> [extract_simsvt(Params) | split(Rest, Cfg)];
                <<"HDG">>    -> [extract_hdg(Params)    | split(Rest, Cfg)];
                <<"HDT">>    -> [extract_hdt(Params)    | split(Rest, Cfg)];
                <<"XDR">>    -> [extract_xdr(Params)    | split(Rest, Cfg)];
                <<"VTG">>    -> [extract_vtg(Params)    | split(Rest, Cfg)];
                <<"TNTHPR">> -> [extract_tnthpr(Params) | split(Rest, Cfg)];
                <<"SMCS">>   -> [extract_smcs(Params)   | split(Rest, Cfg)];
                <<"DBS">>    -> [extract_dbs(Params)    | split(Rest, Cfg)];
                <<"SXN">>    -> [extract_sxn(Params)    | split(Rest, Cfg)];
                <<"SAT">>    -> [extract_sat(Params)    | split(Rest, Cfg)];
                <<"IXSE">>   -> [extract_ixse(Params)   | split(Rest, Cfg)];
                <<"HOCT">>   -> [extract_hoct(Params)   | split(Rest, Cfg)];
                <<"ASHR">>   -> [extract_ashr(Params)   | split(Rest, Cfg)];
                <<"RDID">>   -> [extract_rdid(Params)   | split(Rest, Cfg)];
                <<"DBT">>    -> [extract_dbt(Params)    | split(Rest, Cfg)];
                <<"EVO">>    -> [extract_evo(Params)    | split(Rest, Cfg)];
                <<"EVOTAP">> -> [extract_evotap(Params) | split(Rest, Cfg)];
                <<"EVOTPC">> -> [extract_evotpc(Params) | split(Rest, Cfg)];
                <<"EVOTDP">> -> [extract_evotdp(Params) | split(Rest, Cfg)];
                <<"EVORCP">> -> [extract_evorcp(Params) | split(Rest, Cfg)];
                <<"EVORCT">> -> [extract_evorct(Params) | split(Rest, Cfg)];
                <<"EVORCM">> -> [extract_evorcm(Params) | split(Rest, Cfg)];
                <<"EVOSEQ">> -> [extract_evoseq(Params) | split(Rest, Cfg)];
                <<"EVOSSB">> -> [extract_evossb(Params) | split(Rest, Cfg)];
                <<"EVOSSA">> -> [extract_evossa(Params) | split(Rest, Cfg)];
                <<"EVOCTL">> -> [extract_evoctl(Params) | split(Rest, Cfg)];
                _ ->      [{error, {notsupported, Cmd}} | split(Rest, Cfg)]
              end;
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
  SS = case re:split(BSS,"\\\.") of
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
extract_rmc(Params) ->
  try
    [BUTC,BStatus,BLat,BN,BLon,BE,BSpeed,BTangle,BDate,BMagvar,BME] = 
      lists:sublist(re:split(Params, ","),11),
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
  end.

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
extract_gga(Params) ->
  try
    [BUTC,BLat,BN,BLon,BE,BQ,BSat,BHDil,BAlt,<<"M">>,BGeoid,<<"M">>,BAge,BID] = re:split(Params, ","),
    [UTC, Lat, Lon] = extract_geodata(BUTC, BLat, BN, BLon, BE),
    [Q,Sat,ID] = [safe_binary_to_integer(X) || X <- [BQ,BSat,BID]],
    [HDil,Alt,Geoid,Age] = [safe_binary_to_float(X) || X <- [BHDil,BAlt,BGeoid,BAge]],
    {nmea,{gga, UTC, Lat, Lon, Q, Sat, HDil, Alt, Geoid, Age, ID}}
  catch
    error:_ -> {error, {parseError, gga, Params}}
  end.

%% $--ZDA,hhmmss.ss,xx,xx,xxxx,xx,xx
%% hhmmss.ss = UTC 
%% xx = Day, 01 to 31 
%% xx = Month, 01 to 12 
%% xxxx = Year 
%% xx = Local zone description, 00 to +/- 13 hours 
%% xx = Local zone minutes description (same sign as hours)
extract_zda(Params) ->
  try
    [BUTC,BD,BM,BY,BZD,BZM] = re:split(Params, ","),
    <<BHH:2/binary,BMM:2/binary,BSS/binary>> = BUTC,
    SS = case re:split(BSS,"\\\.") of
           [_,_] -> binary_to_float(BSS);
           _ -> binary_to_integer(BSS)
         end,
    [HH,MM,D,M,Y,ZD,ZM] = [safe_binary_to_integer(X) || X <- [BHH,BMM,BD,BM,BY,BZD,BZM]],
    UTC = 60*(60*HH + MM) + SS,
    {nmea,{zda, UTC, D, M, Y, ZD, ZM}}
  catch
    error:_ -> {error, {parseError, zda, Params}}
  end.

%% LBL location
%% $-EVOLBL,Type,r,Loc_no,Ser_no,Lat,Lon,Alt,Pressure,,
%% Alt - meters
%% Pressure - dbar
%% Type: I or C
%% I - initialized georeferenced position
%% C - calibrated georeferenced position
%% D - undefined position
extract_evolbl(Params) ->
  try
    [BType,_,BLoc,BSer,BLat,BLon,BAlt,BPressure,_,_,_] = re:split(Params, ","),
    Type = binary_to_list(BType),
    [Loc,Ser] = [safe_binary_to_integer(X) || X <- [BLoc,BSer]],
    [Lat,Lon,Alt,Pressure] = [safe_binary_to_float(X) || X <- [BLat,BLon,BAlt,BPressure]],
    {nmea,{evolbl, Type, Loc, Ser, Lat, Lon, Alt, Pressure}}
  catch
    error:_ -> {error, {parseError, evolbl, Params}}
  end.

%% LBL position
%% $-EVOLBP,Timestamp,Tp_array,Type,Status,Coordinates,Lat,Lon,Alt,Pressure,Major,Minor,Direction,SMean,Std
%% Timestamp hhmmss.ss
%% Tp_array c--c %% B01B02B04 %% our case 1:2:3:4
%% Type a- %% R1 or T1 %% in our case just address
%% Status A %% OK | or others
%% Coordinates r (degrees, 7 digits)
extract_evolbp(Params) ->
  try
    [BUTC,BArray,BAddress,BStatus,_,BLat,BLon,BAlt,BPressure,_,_,_,Bsmean,Bstd] = re:split(Params, ","),
    Basenodes = if BArray == <<>> -> [];
                   true -> [binary_to_integer(Bnode) || Bnode <- re:split(BArray, ":")]
                end,
    <<BHH:2/binary,BMM:2/binary,BSS/binary>> = BUTC,
    SS = case re:split(BSS,"\\\.") of
           [_,_] -> binary_to_float(BSS);
           _ -> binary_to_integer(BSS)
         end,
    [HH,MM] = [safe_binary_to_integer(X) || X <- [BHH,BMM]],
    UTC = 60*(60*HH + MM) + SS,
    Status = binary_to_list(BStatus),
    Address = binary_to_integer(BAddress),
    [Lat,Lon,Alt,Pressure,SMean,Std] = [safe_binary_to_float(X) || X <- [BLat,BLon,BAlt,BPressure,Bsmean,Bstd]],
    {nmea, {evolbp, UTC, Basenodes, Address, Status, Lat, Lon, Alt, Pressure, SMean, Std}}
  catch
    error:_ -> {error, {parseError, evolbp, Params}}
  end.

%%
%% $-SIMSVT,Description,TotalPoints,Index,Depth1,Sv1,Depth2,Sv2,Depth3,Sv3,Depth4,Sv4
%% Only "P" supported
%% Description  a_  "P" indicates profile used. "M" for manual parameters. "R" indicates request for data.
%% TotalPoints  x   Total number of points in the sound profile
%% Index        x   The index for the first point in this telegram, a range from 0 to (TotalPoints -1)
%% Depth[1-4]   x.x Depth for the next sound velocity [m].
%% Sv[1-4]      x.x Sound velocity for the previous depth [m/s].
extract_simsvt(Params) ->
  try
    [<<"P">>,BTotal,BIdx,BD1,DS1,BD2,BS2,BD3,BS3,BD4,BS4] = re:split(Params, ","),
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
  end.

%% $PSXN,23,Roll,Pitch,Heading,Heave
%% 23      x         Message type (Roll, Pitch, Heading and Heave)
%% Roll    x.x       Roll in degrees. Positive with port side up.
%% Pitch   x.x       Pitch in degrees. Positive is bow up. (NED)
%% Heading x.x       Heading in degrees true.
%% Heave   x.x       Heave in meters. Positive is down.
%% Example: $PSXN,23,0.02,-0.76,330.56,*0B
extract_sxn(Params) ->
  try
    [Type | Rest] = lists:sublist(re:split(Params, ","),5),
    case Type of
      <<"23">> ->
        [Roll, Pitch, Heading, Heave] = [safe_binary_to_float(X) || X <- Rest],
        {nmea, {sxn, 23, Roll, Pitch, Heading, Heave}};
      _ -> {error, {parseError, sxn_23, Params}}
    end
  catch error:_ -> {error, {parseError, sxn_23, Params}}
  end.

%% $PSAT,HPR,TIME,HEADING,PITCH,ROLL,TYPE*CC<CR><LF>
%% UTC     hhmmss.ss UTC of position
%% Heading x.x       Heading in degrees true.
%% Pitch   x.x       Pitch in degrees. Positive is bow up. (NED)
%% Roll    x.x       Roll in degrees. Positive with port side up.
%% Type    a_        Type N=gps or G=Gyro.
extract_sat(Params) ->
  try
    [Type | Rest] = lists:sublist(re:split(Params, ","),6),
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
  end.

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
extract_ixse(Params) ->
  try
    [Type | Rest] = lists:sublist(re:split(Params, ","),4),
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
  end.

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
extract_ashr(Params) ->
  try
    [BUTC,BHeading,BTrue,BRoll,BPitch,BRes,BRollSTD,BPitchSTD,BHeadingSTD,BGPSq,BINSq] = re:split(Params, ","),
    UTC = extract_utc(BUTC),
    [Heading,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD] = [safe_binary_to_float(X) || X <- [BHeading,BRoll,BPitch,BRes,BRollSTD,BPitchSTD,BHeadingSTD]],
    [GPSq,INSq] = [safe_binary_to_integer(X) || X <- [BGPSq,BINSq]],
    True = case BTrue of <<"T">> -> true; _ -> false end,
    {nmea, {ashr,UTC,Heading,True,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq}}
  catch
    error:_ -> {error, {parseError, ashr, Params}}
  end.

%% $PRDID,PPP.PP,RRR.RR,xxx.xx
%% PPP.PP  x.x       Pitch in degrees
%% RRR.RR  x.x       Roll in degrees
%% xxx.xx  x.x       Heading in degrees true.
extract_rdid(Params) ->
  try
    [Pitch,Roll,Heading] = [safe_binary_to_float(X) || X <- lists:sublist(re:split(Params, ","),3)],
    {nmea, {rdid, Pitch, Roll, Heading}}
  catch error:_ -> {error, {parseError, rdid, Params}}
  end.

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
extract_hoct(Params) ->
  S = fun(<<"T">>) -> valid; (<<"E">>) -> invalid; ("I") -> initialization; (_) -> unknown end,
  try
    [Ver | Rest] = lists:sublist(re:split(Params, ","),19),
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
  end.

%% $PEVO,Request
%% Request c--c NMEA senstence request
extract_evo(Params) ->
  try
    BName = Params,
    {nmea, {'query', evo, binary_to_list(BName)}}
  catch
    error:_ -> {error, {parseError, evo, Params}}
  end.

%% $-EVOTAP,Forward,Right,Down,Spare1,Spare2,Spare3
%% Forward x.x forward offset in meters
%% Right   x.x rights(starboard) offset in meters
%% Down    x.x downwards offset in meters
extract_evotap(Params) ->
  try
    [BForward,BRight,BDown,_,_,_] = re:split(Params, ","),
    [Forward,Right,Down] = [safe_binary_to_float(X) || X <- [BForward,BRight,BDown]],
    {nmea, {evotap,Forward,Right,Down}}
  catch
    error:_ -> {error, {parseError, evotap, Params}}
  end.

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
extract_evotdp(Params) ->
  try
    [BTransceiver,BMax_range,BSequence,BLAx,BLAy,BLAz,BHL,BYaw,BPitch,BRoll] = re:split(Params,","),
    [Transceiver,Max_range] = [safe_binary_to_integer(X) || X <- [BTransceiver,BMax_range]],
    [LAx,LAy,LAz,HL,Yaw,Pitch,Roll] = [safe_binary_to_float(X) || X <- [BLAx,BLAy,BLAz,BHL,BYaw,BPitch,BRoll]],
    Sequence = [safe_binary_to_integer(X) || X <- re:split(BSequence,":")],
    {nmea, {evotdp, Transceiver, Max_range, Sequence, LAx,LAy,LAz,HL,Yaw,Pitch,Roll}}
  catch 
    error:_ -> {error, {parseError, evotdp, Params}}
  end.

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
extract_evotpc(Params) ->
  try
    [BPair,BPraw,BPtrans,BTransS,BYaw,BPitch,BRoll,BAHRSS,BHL] = re:split(Params, ","),
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
  end.

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
extract_evorcm(Params) ->
  try
    [BRX,BRXP,BSrc,BRSSI,BInt,BPSrc,BTS,BAS,BTSS,BTDS,BTDOAS] = re:split(Params, ","),
    RX_utc = extract_utc(BRX),
    [RX_phy,Src,TS,RSSI,Int] = [safe_binary_to_integer(X) || X <- [BRXP,BSrc,BTS,BRSSI,BInt]],
    PSrc = safe_binary_to_float(BPSrc),
    [AS,TSS,TDS,TDOAS] = [[safe_binary_to_integer(X) || X <- re:split(Y,":")]
                          || Y <- [BAS,BTSS,BTDS,BTDOAS]],
    {nmea, {evorcm,RX_utc,RX_phy,Src,RSSI,Int,PSrc,TS,AS,TSS,TDS,TDOAS}}
  catch
    error:_ -> {error, {parseError, evorcm, Params}}
  end.

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
extract_evoseq(Params) ->
  try
    [BSID,BTotal,BMaddr,BRange,BSeq] = re:split(Params, ","),
    [Sid,Total,MAddr,Range] = [safe_binary_to_integer(X) || X <- [BSID,BTotal,BMaddr,BRange]],
    Seq = [safe_binary_to_integer(X) || X <- re:split(BSeq,":")],
    {nmea, {evoseq,Sid,Total,MAddr,Range,Seq}}
  catch error:_ -> {error, {parseError, evoseq, Params}}
  end.

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
extract_evorct(Params) ->
  try
    [BTX,BTXP,BLat,BN,BLon,BE,BAlt,BGPSS,BP,BPS,BYaw,BPitch,BRoll,BAHRSS,BLx,BLy,BLz,BHL] = re:split(Params, ","),
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
  end.

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
extract_evorcp(Params) ->
  try
    [BType,BStatus,BSub,BInt,BMode,BCycles,BCast,_,_] = re:split(Params, ","),
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
  end.

%% $PEVOSSB,UTC,TID,S,Err,CS,FS,X,Y,Z,Acc,Pr,Vel
%% UTC hhmmss.ss
%% TID transponder ID
%% S status OK/NOK
%% Err error code cc_
%% CS coordinate system: Local frame (LF)/ ENU / GEOD
%% FS filter status: M measured, R reconstructed, F filtered
%% X,Y,Z coordinates
%% Acc accuracy in meters
%% Pr pressure in dBar (blank, if not available)
%% Vel velocity in m/s
extract_evossb(Params) ->
  try
    [BUTC,BTID,BS,BErr,BCS,BFS,BX,BY,BZ,BAcc,BPr,BVel] = 
      lists:sublist(re:split(Params, ","),12),
    UTC = extract_utc(BUTC),
    TID = safe_binary_to_integer(BTID),
    [X,Y,Z,Acc,Pr,Vel] = [safe_binary_to_float(V) || V <- [BX,BY,BZ,BAcc,BPr,BVel]],
    S = case BS of
          <<"OK">> -> ok;
          <<"NOK">> -> nok
        end,
    CS = case BCS of
           <<"LF">> -> lf;
           <<"ENU">> -> enu;
           <<"GEOD">> -> geod
         end,
    FS = case BFS of
           <<"M">> -> measured;
           <<"F">> -> filtered;
           <<"R">> -> reconstructed
         end,
    Err = binary_to_list(BErr),
    {nmea, {evossb, UTC, TID, S, Err, CS, FS, X, Y, Z, Acc, Pr, Vel}}
  catch
    error:_ -> {error, {parseError, evossb, Params}}
  end.

%% $PEVOSSA,UTC,TID,S,Err,CS,FS,B,E,Acc,Pr,Vel
%% UTC hhmmss.ss
%% TID transponder ID
%% S status OK/NOK
%% Err error code cc_
%% CS coordinate system: Local frame (LF)/ ENU / GEOD
%% FS filter status: M measured, F filtered, R reconstructed
%% B,E bearing and elevation angles
%% Acc accuracy in meters
%% Pr pressure in dBar (blank, if not available)
%% Vel velocity in m/s
extract_evossa(Params) ->
  try
    [BUTC,BTID,BS,BErr,BCS,BFS,BB,BE,BAcc,BPr,BVel] = 
      lists:sublist(re:split(Params, ","),11),
    UTC = extract_utc(BUTC),
    TID = safe_binary_to_integer(BTID),
    [B,E,Acc,Pr,Vel] = [safe_binary_to_float(V) || V <- [BB,BE,BAcc,BPr,BVel]],
    S = case BS of
          <<"OK">> -> ok;
          <<"NOK">> -> nok
        end,
    CS = case BCS of
           <<"LF">> -> lf;
           <<"ENU">> -> enu;
           <<"GEOD">> -> geod
         end,
    FS = case BFS of
           <<"M">> -> measured;
           <<"F">> -> filtered;
           <<"R">> -> reconstructed
         end,
    Err = binary_to_list(BErr),
    {nmea, {evossa, UTC, TID, S, Err, CS, FS, B, E, Acc, Pr, Vel}}
  catch
    error:_ -> {error, {parseError, evossb, Params}}
  end.

%% $PEVOCTL,BUSBL,...
%% ID - configuration id (BUSBL/SBL...)
%% $PEVOCTL,BUSBL,Lat,N,Lon,E,Alt,Mode,IT,MP,AD
%% Lat/Lon/Alt x.x reference coordinates
%% Mode        a   interrogation mode (S = silent / T  = transponder / <I1>:...:<In> = interrogation sequence)
%% IT          x   interrogation period in us
%% MP          x   max pressure id dBar (must be equal on all the modems)
%% AD          x   answer delays in us
extract_evoctl(<<"BUSBL,",Params/binary>>) ->
  try
    [BLat,BN,BLon,BE,BAlt,BMode,BIT,BMP,BAD] = 
      lists:sublist(re:split(Params, ","),9),
    [_, Lat, Lon] = safe_extract_geodata(nothing, BLat, BN, BLon, BE),
    Alt = safe_binary_to_float(BAlt),
    Mode = case BMode of
             <<>> -> nothing;
             <<"S">> -> silent;
             <<"T">> -> transponder;
             _ -> [binary_to_integer(BI) || BI <- re:split(BMode, ":")]
           end,
    [IT, MP, AD] = [safe_binary_to_integer(X) || X <- [BIT, BMP, BAD]],
    {nmea, {evoctl, busbl, {Lat, Lon, Alt, Mode, IT, MP, AD}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
%% $PEVOCTL,SBL,X,Y,Z,Mode,IT,MP,AD
%% X,Y,Z           x.x coordinates of SBL node in local frame in meters
%% Mode            a   interrogation mode (S = silent / T  = transponder / <I1>:...:<In> = interrogation sequence)
%% IT              x   interrogation timeout in us
%% MP              x   max pressure id dBar (must be equal on all the modems)
%% AD              x   answer delays in us
extract_evoctl(<<"SBL,",Params/binary>>) ->
  %% try
    [BX,BY,BZ,BMode,BIT,BMP,BAD] = 
      lists:sublist(re:split(Params, ","),9),
    [X,Y,Z] = [safe_binary_to_float(BV) || BV <- [BX, BY, BZ]],
    Mode = case BMode of
             <<>> -> nothing;
             <<"S">> -> silent;
             <<"T">> -> transponder;
             _ -> [binary_to_integer(BI) || BI <- re:split(BMode, ":")]
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
extract_evoctl(<<"SUSBL,",Params/binary>>) ->
  try
    [BMRange, BSVel, BSeq] =
      lists:sublist(re:split(Params, ","), 3),
    [MRange,SVel] = [safe_binary_to_float(BV) || BV <- [BMRange, BSVel]],
    Seq = case BSeq of
            <<>> -> nothing;
            _ -> [binary_to_integer(BI) || BI <- re:split(BSeq, ":")]
          end,
    {nmea, {evoctl, susbl, {Seq, MRange, SVel}}}
  catch
    error:_ ->{error, {parseError, evoctl, Params}}
  end;
extract_evoctl(Params) ->
  {error, {parseError, evoctl, Params}}.

%% $--HDG,Heading,Devitaion,D_sign,Variation,V_sign
%% Heading        x.x magnetic sensor heading in degrees
%% Deviation      x.x deviation, degrees
%% D_sign         a   deviation direction, E = Easterly, W = Westerly
%% Variation      x.x variation, degrees
%% V_sign         a   variation direction, E = Easterly, W = Westerly
%%
%% Example: $HCHDG,271.1,10.7,E,12.2,W*52
extract_hdg(Params) ->
  try
    [BHeading,BDev,BDevS,BVar,BVarS] = re:split(Params, ","),
    [Heading,Dev,Var] = [safe_binary_to_float(X) || X <- [BHeading,BDev,BVar]],
    DevS = case BDevS of <<"E">> -> 1; _ -> -1 end,
    VarS = case BVarS of <<"E">> -> 1; _ -> -1 end,
    {nmea, {hdg, Heading, DevS * Dev, VarS * Var}}
  catch
    error:_ -> {error, {parseError, hdg, Params}}
  end.      

%% $--HDT,Heading,T
%% Heading        x.x heading in degrees, true
%%
%% Example: $HCHDT,86.2,T*15
extract_hdt(Params) ->
  try
    [BHeading,<<"T">>] = re:split(Params, ","),
    Heading = safe_binary_to_float(BHeading),
    {nmea, {hdt, Heading}}
  catch
    error:_ -> {error, {parseError, hdt, Params}}
  end.      

%% $--XDR,a,x.x,a,c--c, ..... 
%%  Type   a
%%  Data   x.x 
%%  Units  a
%%  Name   c--c
%%  More of the same .....
%%
%% Example: $HCXDR,A,-0.8,D,PITCH,A,0.8,D,ROLL,G,122,,MAGX,G,1838,,MAGY,G,-667,,MAGZ,G,1959,,MAGT*11
extract_xdr(Params) ->
  try
    BLst = re:split(Params, ","),
    Lst = lists:map(fun(Idx) ->
                        [BType,BData,BUnits,BName] = lists:sublist(BLst, Idx, 4),
                        Data = safe_binary_to_float(BData),
                        {binary_to_list(BType), Data, binary_to_list(BUnits), binary_to_list(BName)}
                    end, lists:seq(1, length(BLst) div 4)),
    {nmea, {xdr, Lst}}
  catch
    error:_ -> {error, {parseError, xdr, Params}}
  end.      

%% $--VTG,<TMGT>,T,<TMGM>,M,<Knots>,N,<KPH>,[FAA,]K
%% TMGT  x.x Track made good (degrees true), track made good is relative to true north
%% TMGM  x.x Track made good (degrees magnetic), track made good is relative to magnetic north
%% Knots x.x speed is measured in knots
%% KPH   x.x speed over ground is measured in kph
%% FAA mode is optional
%%
%% Example: $GPVTG,054.7,T,034.4,M,005.5,N,010.2,K*48
extract_vtg(Params) ->
  try
    [BTMGT,<<"T">>,BTMGM,<<"M">>,BKnots,<<"N">>,BKPH,<<"K">>] = lists:sublist(re:split(Params, ","),8),
    %% optional FAA mode dropped
    %% KPH = Knots * 0.539956803456
    [TMGT,TMGM,Knots,_KPH] = [safe_binary_to_float(X) || X <- [BTMGT,BTMGM,BKnots,BKPH]],
    {nmea, {vtg, TMGT,TMGM,Knots}}
  catch
    error:_ -> {error, {parseError, vtg, Params}}
  end.      

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
extract_tnthpr(Params) ->
  try
    [BHeading,BHStatus,BPitch,BPStatus,BRoll,BRStatus] = re:split(Params, ","),
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
  end.      

extract_smcs(Params) ->
  try
    [BPitch,BRoll,BHeave] = re:split(Params, ","),
    [Roll, Pitch, Heave] = [ safe_binary_to_float(X) || X <- [BRoll,BPitch,BHeave]],
    {nmea, {smcs, Roll, Pitch, Heave}}
  catch
    error:_ -> {error, {parseError, tnthpr, Params}}
  end.

%% $--DBS,<Df>,f,<DM>,M,<DF>,F
%% Depth below surface (pressure sensor)
%% Df x.x Depth in feets  
%% DM x.x Depth in meters 
%% DF x.x Depth in fathoms
%%
%% Example: $SDDBS,2348.56,f,715.78,M,391.43,F*4B
extract_dbs(Params) ->
  try
    [_BDf,<<"f">>,BDM,<<"M">>,_BDF,<<"F">>] = re:split(Params, ","),
    DM = safe_binary_to_float(BDM),
    {nmea, {dbs, DM}}
  catch
    error:_ -> {error, {parseError, dbs, Params}}
  end.      

%% $--DBT,<Df>,f,<DM>,M,<DF>,F
%% Depth Below Transducer (echolot)
%% Water depth referenced to the transducer’s position. Depth value expressed in feet, metres and fathoms.
%% Df x.x Depth in feets  
%% DM x.x Depth in meters 
%% DF x.x Depth in fathoms
%%
%% Example: $SDDBT,8.1,f,2.4,M,1.3,F*0B
extract_dbt(Params) ->
  try
    [_BDf,<<"f">>,BDM,<<"M">>,_BDF,<<"F">>] = re:split(Params, ","),
    DM = safe_binary_to_float(BDM),
    {nmea, {dbt, DM}}
  catch
    error:_ -> {error, {parseError, dbt, Params}}
  end.      

safe_fmt(Fmts,Values) ->
  lists:map(fun({_,nothing}) -> "";
               ({Fmt,V}) ->
                T = hd(lists:reverse(Fmt)),
                Value = case T of $f -> float(V); _ -> V end,
                flatten(io_lib:format(Fmt,[Value]))
            end, lists:zip(Fmts,Values)).

safe_fmt(Fmts, Values, Join) ->
  Z = lists:reverse(lists:zip(Fmts,Values)),
  lists:foldl(fun({_,nothing},Acc) -> [Join, "" | Acc];
                 ({Fmt,V},Acc)     ->
                  T = hd(lists:reverse(Fmt)),
                  Value = case T of $f -> float(V); _ -> V end,
                  [Join, lists:flatten(io_lib:format(Fmt,[Value])) | Acc]
              end, "", Z).


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
  flatten(["GPZDA", SUTC, SDate]).

%% Example: $GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
build_rmc(UTC,Status,Lat,Lon,Speed,Tangle,Date,Magvar) ->
  SUTC = utc_format(UTC),
  SStatus = case Status of active -> ",A"; _ -> ",V" end,
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  {YY,MM,DD} = Date,
  SDate = io_lib:format("~2.10.0B~2.10.0B~2.10.0B",[DD,MM,YY rem 100]),
  ME = case Magvar < 0 of true -> "W"; _ -> "E" end,
  SRest = safe_fmt(["~5.1.0f","~5.1.0f","~s","~5.1.0f","~s"], [Speed,Tangle,SDate,abs(Magvar),ME], ","),
  flatten(["GPRMC",SUTC,SStatus,SLat,SLon,SRest]).

%% hhmmss.ss,llll.ll,a,yyyyy.yy,a,x,xx,x.x,x.x,M, x.x,M,x.x,xxxx
build_gga(UTC,Lat,Lon,Q,Sat,HDil,Alt,Geoid,Age,ID) ->
  SUTC = utc_format(UTC),
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  SRest = safe_fmt(["~B","~2.10.0B","~.1.0f","~.1.0f","~s","~.1.0f","~s","~.1.0f","~4.4.0B"],
                   [Q,Sat,HDil,Alt,"M",Geoid,"M",Age,ID],","),
  flatten(["GPGGA",SUTC,SLat,SLon,SRest]).

build_evolbl(Type,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure) ->
  S = safe_fmt(["~s","~s","~B","~B","~.7.0f","~.7.0f","~.2.0f","~.2.0f"],
               [Type,"r",Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure],","),
  flatten(["PEVOLBL",S,",,,"]).

build_evolbp(UTC, Basenodes, Address, Status, Lat_rad, Lon_rad, Alt, Pressure, SMean, Std) ->
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
           _ -> lists:flatten(io_lib:format("~.3.0f",[float(Std)]))
         end,
  SRest = safe_fmt(["~B","~s","~s","~.7.0f","~.7.0f","~.2.0f","~.2.0f","~s","~s","~s","~.3.0f","~s"],
                   [Address,Status,"r",Lat_rad,Lon_rad,Alt,Pressure,"","","",SMean,SStd],","),
  flatten(["PEVOLBP",SUTC,SNodes,SRest]).

build_simsvt(Total, Idx, Lst) ->
  SPoints = lists:map(fun({D,S}) ->
                          safe_fmt(["~.2.0f","~.2.0f"], [D, S], ",")
                      end, Lst),
  STail = lists:map(fun(_) -> ",," end, 
                    try lists:seq(1,4-length(Lst)) catch _:_ -> [] end),
  SHead = io_lib:format(",~B,~B", [Total, Idx]),
  flatten(["PSIMSVT,P",SHead,SPoints,STail]).

%% Example: $PSXN,23,0.02,-0.76,330.56,*0B
build_sxn(23,Roll,Pitch,Heading,Heave) ->
  SRest = safe_fmt(["~.2f","~.2f","~.2f","~.2f"],
                   [Roll,Pitch,Heading,Heave], ","),
  flatten(["PSXN,23",SRest]).

%% $PSAT,HPR,TIME,HEADING,PITCH,ROLL,TYPE*CC<CR><LF>
build_sat(hpr,UTC,Heading,Pitch,Roll,Type) ->
  SUTC = utc_format(UTC),
  SHPR = safe_fmt(["~.2f","~.2f","~.2f"], [Heading,Pitch,Roll], ","),
  SType = case Type of gps -> ",N"; gyro -> ",G"; _ -> "," end,
  % почему не ставится запятая перед SType? почему она ставится перед SUTC и SHPR?
  flatten(["PSAT,HPR",SUTC,SHPR,SType]).

%% $PIXSE,ATITUD,-1.641,-0.490*6D
build_ixse(atitud,Roll,Pitch) ->
  SPR = safe_fmt(["~.3f","~.3f"], [Roll,Pitch], ","),
  flatten(["PIXSE,ATITUD",SPR]).

%% $PIXSE,POSITI,53.10245714,8.83994382,-0.115*71
build_ixse(positi,Lat,Lon,Alt) ->
  SPR = safe_fmt(["~.8f","~.8f","~.3f"], [Lat,Lon,Alt], ","),
  flatten(["PIXSE,POSITI",SPR]).

%% $PASHR,200345.00,78.00,T,-3.00,+2.00,+0.00,1.000,1.000,1.000,1,1*32
build_ashr(UTC,Heading,True,Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq) ->
  SUTC = utc_format(UTC),
  STrue = case True of true -> ",T"; _ -> "," end,
  SHeading = safe_fmt(["~.2f"], [Heading], ","),
  % how to printf("%+.2f", Roll); with io:format()?
  RollFmt = case Roll of N when N >= 0 -> "+~.2f"; _ -> "~.2f" end,
  PitchFmt = case Pitch of M when M >= 0 -> "+~.2f"; _ -> "~.2f" end,
  HeadingFmt = case Heading of K when K >= 0 -> "+~.2f"; _ -> "~.2f" end,
  SRest = safe_fmt([RollFmt,PitchFmt,HeadingFmt,"~.3f","~.3f","~.3f","~B","~B"], [Roll,Pitch,Res,RollSTD,PitchSTD,HeadingSTD,GPSq,INSq], ","),
  flatten(["PASHR",SUTC,SHeading,STrue,SRest]).

%% $PRDID,PPP.PP,RRR.RR,xxx.xx
build_rdid(Pitch,Roll,Heading) ->
  SPRH = safe_fmt(["~.2f","~.2f","~.2f"], [Pitch,Roll,Heading], ","),
  flatten(["PRDID",SPRH]).

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
  flatten(["PHOCT,01",SUTC,S(TmS),SLt,SHd,S(HdS),SRl,S(RlS),SPt,S(PtS),SHvI,S(HvS),SRest]).

build_evo(Request) ->
  "PEVO," ++ Request.

%% $-EVOTDP,Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll
build_evotdp(Transceiver,Max_range,Sequence,LAx,LAy,LAz,HL,Yaw,Pitch,Roll) ->
  SLst = lists:reverse(
           lists:foldl(fun(V,[])  -> [integer_to_list(V)];
                          (V,Acc) -> [integer_to_list(V),":"|Acc]
                       end, "", Sequence)),
  flatten(["PEVOTDP",
           safe_fmt(["~B","~B","~s","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f","~.2.0f"],
                    [Transceiver,Max_range,flatten(SLst),LAx,LAy,LAz,HL,Yaw,Pitch,Roll],",")]).

%% $-EVORCM,RX,RX_phy,Src,RSSI,Int,P_src,TS,A1:...:An,TS1:...:TSn,TD1:...TDn,TDOA1:...:TDOAn
build_evorcm(RX_utc,RX_phy,Src,RSSI,Int,PSrc,TS,AS,TSS,TDS,TDOAS) ->
  SFun = fun(nothing) -> "";
            (Lst) -> lists:flatten(
                       lists:reverse(
                         lists:foldl(fun(V,[])  -> [safe_fmt(["~B"],[V])];
                                        (V,Acc) -> [safe_fmt(["~B"],[V]),":"|Acc]
                                     end, "", Lst))) end,
  SRX = utc_format(RX_utc),
  flatten(["PEVORCM",SRX,
           safe_fmt(["~B","~B","~.2.0f","~B","~B","~B","~s","~s","~s","~s"],
                    [RX_phy,Src,PSrc,RSSI,Int,TS,SFun(AS),SFun(TSS),SFun(TDS),SFun(TDOAS)],",")]).

%% $-EVOSEQ,sid,total,maddr,range,seq
build_evoseq(Sid,Total,MAddr,Range,Seq) ->
  SFun = fun(nothing) -> "";
            (Lst) -> lists:flatten(
                       lists:reverse(
                         lists:foldl(fun(V,[])  -> [safe_fmt(["~B"],[V])];
                                        (V,Acc) -> [safe_fmt(["~B"],[V]),":"|Acc]
                                     end, "", Lst))) end,
  flatten(["PEVOSEQ",safe_fmt(["~B","~B","~B","~B","~s"],
                              [Sid,Total,MAddr,Range,SFun(Seq)],",")]).

%% $-EVOCTL,BUSBL,Lat,N,Lon,E,Alt,Mode,IT,MP,AD
build_evoctl(busbl, {Lat, Lon, Alt, Mode, IT, MP, AD}) ->
  SLat = lat_format(Lat),
  SLon = lon_format(Lon),
  SMode = case Mode of
            silent -> "S";
            transponder -> "T";
            Seq when is_list(Seq) ->
              foldl(fun(Id,Acc) ->
                        Acc ++ ":" ++ integer_to_list(Id)
                    end, integer_to_list(hd(Seq)), tl(Seq))
          end,
  flatten(["PEVOCTL,BUSBL",SLat,SLon,
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
  flatten(["PEVOCTL,SBL",
           safe_fmt(["~.3.0f","~.3.0f","~.3.0f","~s","~B","~B","~B"],
                    [X,Y,Z,SMode,IT,MP,AD],",")]);
%% $PEVOCTL,SUSBL,Seq,MRange,SVel
build_evoctl(sbl, {Seq, MRange, SVel}) ->
    SSeq = foldl(fun(Id,Acc) ->
                         Acc ++ ":" ++ integer_to_list(Id)
                 end, integer_to_list(hd(Seq)), tl(Seq)),
  flatten(["PEVOCTL,SUSBL",
           safe_fmt(["~s","~.1.0f","~.1.0f"],
                    [SSeq,MRange,SVel],",")]).

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
  flatten(["PEVORCT",STX,STX_phy,SLat,SLon,
           safe_fmt(["~.2.0f","~s","~.2.0f","~s","~.1.0f","~.1.0f","~.1.0f","~s","~.2.0f","~.2.0f","~.2.0f","~.2.0f"],
                    [Alt,SStatus(GPSS),P,SStatus(PS),Yaw,Pitch,Roll,SStatus(AHRSS),Lx,Ly,Lz,HL], ",")]).

%% $-EVOTAP,Forward,Right,Down,Spare1,Spare2,Spare3
build_evotap(Forward, Right, Down) ->
  flatten(["PEVOTAP",
           safe_fmt(["~.2.0f","~.2.0f","~.2.0f"], [Forward,Right,Down], ","),
           ",,,"]).

%% $-EVOTPC,Pair,Praw,Ptrans,S_ptrans,Yaw,Pitch,Roll,S_arhs,HL
build_evotpc(Pair,Praw,{Ptrans,S_trans},{Yaw,Pitch,Roll,S_ahrs},HL) ->
  SStatus = fun(undefined)    -> "";
               (raw)          -> "R";
               (interpolated) -> "I";
               (ready)        -> "N"
            end,
  flatten(["PEVOTPC",
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
  flatten(["PEVORCP",
           safe_fmt(["~s","~s","~s","~.2.0f","~s","~B","~s"], [SType, SStatus, Substatus, Interval, SMode, NCycles, SCast], ","),
           ",,"]).

%% $PEVOSSB,UTC,TID,S,Err,CS,FS,X,Y,Z,Acc,Pr,Vel
build_evossb(UTC,TID,S,Err,CS,FS,X,Y,Z,Acc,Pr,Vel) ->
  SUTC = utc_format(UTC),
  SS = case S of
         ok -> "OK";
         nok -> "NOK"
       end,
  {SCS,Fmt} = case CS of
                lf -> {<<"LF">>,"~.2.0f"};
                enu -> {<<"ENU">>,"~.2.0f"};
                geod -> {<<"GEOD">>,"~.6.0f"}
        end,
  SFS = case FS of
          measured -> <<"M">>;
          filtered -> <<"F">>;
          reconstructed -> <<"R">>
        end,
  flatten(["PEVOSSB",SUTC,
           safe_fmt(["~B","~s","~s","~s","~s",Fmt,Fmt,Fmt,"~.2.0f","~.2.0f","~.2.0f"],
                    [TID, SS, Err, SCS, SFS, X, Y, Z, Acc, Pr, Vel], ",")
          ]).

%% $PEVOSSA,UTC,TID,S,Err,CS,FS,B,E,Acc,Pr,Vel
build_evossa(UTC,TID,S,Err,CS,FS,B,E,Acc,Pr,Vel) ->
  SUTC = utc_format(UTC),
  SS = case S of
         ok -> "OK";
         nok -> "NOK"
       end,
  {SCS,Fmt} = case CS of
                lf -> {<<"LF">>,"~.2.0f"};
                enu -> {<<"ENU">>,"~.2.0f"};
                geod -> {<<"GEOD">>,"~.6.0f"}
        end,
  SFS = case FS of
          measured -> <<"M">>;
          filtered -> <<"F">>;
          reconstructed -> <<"R">>
        end,
  flatten(["PEVOSSA",SUTC,
           safe_fmt(["~B","~s","~s","~s","~s",Fmt,Fmt,"~.2.0f","~.2.0f","~.2.0f"],
                    [TID, SS, Err, SCS, SFS, B, E, Acc, Pr, Vel], ",")
          ]).

build_hdg(Heading,Dev,Var) ->
  F = fun(V) -> case V < 0 of true -> {"W",-V}; _ -> {"E",V} end end,
  {DevS,DevA} = F(Dev),
  {VarS,VarA} = F(Var),
  flatten(["HCHDG",safe_fmt(["~.1.0f","~.1.0f","~s","~.1.0f","~s"],[Heading,DevA,DevS,VarA,VarS],",")]).

build_hdt(Heading) ->
  flatten(["HCHDT", safe_fmt(["~.1.0f"],[Heading],","),",T"]).

build_xdr(Lst) ->
  F = fun(V) -> if is_integer(V) -> "~B"; true -> "~.1.0f" end end,
  flatten(["HCXDR", lists:map(fun({Type,Data,Units,Name}) ->
                                  safe_fmt(["~s",F(Data),"~s","~s"],[Type,Data,Units,Name],",")
                              end, Lst)]).

build_vtg(TMGT,TMGM,Knots) ->
  KMH = if is_number(Knots) -> Knots*0.539956803456; true -> nothing end,
  Fields = safe_fmt(["~5.1.0f","~5.1.0f","~5.1.0f","~5.1.0f"],[TMGT,TMGM,Knots,KMH]),
  flatten(io_lib:format("GPVTG,~s,T,~s,M,~s,N,~s,K",Fields)).

build_tnthpr(Heading,HStatus,Pitch,PStatus,Roll,RStatus) ->
  flatten(["PTNTHPR",
           safe_fmt(["~.1.0f","~s","~.1.0f","~s","~.1.0f","~s"],
                    [Heading,HStatus,Pitch,PStatus,Roll,RStatus], ",")]).

build_smcs(Roll,Pitch,Heave) ->
  flatten(["PSMCS",
           safe_fmt(["~.1.0f","~.1.0f","~.1.0f"],
                    [Roll,Pitch,Heave], ",")]).

build_dbs(Depth) ->
  Fmts = ["~.2.0f","~.2.0f","~.2.0f"],
  Fields = safe_fmt(Fmts, case Depth of
                            nothing -> [nothing, nothing, nothing];
                            _ -> [Depth * 3.2808399, Depth, Depth * 0.546806649]
                          end),
  flatten(io_lib:format("SDDBS,~s,f,~s,M,~s,F",Fields)).

build_dbt(Depth) ->
  Fmts = ["~.2.0f","~.2.0f","~.2.0f"],
  Fields = safe_fmt(Fmts, case Depth of
                            nothing -> [nothing, nothing, nothing];
                            _ -> [Depth * 3.2808399, Depth, Depth * 0.546806649]
                          end),
  flatten(io_lib:format("SDDBT,~s,f,~s,M,~s,F",Fields)).

from_term_helper(Sentense) ->
  case Sentense of
    {rmc,UTC,Status,Lat,Lon,Speed,Tangle,Date,Magvar} ->
      build_rmc(UTC,Status,Lat,Lon,Speed,Tangle,Date,Magvar);
    {gga,UTC,Lat,Lon,Q,Sat,HDil,Alt,Geoid,Age,ID} ->
      build_gga(UTC,Lat,Lon,Q,Sat,HDil,Alt,Geoid,Age,ID);
    {zda,UTC,DD,MM,YY,Z1,Z2} ->
      build_zda(UTC,DD,MM,YY,Z1,Z2);
    {evolbl,Type,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure} ->
      build_evolbl(Type,Loc_no,Ser_no,Lat_rad,Lon_rad,Alt,Pressure);
    {evolbp,UTC,Basenodes,Address,Status,Lat_rad,Lon_rad,Alt,Pressure,SMean,Std} ->
      build_evolbp(UTC,Basenodes,Address,Status,Lat_rad,Lon_rad,Alt,Pressure,SMean,Std);
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
    {evossb,UTC,TID,S,Err,CS,FS,X,Y,Z,Acc,Pr,Vel} ->
      build_evossb(UTC,TID,S,Err,CS,FS,X,Y,Z,Acc,Pr,Vel);
    {evossa,UTC,TID,S,Err,CS,FS,B,E,Acc,Pr,Vel} ->
      build_evossa(UTC,TID,S,Err,CS,FS,B,E,Acc,Pr,Vel);
    {evoseq,Sid,Total,MAddr,Range,Seq} ->
      build_evoseq(Sid,Total,MAddr,Range,Seq);
    {evoctl, busbl, {Lat, Lon, Alt, Mode, IT, MP, AD}} ->
      build_evoctl(busbl, {Lat, Lon, Alt, Mode, IT, MP, AD});
    {evoctl, sbl, {X, Y, Z, Mode, IT, MP, AD}} ->
      build_evoctl(sbl, {X, Y, Z, Mode, IT, MP, AD});
    {evoctl, susbl, Args} ->
      build_evoctl(susbl, Args);
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
    _ -> ""
  end.

%% TODO: code Lat/Lon N/E with sign?
from_term({nmea, Sentense}, Cfg) ->
  #{out := OutRule} = Cfg,
  Flag = is_filtered(Sentense, OutRule),
  Body = if Flag -> from_term_helper(Sentense);
            true -> ""
         end,
  case length(Body) of
    0 -> [<<>>, Cfg];
    _ ->
      CS = checksum(Body),
      [list_to_binary(flatten(["$",Body,"*",io_lib:format("~2.16.0B",[CS]),"\r\n"])), Cfg]
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
  
