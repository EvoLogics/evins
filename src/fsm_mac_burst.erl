-module(fsm_mac_burst).
-behaviour(fsm).

-include("fsm.hrl").

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
    {rcv_ul, Msg = {at, _PID, _, _, _}} ->
      fsm:run_event(MM, SM#sm{event = send_data}, {try_send, {sendburst, Msg}});
    {rcv_ul, Msg = {at, _PID, "*SENDIM", _, _, _}} ->
      fsm:run_event(MM, SM#sm{event = send_data}, {try_send, {sendim, Msg}});
    {rcv_ul, {at, _, _, _}} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } }),
      SM;
    {async, {pid, NPid}, Tuple} ->
      [H | T] = tuple_to_list(Tuple),
      BPid = <<"p", (integer_to_binary(NPid))/binary>>,
      fsm:cast(SM, alh, {send, {async, list_to_tuple([H | [BPid|T]])} }),
      fsm:run_event(MM, SM, {});
    {async, Tuple} ->
      fsm:cast(SM, alh, {send, {async, Tuple} });
    {sync, _Req, Answer} ->
      SMAT = fsm:clear_timeout(SM, answer_timeout),
      fsm:cast(SMAT, alh, {send, {sync, Answer} }),
      fsm:run_event(MM, SMAT#sm{event = sync}, {});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _Term) ->
  SM#sm{event = eps}.

handle_send(_MM, SM, Term) ->
Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    {try_send, {sendburst, AT = {at, _PID, _, _, _}} } when Answer_timeout == false ->
      SM1 = fsm:send_at_command(SM, AT),
      SM1#sm{event = eps};

    {try_send, {sendim, {at, PID, SENDIM, Dst, _, Data}} } when Answer_timeout == false ->
      [_, Flag, _, _, _, _, _] = nl_mac_hf:extract_payload_nl_flag(Data),
      NLFlag = nl_mac_hf:num2flag(Flag, nl),
      ACK =
      if NLFlag == data -> ack;
      true -> noack end,

      SM1 = fsm:send_at_command(SM, {at, PID, SENDIM, Dst, ACK, Data} ),
      SM1#sm{event = eps};

    {try_send, _} ->
      fsm:set_timeout(SM, {ms, 500}, Term);
    _ ->
      SM#sm{event = eps}
  end.


-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions------------------------