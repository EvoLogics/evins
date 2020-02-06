-module(fsm_pos_nl).
-behaviour(fsm).

-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_idle/3, handle_alarm/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle}
                 ]},

                {alarm, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  LA = share:get(SM, local_address),
  ?INFO(?ID, "HANDLE EVENT  ~150p ~p LA ~p~n", [MM, Term, LA]),
  case Term of
     {connected} ->
      case MM#mm.role of
        nl ->
          [fsm:set_timeout(__, {s, 1}, get_address),
           fsm:cast(__, nl, {send, {nl, get, address}})
          ](SM);
        _ -> SM
      end;
    {timeout, get_address} ->
      [fsm:set_timeout(__, {s, 1}, get_address),
       fsm:cast(__, nl, {send, {nl, get, address}})
      ](SM);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {nl, address, A} ->
      [fsm:clear_timeout(__, get_address),
       share:put(__, local_address, A),
       fsm:cast(__, nl_impl, {send, Term})
      ](SM);
    {nl, get, help} ->
      NHelp = string:concat(?MUXHELP, ?HELP),
      fsm:cast(SM, nl_impl, {send, {nl, help, NHelp}});
    {nl, error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {nl, recv, _, _, _} ->
      decode(SM, Term);
    {send_error, formError} when MM#mm.role == nl ->
      SM;
    Tuple when MM#mm.role == nl ->
      fsm:cast(SM, nl_impl, {send, Tuple});
    Tuple when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl, {send, Tuple});
    {nmea, Nmea} ->
      handle_nmea(SM, Nmea);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p from ~p~n", [?MODULE, UUg, MM#mm.role]),
      SM
  end.

handle_idle(_MM, SM, _) ->
  fsm:set_event(SM, eps).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_nmea(SM, {evossb,_,_,_,xyz,crp,raw,X,Y,Z,_,_,_,_,_}) ->
  Angles = env:get(SM, last_angles),
  Pos = {X,Y,Z},
  Coded = encode(Pos, Angles),
  P = <<1:1, 0:5, 1:1, 1:1, Coded/binary>>,
  RA = share:get(SM, remote_address),
  Tuple = {nl, send, RA, P},
  fsm:cast(SM, nl, {send, Tuple});
handle_nmea(SM, {evorpy,_,_,_,computed,R,P,Yw}) ->
  env:put(SM, last_angles, {R,P,Yw});
handle_nmea(SM, _) -> SM.

decode(SM, Tuple = {nl, recv, Dst, Src, <<1:1, 0:5, 1:1, 1:1, BData/binary>>}) ->
  try
    <<X:64/float, Y:64/float, Z:64/float, R:64/float, P:64/float, Yw:64/float>> = BData,
    NLStr = io_lib:format("~.5f;~.5f;~.5f;~.5f;~.5f;~.5f", [X,Y,Z,R,P,Yw]),
    PEVOSSB = {evossb,0,0,0,xyz,crp,raw,X,Y,Z,0,0,0,nothing,nothing},
    PEVORPY = {evorpy,0,0,0,computed,R,P,Yw},
    [fsm:cast(__, nl_impl, {send, {nl, recv, Dst, Src, list_to_binary(NLStr)}}),
     fsm:cast(__, nmea, {send, {nmea, PEVOSSB}}),
     fsm:cast(__, nmea, {send, {nmea, PEVORPY}})
    ](SM)
  catch error:_Error ->
    fsm:cast(SM, nl_impl, {send, Tuple})
  end;
decode(SM, Tuple) ->
  fsm:cast(SM, nl_impl, {send, Tuple}).

encode(Pos, nothing) ->
  encode(Pos, {0,0,0});
encode({X,Y,Z}, {R,P,Yw}) ->
  L = [X,Y,Z,R,P,Yw],
  lists:foldr(fun (A, B) -> <<A:64/float, B/binary>> end, <<>>, L).