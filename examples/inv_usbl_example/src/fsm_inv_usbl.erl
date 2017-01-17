-module(fsm_inv_usbl).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3, handle_sendpbkm/3, handle_alarm/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {answer_timeout, idle},
                  {sendend, idle},
                  {wait_sendend, idle},
                  {recvim, sendpbkm}
                 ]},

                {sendpbkm,
                  [{sendend, sendpbkm},
                  {wait_sendend, sendpbkm},
                  {recvangles, sendpbkm},
                  {sendangles, idle}]},

                {alarm,[]}
               ]).

start_link(SM) ->
  [
   env:put(__,got_sync,true),
   fsm:start_link(__)
  ] (SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> internal.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  Local_addr = share:get(SM, local_address),
  case Term of
    {timeout, answer_timeout} ->
      SM;
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});
    {connected} ->
      SM;
    {async, {sendend, Dst, "pbm|imack", _, _}} ->
      fsm:run_event(MM, SM#sm{event = sendend}, {sendend, Dst});
    {async, {sendend, Dst, "imack", _, _}} ->
      fsm:run_event(MM, SM#sm{event = sendend}, {sendend, Dst});
    {async,  {pid, Pid}, {recvim, _, Dst, Local_addr, ack, _, _, _, _, _}} ->
      fsm:run_event(MM, SM#sm{event = recvim}, {recvim, Pid, Dst});
    {async, {usblangles, _CTime,_MTime, _Raddr, LBearing, LElevation, _Bearing, _Elevation, Roll, Pitch, Yaw, _Rssi, _Integrity, _Accuracy}} ->
      DBearing = wrapAroundDeg( (LBearing * 180) / math:pi() ),
      DElevation = wrapAroundDeg( (LElevation * 180) / math:pi() ),
      DRoll = wrapAroundDeg( (Roll * 180) / math:pi() ),
      DPitch = wrapAroundDeg( (Pitch * 180) / math:pi() ),
      DDYaw = wrapAroundDeg( (Yaw * 180) / math:pi() ),
      B = createPBKM(DBearing, DElevation, DRoll, DPitch, DDYaw),
      ?TRACE(?ID, "ANGLES ~p {Bearing, Elevation, Roll, Pitch, Yaw} = ~p~n", [B, extractPBKM(B)]),
      fsm:run_event(MM, SM#sm{event = wait_sendend}, {pbkm, B});
    {sync, _Req, _Answer} ->
      fsm:clear_timeout(SM, answer_timeout);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _Term) ->
  fsm:set_event(SM, eps).

handle_sendpbkm(_MM, #sm{event = wait_sendend} = SMP, Term) ->
  [Param_Term, SM] = event_params(SMP, Term, senpbk_params),
  case Term of
    {pbkm, Msg} when Param_Term =/= [] ->
      {senpbk_params, Pid, Dst} = Param_Term,
      AT = {at, {pid, Pid}, "*SENDPBM", Dst, Msg},
      SM#sm{event = eps, event_params = {senpbk, Dst, AT} };
    _ ->
      fsm:set_event(SM, eps)
  end;
handle_sendpbkm(_MM, SMP, Term) ->
  Answer_timeout = fsm:check_timeout(SMP, answer_timeout),
  [Param_Term, SM] = event_params(SMP, Term, senpbk),
  case Term of
    {sendend, _} when Answer_timeout == true ->
      fsm:set_event(SM, eps);
    {sendend, Dst} when Param_Term =/= [] ->
      {senpbk, DstP, AT} = Param_Term,
      if DstP == Dst ->
        checkSentMsg(SM, AT),
        SM1 = fsm:send_at_command(SM, AT),
        SM1#sm{event = sendangles};
      true ->
        fsm:set_event(SM, eps)
      end;
    {recvim, Pid, Dst} ->
      SM#sm{event = eps, event_params = {senpbk_params, Pid, Dst} };
    _ ->
      fsm:set_event(SM, eps)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

%---------------------------------------------------------------------
wrapAroundDeg(Angle) ->
  case Angle of
    Angle when Angle < 0 ->
      wrapAroundDeg(Angle + 360);
    Angle when Angle > 360 ->
      wrapAroundDeg(Angle - 360);
    _ ->
      round( Angle * 10 )
  end.

createPBKM(DBearing, DElevation, DRoll, DPitch, DDYaw) ->
  BinMsg = <<"L", DBearing:12, DElevation:12, DRoll:12, DPitch:12, DDYaw:12>>,
  Add = (8 - (bit_size(BinMsg)) rem 8) rem 8,
  <<BinMsg/bitstring, 0:Add>>.

checkSentMsg(SM, AT) ->
  {at, _,"*SENDPBM",_, B} = AT,
  ?TRACE(?ID, "{Bearing, Elevation, Roll, Pitch, Yaw} = ~p~n", [extractPBKM(B)]),
  io:format("{Bearing, Elevation, Roll, Pitch, Yaw} = ~p~n", [extractPBKM(B)]).

extractPBKM(Payl) ->
  <<"L", DBearing:12, DElevation:12, DRoll:12, DPitch:12, DDYaw:12, _/bitstring>> = Payl,
  {DBearing / 10, DElevation / 10, DRoll / 10, DPitch / 10, DDYaw / 10}.

event_params(SM, Term, Event) ->
  if SM#sm.event_params =:= [] ->
       [Term, SM];
     true ->
       EventP = hd(tuple_to_list(SM#sm.event_params)),
       if EventP =:= Event -> [SM#sm.event_params, SM#sm{event_params = []}];
          true -> [Term, SM]
       end
  end.
