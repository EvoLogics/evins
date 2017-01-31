-module(fsm_inv_usbl_gen).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3, handle_sendim/3, handle_alarm/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                 {sendim_timout, sendim},
                 {get_distance, sendim}
                 ]},

                {sendim,
                  [{im_sent, idle},
                  {sendim_timout, sendim},
                  {get_distance, sendim}]},

                {alarm,[]}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> internal.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  Dst = share:get(SM, dst),
  case Term of
    {timeout, answer_timeout} ->
      SM;
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {async, _, {recvpbm, _, Dst, _, _, _, _, _, Payl}} ->
    %{async, _, {recvims , _, _, _, _, _, _, _, _, Payl}} ->
      io:format("RAngles: ~p~n", [extractAM(Payl)]),
      SM;
    {async, {deliveredim, Dst}} ->
      fsm:run_event(MM, SM#sm{event = get_distance}, {get_distance, Dst});
    {sync,"?T", Distance} ->
      Timeout = share:get(SM, gen_timeout),
      {IDistance, _} = string:to_integer(Distance),
      D = (IDistance / 1000000) * 1500 * 10,
      share:put(SM, distance, round(D) ),
      SM1 = fsm:set_timeout(SM, {s, Timeout}, sendim_timout),
      fsm:clear_timeout(SM1, answer_timeout);
    {sync, _Req, _Answer} ->
      fsm:clear_timeout(SM, answer_timeout);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, #sm{event = internal} = SM, _Term) ->
  Timeout = share:get(SM, gen_timeout),
  fsm:set_timeout(SM#sm{event = eps}, {s, Timeout}, sendim_timout);
handle_idle(_MM, SM, _Term) ->
  fsm:set_event(SM, eps).

handle_sendim(_MM, #sm{event = get_distance} = SM, _Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Answer_timeout of
    true  ->
      fsm:set_timeout(SM#sm{event = eps}, {ms, 100}, get_distance);
    false ->
      SM1 = fsm:send_at_command(SM, {at, "?T", ""}),
      fsm:set_event(SM1, eps)
  end;
handle_sendim(_MM, SM, _Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Answer_timeout of
    true  ->
      fsm:set_event(SM, eps);
    false ->
      AT = createIM(SM),
      SM1 = fsm:send_at_command(SM, AT),
      fsm:set_event(SM1, im_sent)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

% -----------------------------------------------------------------------
createIM(SM) ->
  Dst = share:get(SM, dst),
  Pid = share:get(SM, pid),
  D = share:get(SM, distance),
  Data =
  case D of
    nothing ->
      <<"N">>;
    _ ->
      <<"D", D:16/little-unsigned-integer>>
  end,
  {at, {pid, Pid}, "*SENDIM", Dst, ack, Data}.


extractAM(Payload) ->
  <<"L", Bearing:12/little-unsigned-integer,
    Elevation:12/little-unsigned-integer,
    Roll:12/little-unsigned-integer,
    Pitch:12/little-unsigned-integer,
    Yaw:12/little-unsigned-integer, _/bitstring>> = Payload,
  lists:map(fun(A) -> A / 10 end, [Bearing, Elevation, Roll, Pitch, Yaw]).
