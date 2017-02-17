-module(fsm_inv_usbl_gen).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3,handle_waiting_answer/3,handle_alarm/3]).

-define(TRANS, [{idle,
                 [{init, idle},
                  {send_at_command, waiting_answer},
                  {sync_answer, alarm},
                  {answer_timeout, alarm}]},

                {waiting_answer,
                 [{send_at_command, waiting_answer},
                  {sync_answer, waiting_answer},
                  {empty_queue, idle},
                  {answer_timeout, alarm}]},

                {alarm,[]}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> share:put(SM, heading, 0).
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> init.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  RAddr = share:get(SM, dst),
  LAddr = share:get(SM, local_address),
  case Term of
    {timeout, answer_timeout} ->
      fsm:run_event(MM, SM#sm{event=answer_timeout}, {});

    {timeout, query_timeout} ->
      TM = share:get(SM, query_timeout),
      [fsm:set_timeout(__, {ms, TM}, query_timeout),
       fsm:run_event(MM, __#sm{event = send_at_command}, createIM(SM))
      ](SM);

    %% ------ IM logic -------
    {async, _, {recvpbm, _, RAddr, LAddr, _, _, _, _, _Payload}} ->
      %io:format("RAngles: ~p~n", [extractAM(Payload)]),
      SM;

    {async, {deliveredim, RAddr}} ->
      fsm:run_event(MM, SM#sm{event = send_at_command}, {at, "?T", ""});

    {async, {failedim, RAddr}} ->
      TM = share:get(SM, query_delay),
      [fsm:clear_timeout(__, query_timeout),
       fsm:set_timeout(__, {ms, TM}, query_timeout)
      ](SM);

    {sync, "?T", PTimeStr} ->
      Delay = share:get(SM, query_delay),
      {PTime, _} = string:to_integer(PTimeStr),
      Dist = PTime * 1500.0e-6,
      %io:format("LDistance: ~p~n", [Dist]),
      [share:put(__, distance, Dist),
       fsm:clear_timeout(__, query_timeout),
       fsm:set_timeout(__, {ms, Delay}, query_timeout),
       fsm:clear_timeout(__, answer_timeout),
       fsm:run_event(MM, __#sm{event=sync_answer}, {})
      ](SM);

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
       fsm:set_timeout(__, {ms, Delay}, query_timeout)
      ](SM);

    {sync, _Req, _Answer} ->
      [fsm:clear_timeout(__, answer_timeout),
       fsm:run_event(MM, __#sm{event=sync_answer}, {})
      ](SM);

    {nmea, {tnthpr, Heading, _, _Pitch, _, _Roll, _}} ->
       share:put(SM, heading, Heading);

    _ -> SM
  end.

handle_idle(_MM, SM, _Term) ->
  case SM#sm.event of
    init ->
      Delay = share:get(SM, query_delay),
      [share:put(__, at_queue, queue:new()),
       fsm:set_timeout(__, {ms, Delay}, query_timeout),
       fsm:set_event(__, eps)
      ](SM);
    _ -> fsm:set_event(SM, eps)
  end.

handle_waiting_answer(_MM, SM, Term) ->
  AQ = share:get(SM, at_queue),
  case SM#sm.event of
    send_at_command ->
      SM1 = case fsm:check_timeout(SM, answer_timeout) of
              true ->
                share:put(SM, at_queue, queue:in(Term, AQ));
              _ ->
                fsm:send_at_command(SM, Term)
            end,
      fsm:set_event(SM1, eps);

    sync_answer ->
      case queue:out(AQ) of
        {{value, AT}, AQn} ->
          [fsm:send_at_command(__, AT),
           share:put(__, at_queue, AQn),
           fsm:set_event(__, eps)
          ](SM);

        {empty, _} ->
          fsm:set_event(SM, empty_queue)
      end;

    _ -> fsm:set_event(SM, eps)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

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
