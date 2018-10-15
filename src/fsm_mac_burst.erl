-module(fsm_mac_burst).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_send/3, handle_final/3]).


-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {send_data, send}
                 ]},

                {send,
                 [{send_data, send},
                 {sync, idle}
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

%%--------------------------------Handler functions----------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT  ~p   ~p ~n", [MM, SM]),
  ?TRACE(?ID, "~p~n", [Term]),

  case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"ANSWER TIMEOUT">>} } }),
      SM;
    {timeout, {send_data, Term}} ->
      fsm:run_event(MM, SM#sm{event = send_data}, Term);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {rcv_ul, Msg = {at, _PID, _, Src, _}} ->
      case if_busy(SM, Src) of
        busy -> fsm:cast(SM, alh, {send, {sync, {busy, <<"BUSY BACKOFF STATE">>} } });
        _ -> fsm:run_event(MM, SM#sm{event = send_data}, {try_send, {sendburst, Msg}})
      end;
    {rcv_ul, Msg = {at, _PID, "*SENDIM", Src, _, _}} ->
      case if_busy(SM, Src) of
        busy -> fsm:cast(SM, alh, {send, {sync, {busy, <<"BUSY BACKOFF STATE">>} } });
        _ -> fsm:run_event(MM, SM#sm{event = send_data}, {try_send, {sendim, Msg}})
      end;
    {rcv_ul, {at, _, _, _}} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } }),
      SM;
    {async, {pid, NPid}, Tuple} ->
      [H | _] = tuple_to_list(Tuple),
      BPid = <<"p", (integer_to_binary(NPid))/binary>>,
      [SMN, ParsedRecv] = process_recv(SM, Tuple),
      case ParsedRecv of
        {_, _, STuple} ->
          SMsg = list_to_tuple([H | [BPid | tuple_to_list(STuple) ]]),
          fsm:cast(SMN, alh, {send, {async, SMsg} }),
          fsm:run_event(MM, SMN, {});
        _ ->
          SMN
      end;
    {async, Tuple} ->
      process_async(SM, Tuple);
    {sync, _Req, Answer} ->
      SMAT = fsm:clear_timeout(SM, answer_timeout),
      fsm:cast(SMAT, alh, {send, {sync, Answer} }),
      fsm:run_event(MM, SMAT#sm{event = sync}, {});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _Term) ->
  case SM#sm.event of
    internal ->
      share:put(SM, notacked_msg, []),
      SM#sm{event = eps};
    _ -> SM#sm{event = eps}
  end.

handle_send(_MM, SM, Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    {try_send, {sendburst, AT = {at, _PID, _, _, _}} } when Answer_timeout == false ->
      SM1 = mac_hf:send_mac(SM, at, data, AT),
      SM1#sm{event = eps};
    {try_send, {sendburst, {at, _PID, _, _, _}} } ->
      fsm:set_timeout(SM, {ms, 500}, Term);
    {try_send, {sendim, {at, PID, _SENDIM, Dst, _, Data}} } when Answer_timeout == false ->
      [_, Flag, _, _, _, _, _] = mac_hf:extract_payload_nl_flag(Data),
      NLFlag = mac_hf:num2flag(Flag, nl),
      case NLFlag of
      data when Answer_timeout == true ->
        fsm:set_timeout(SM, {ms, 500}, Term);
      data ->
        AT = {at, PID, "*SEND", Dst, Data},
        SM1 = mac_hf:send_mac(SM, at, data, AT),
        SM1#sm{event = eps};
      _ ->
        SM#sm{event = eps}
      end;
    _ ->
      SM#sm{event = eps}
  end.


-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions------------------------
process_async(SM, Tuple) ->
  IfCastMAC =
  case Tuple of
    {deliveredim, Src} ->
      [update_async_list(SM, Src),
      {delivered, mac, Src}];
    {failedim, Src} ->
      [update_async_list(SM, Src),
      {failed, mac, Src}];
    {canceledim, Src} ->
      [update_async_list(SM, Src),
      {failed, mac, Src}];
    {delivered, _, Src} ->
      [inside,
      {delivered, mac, Src}];
    {failed, _, Src} ->
      [inside,
      {failed, mac, Src}];
    _ ->
      [not_inside, nothing]
  end,

  MACTuple =
  case IfCastMAC of
    [inside, NT] -> NT;
    [not_inside, _] -> nothing
  end,

  if MACTuple =/= nothing ->
    fsm:cast(SM, alh, {send, {async, MACTuple} });
  true ->
    nothing
  end,
  fsm:cast(SM, alh, {send, {async, Tuple} }).

update_async_list(SM, Src) ->
  LAsyncs = share:get(SM, notacked_msg),
  Member = lists:member(Src, LAsyncs),
  case LAsyncs of
    [] -> not_inside;
    _ when not Member -> not_inside;
    _ ->
      ULAsyncs = lists:delete(Src, LAsyncs),
      share:put(SM, notacked_msg, ULAsyncs),
      inside
  end.

if_busy(SM, Src) ->
  LAsyncs = share:get(SM, notacked_msg),
  Member = lists:member(Src, LAsyncs),
  case LAsyncs of
    nothing -> not_busy;
    [] -> not_busy;
    _ when Member -> not_busy;
    _ -> busy
  end.

process_recv(SM, T) ->
  ?TRACE(?ID, "MAC_AT_RECVIM ~p~n", [T]),
  {_, Len, P1, P2, P3, P4, P5, P6, P7, Payl} = T,
  [BPid, BFlag, Data, LenAdd] = mac_hf:extract_payload_mac_flag(Payl),

  CurrentPid = ?PROTOCOL_MAC_PID(share:get(SM, macp)),
  if CurrentPid == BPid ->
    Flag = mac_hf:num2flag(BFlag, mac),
    ShortTuple = {Len - LenAdd, P1, P2, P3, P4, P5, P6, P7, Data},
    [SM, {BPid, Flag, ShortTuple}];
  true ->
    [SM, nothing]
  end.