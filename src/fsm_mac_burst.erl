-module(fsm_mac_burst).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3, handle_send/3, handle_backoff/3, handle_final/3]).


-define(TRANS, [
                {idle,
                 [{internal, idle},
                  {try_send, send}
                 ]},

                {send,
                 [{try_send, send},
                  {busy, idle},
                  {error, idle},
                  {ok, backoff}
                 ]},

                {backoff,
                 [{delivered, idle},
                  {failed, idle}
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
    {timeout, {send_data, Term}} when SM#sm.state == send ->
      fsm:run_event(MM, SM#sm{event = try_send}, Term);
    {timeout, {send_data, _}} ->
      SM;
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;
    {rcv_ul, {at, _, _, _}} ->
      fsm:cast(SM, alh, {send, {sync, {error, <<"WRONG FORMAT">>} } }),
      SM;
    {rcv_ul, {at, _PID, _, _, _}} when SM#sm.state =/= idle ->
      fsm:cast(SM, alh, {send, {sync, {busy, <<"BUSY BACKOFF STATE">>} } }),
      SM;
    {rcv_ul, Msg = {at, _PID, _, _, _}} ->
      fsm:run_event(MM, SM#sm{event = try_send}, {try_send, Msg});
    {async, {pid, NPid}, Tuple = {recv, _, _, _, _, _, _, _, _, _Payload}} ->
      [H | T] = tuple_to_list(Tuple),
      BPid = <<"p", (integer_to_binary(NPid))/binary>>,
      fsm:cast(SM, alh, {send, {async, list_to_tuple([H | [BPid|T]])} }),
      fsm:run_event(MM, SM, {});
    {async, Tuple} ->
      fsm:cast(SM, alh, {send, {async, Tuple} }),
      Ev = process_async(SM, Tuple),
      fsm:run_event(MM, SM#sm{event = Ev}, {});
    {sync, Req, Answer} ->
      Ev = process_sync(SM, Req,Answer),
      SMAT = fsm:clear_timeout(SM, answer_timeout),
      fsm:cast(SMAT, alh, {send, {sync, Answer} }),
      fsm:run_event(MM, SMAT#sm{event = Ev}, {});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, _Term) ->
  SM#sm{event = eps}.

handle_send(_MM, SM, Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  case Term of
    {try_send, AT = {at, _PID, _, _, _}} when Answer_timeout == false ->
      SM1 = fsm:send_at_command(SM, AT),
      SM1#sm{event = eps};
    {try_send, {at, _PID, _, _, _}} ->
      fsm:set_timeout(SM, {ms, 500}, {send_data, Term});
    _ ->
      SM#sm{event = eps}
  end.

handle_backoff(_MM, SM, _Term) ->
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions------------------------

process_async(_SM, Tuple) ->
  case Tuple of
    {delivered, _, _} ->
      delivered;
    {failed, _, _} ->
      failed;
    _ ->
      eps
  end.

process_sync(#sm{state = send}, "*SEND", Answer) ->
  case Answer of
    "OK" ->
      ok;
    {busy, _} ->
      busy;
    {error, _} ->
      error;
    _ ->
      eps
  end;
process_sync(_SM, _, _Answer) ->
  eps.