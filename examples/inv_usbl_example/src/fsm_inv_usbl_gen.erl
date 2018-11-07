-module(fsm_inv_usbl_gen).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> share:put(SM, heading, 0).
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(_MM, SM, Term) ->
  RAddr = share:get(SM, dst),
  LAddr = share:get(SM, local_address),

  case Term of
    {allowed} ->
      TM = share:get(SM, query_timeout),
      fsm:set_timeout(SM, {ms, TM}, query_timeout);

    {denied} ->
      fsm:clear_timeout(SM, query_timeout);

    {timeout, query_timeout} ->
      TM = share:get(SM, query_timeout),
      [fsm:set_timeout(__, {ms, TM}, query_timeout),
       fsm:send_at_command(__, createIM(SM))](SM);

    %% ------ IM logic -------
    {async, _, {recvpbm, _, RAddr, LAddr, _, _, _, _, _Payload}} ->
      %io:format("RAngles: ~p~n", [extractAM(Payload)]),
      SM;

    {async, {deliveredim, RAddr}} ->
      fsm:send_at_command(SM, {at, "?T", ""});

    {async, {failedim, RAddr}} ->
      TM = share:get(SM, query_delay),
      [fsm:clear_timeout(__, query_timeout),
       fsm:set_timeout(__, {ms, TM}, query_timeout)](SM);

    {sync, "?T", PTimeStr} ->
      Delay = share:get(SM, query_delay),
      {PTime, _} = string:to_integer(PTimeStr),
      Dist = PTime * 1500.0e-6,
      %io:format("LDistance: ~p~n", [Dist]),
      [share:put(__, distance, Dist),
       fsm:clear_timeout(__, query_timeout),
       fsm:set_timeout(__, {ms, Delay}, query_timeout),
       fsm:clear_timeout(__, answer_timeout)](SM);

    %% ------ IMS logic -------
    {async, {sendend, RAddr,"ims", STS, _}} ->
      share:put(SM, sts, STS);

    {async, _, {recvims, _, RAddr, LAddr, TS, _, _, _, _, _Payload}} ->
      %io:format("RAngles: ~p~n", [extractAM(Payload)]),
      Delay = share:get(SM, query_delay),
      STS = share:get(SM, sts),
      AD = share:get(SM, answer_delay),
      PTime = (TS - STS - AD * 1000) / 2,
      Dist = PTime * 1500.0e-6,
      %io:format("LDistance: ~p~n", [Dist]),
      [share:put(__, distance, Dist),
       fsm:clear_timeout(__, query_timeout),
       fsm:set_timeout(__, {ms, Delay}, query_timeout)](SM);

    {sync, _Req, _Answer} ->
      fsm:clear_timeout(SM, answer_timeout);

    {nmea, {tnthpr, Heading, _, _Pitch, _, _Roll, _}} ->
       share:put(SM, heading, Heading);

    _ -> SM
  end.

% -----------------------------------------------------------------------
createIM(SM) ->
  RAddr = share:get(SM, dst),
  Pid = share:get(SM, pid),
  Dist = share:get(SM, distance),
  Heading = share:get(SM, heading),
  Mode = share:get(SM, mode),
  Payload = case Dist of
              nothing ->
                <<"N">>;
              _ ->
                V = round(Dist * 10),
                H = round(Heading * 10),
                <<"D", V:16/little-unsigned-integer,
                       H:12/little-unsigned-integer,
                       0:4>>
            end,
  case Mode of
    im  -> {at, {pid, Pid}, "*SENDIM", RAddr, ack, Payload};
    ims -> {at, {pid, Pid}, "*SENDIMS", RAddr, none, Payload}
  end.


%extractAM(Payload) ->
%  case Payload of
%    <<"L", Bearing:12/little-unsigned-integer,
%           Elevation:12/little-unsigned-integer,
%           Roll:12/little-unsigned-integer,
%           Pitch:12/little-unsigned-integer,
%           Yaw:12/little-unsigned-integer, _/bitstring>> ->
%      lists:map(fun(A) -> A / 10 end, [Bearing, Elevation, Roll, Pitch, Yaw]);
%    _ -> nothing
%  end.
