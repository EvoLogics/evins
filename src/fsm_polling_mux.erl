%% Copyright (c) 2015, Veronika Kebkal <veronika.kebkal@evologics.de>
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

% PC - package counter

-module(fsm_polling_mux).
-behaviour(fsm).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_polling_loop/3, handle_poller_transmit/3, handle_poller_wait_pbm/3, handle_poller_wait_data/3]).
-export([handle_polled_transmit/3, handle_wait_async/3, handle_polled_wait_request/3]).
-export([handle_idle/3, handle_alarm/3, handle_final/3]).

-define(TRANS, [
                {idle,
                 [{stop, idle},
                  {complete_data, idle},
                  {ignore, idle},
                  {next_packet, idle},
                  {nb_send_pbm, idle},
                  {start, polling_loop},
                  {b_send_pbm, polled_wait_request},
                  {polled_data, idle}
                 ]},

                {polling_loop,
                 [{stop, idle},
                  {polled, idle},
                  {start, polling_loop},
                  {poller_request, poller_wait_pbm},
                  {poller_data, poller_transmit}
                ]},

                {poller_transmit,
                 [{next_packet, poller_transmit},
                  {polled_data, poller_transmit},
                  {poller_data, poller_transmit},
                  {complete_data, poller_transmit},
                  {start, polling_loop},
                  {stop, polling_loop},
                  {poll_next, polling_loop},
                  {wait_async, wait_async}
                ]},

                {poller_wait_pbm,
                 [{wait_data_tmo, poller_wait_pbm},
                  {complete_data, poller_wait_pbm},
                  {poll_next, polling_loop},
                  {poller_request, poller_wait_pbm},
                  {polled_data, poller_wait_data},
                  {start, polling_loop},
                  {b_send_pbm, poller_wait_pbm},
                  {stop, polling_loop}
                ]},

                {poller_wait_data,
                 [{complete_data, polling_loop},
                  {wait_data_tmo, polling_loop},
                  {stop, polling_loop},
                  {start, polling_loop},
                  {polled_data, poller_wait_data}
                ]},

                {polled_wait_request,
                 [{ignore, polled_wait_request},
                  {nb_send_pbm, polled_wait_request},
                  {b_send_pbm, polled_wait_request},
                  {polled_request, polled_transmit},
                  {polled_empty, idle},
                  {start, idle}
                ]},

                {polled_transmit,
                 [{ignore, idle},
                  {error, idle},
                  {start, idle},
                  {next_packet, polled_transmit},
                  {wait_async, wait_async}
                ]},

                {wait_async,
                 [{polled_data, wait_async},
                  {next_packet, wait_async},
                  {b_send_pbm, wait_async},
                  {nb_send_pbm, wait_async},
                  {complete_data, wait_async},
                  {wait_data_tmo, wait_async},
                  {ignore, wait_async},
                  {polled_ready, idle},
                  {poller_ready, poller_wait_pbm},
                  {stop, idle},
                  {start, polling_loop}
                ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> init_poll(SM), SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> eps.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, ">> HANDLE EVENT ~p ~p Term:~p~n", [SM#sm.state, SM#sm.event, Term]),
  Sequence = share:get(SM, polling_seq),
  Local_address = share:get(SM, local_address),
  Pid = share:get(SM, pid),
  State = SM#sm.state,
  Polled_address = get_current_polled(SM),
  Wait_sync = share:get(SM, nothing, wait_sync, false),
  Started = share:get(SM, started),

 case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, nl_impl, {send, {nl, error, <<"ANSWER TIMEOUT">>}});
    {timeout, check_state} ->
      fsm:maybe_send_at_command(SM, {at, "?S", ""});
    {timeout, wait_data_tmo} ->
      fsm:run_event(MM, SM#sm{event = wait_data_tmo}, Term);
    {timeout, {delivered, Term}} ->
      fsm:run_event(MM, SM#sm{event = delivered}, Term);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      SM;
    {allowed} ->
      share:put(SM, pid, share:get(SM, {pid, MM}));
    {denied} ->
      share:put(SM, pid, nothing);
    {disconnected, _} ->
      SM;
    {nl, get, buffer} ->
      Buffer = get_buffer(SM),
      fsm:cast(SM, nl_impl, {send, {nl, buffer, Buffer}});
    {nl, reset, state} ->
      fsm:cast(SM, nl_impl, {send, {nl, state, ok}}),
      fsm:maybe_send_at_command(SM, {at, "Z1", ""}),
      fsm:clear_timeouts(SM#sm{state = idle});
    {nl, get, protocol} ->
      Protocol = share:get(SM, nl_protocol),
      fsm:cast(SM, nl_impl, {send, {nl, protocol, Protocol}});
    {nl, get, address} ->
      fsm:cast(SM, nl_impl, {send, {nl, address, Local_address}});
    {nl, set, address, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, address, error}});
    {nl, flush, buffer} ->
      [fsm:maybe_send_at_command(__, {at, "Z3", ""}),
       clear_buffer(__),
       fsm:clear_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, buffer, ok}})
      ] (SM);
    {nl, send, _, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl,send, _, _, _} ->
      process_nl_send(SM, Local_address, Term);
    {nl, set, polling, PSequence} when is_list(PSequence) ->
      Member = lists:member(Local_address, PSequence),
      Start_handler =
      fun (LSM, true) ->
            [fsm:clear_timeouts(__#sm{state = idle}),
             fsm:set_event(__, start)
            ] (LSM);
          (LSM, _) -> LSM
      end,
      Polling_handler =
      fun (LSM) when Member ->
            fsm:cast(LSM, nl_impl, {send, {nl, polling, error}});
          (LSM) ->
            [init_poller(__),
             share:put(__, polling_seq, PSequence),
             Start_handler(__, Started),
             fsm:cast(__, nl_impl, {send, {nl, polling, PSequence}}),
             fsm:run_event(MM, __, {})
            ](LSM)
      end,
      Polling_handler(SM);
    {nl, get, polling} ->
      fsm:cast(SM, nl_impl, {send, {nl, polling, Sequence}});
    {nl, get, polling, status} ->
      Status_handler =
        fun (true) -> share:get(SM, burst_data_on);
            (_) -> idle
        end,
      fsm:cast(SM, nl_impl, {send, {nl, polling, status, Status_handler(Started)}});
    {nl, start, polling, Flag} when (Sequence =/= []) ->
      [share:put(__, started, true),
       fsm:clear_timeouts(__),
       share:put(__, burst_data_on, Flag),
       fsm:cast(__, nl_impl, {send, {nl, polling, ok}}),
       fsm:set_event(__, start),
       fsm:run_event(MM, __, {})
      ] (SM);
    {nl, start, polling, _Flag} ->
      fsm:cast(SM, nl_impl, {send, {nl, polling, error}});
    {nl, stop, polling} ->
      [share:put(__, started, false),
       fsm:clear_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, polling, ok}}),
       fsm:set_event(__, stop),
       fsm:run_event(MM, __, {})
      ] (SM);
    {async, {dropcnt, _Val}} ->
      SM;
    {nl, get, routing} ->
      Routing = {nl, routing, nl_hf:routing_to_list(SM)},
      fsm:cast(SM, nl_impl, {send, Routing});
    {async, {pid, Pid}, Tuple = {recv, _, _, Local_address , _,  _,  _,  _,  _, _}} ->
      [process_data(__, Tuple),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {pid, Pid}, Tuple = {recvpbm, _, Polled_address, Local_address, _, _, _, _, _Data}} ->
      [process_pbm(__, Tuple, mine),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {pid, Pid}, Tuple = {recvpbm, _, _, _, _, _, _, _, _}} ->
      process_pbm(SM, Tuple, overheared);
    {async, {pid, Pid}, {recvim, _, _, Local_address, _, _, _, _,_, _}} when Started == true ->
      [share:put(__, started, false),
       fsm:clear_timeouts(__),
       fsm:set_event(__, stop),
       fsm:run_event(MM, __, {})
      ] (SM);
    {async, {pid, Pid}, Tuple = {recvim, _, _, Local_address, _, _, _, _,_, _}} ->
      [process_request(__, Pid, Tuple, mine),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {pid, _}, Tuple = {recvim, _, _, _, _, _, _, _, _, _}} ->
      process_request(SM, Tuple, overheared);
    {async, _PosTerm = {usbllong, _FCurrT, _FMeasT, _Src, _X, _Y, _Z,
                       _E, _N, _U, _Roll, _Pitch, _Yaw, _P, _Rssi, _I, _Acc}} ->
      SM;
    {async, {delivered, PC, Src}} ->
      [process_asyncs(__, PC),
       pop_delivered(__, tolerant, PC, Src),
       pop_delivered(__, sensitive, PC, Src),
       async_pc(__, PC),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {failed, PC, Src}} ->
      [process_asyncs(__, PC),
       failed_pc(__, tolerant, PC, Src),
       failed_pc(__, sensitive, PC, Src),
       fsm:set_event(__, eps),
       async_pc(__, PC),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {deliveredim, Polled_address}} when State == poller_transmit ->
      [fsm:set_event(__, next_packet),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {failedim, Polled_address}} when State == poller_transmit;
                                             State == poller_wait_pbm ->
      [fsm:set_event(__, poll_next),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {canceledim, Polled_address}} when State == poller_transmit;
                                               State == poller_wait_pbm ->
      [fsm:set_event(__, poll_next),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {deliveredim, Polled_address}} when State == poller_wait_pbm ->
      [fsm:set_event(__, poll_next),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {deliveredim, Polled_address}} ->
      [fsm:set_event(__, eps),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {failedim, Polled_address}} ->
      [fsm:set_event(__, eps),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {canceledim, Polled_address}} ->
      [fsm:set_event(__, eps),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync, "*SENDPBM", "OK"} ->
      {send_pbm, Default} = nl_hf:find_event_params(SM, send_pbm, {send_pbm, eps}),
      [share:clean(__, broadcast),
       nl_hf:clear_spec_event_params(__, {send_pbm, Default}),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {async, _Tuple} ->
      SM;
    {sync,"?S", Status} ->
      [fsm:clear_timeout(__, answer_timeout),
       extract_status(__, Status),
       fsm:run_event(MM, __, Term)
      ](SM);
    {sync,"?PC", PC} ->
      [fsm:clear_timeout(__, answer_timeout),
       process_pc(__, PC),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync,"*SEND",{error, _}} when State == poller_transmit;
                                   State == wait_async ->
      [share:put(__, wait_sync, false),
       fsm:cast(__, nl_impl, {send, {nl, send, error}}),
       run_hook_handler(MM, __, Term, poll_next)
      ](SM);
    {sync,"*SEND",{error, _}} ->
      [share:put(__, wait_sync, false),
       fsm:cast(__, nl_impl, {send, {nl, send, error}}),
       run_hook_handler(MM, __, Term, error)
      ](SM);
    {sync,"*SEND",{busy, _}} ->
      [share:put(__, wait_sync, false),
       fsm:maybe_send_at_command(__, {at, "?S", ""}),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {sync, "*SEND", "OK"} when Wait_sync ->
      [share:put(__, wait_sync, false),
       fsm:maybe_send_at_command(__, {at, "?PC", ""}),
       run_hook_handler(MM, __, Term, wait_async)
      ](SM);
    {sync, "*SEND", "OK"} ->
      [share:put(__, wait_sync, false),
       fsm:maybe_send_at_command(__, {at, "?PC", ""}),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {sync, "*SENDIM", "OK"} ->
      [share:clean(__, broadcast),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {sync, _Req, _Answer} ->
      run_hook_handler(MM, SM, Term, eps);
    {nl, error} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    _ when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {nmea, {evossb, _UTC, TID, _DID, _S, _Err, geod, _FS, Lat, Lon, _Z, _Acc, _Pr, _Vel}} ->
      ?INFO(?ID, "Term = ~p, Ref = ~p~n", [Term, share:get(SM, reference_position)]),
      case share:get(SM, reference_position) of
        nothing -> SM;
        {LatRef, LonRef}  ->
          LatD = round(((Lat - LatRef) * 1.0e6)),
          LonD = round(((Lon - LonRef) * 1.0e6)),
          share:put(SM, gps_diff, {erlang:monotonic_time(seconds), TID, LatD, LonD})
      end;
    {nmea, {evoctl, busbl, Settings}} ->
      apply_settings(SM, Settings);
    {nmea, _} ->
      SM;
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

extract_status(SM, Status) when SM#sm.state == polled_transmit;
                                SM#sm.state == poller_transmit ->
  Parsed = [string:rstr(X, "INITIATION LISTEN") || X <- string:tokens (Status, "\r\n")],
  ?TRACE(?ID, "~p~n", [Status]),
  Listen =
  lists:filtermap(fun(X) ->
                    if X == 0 -> false;
                      true -> {true, true}
                  end end, Parsed),
  Status_handler =
  fun (LSM, [true]) ->
        fsm:set_event(LSM, next_packet);
      (LSM, _) ->
        [fsm:set_event(__, eps),
         fsm:clear_timeout(__, check_state),
         fsm:set_timeout(__, {s, 1}, check_state)
        ](LSM)
  end,
  Status_handler(SM, Listen);
extract_status(SM, _) ->
  fsm:set_event(SM, eps).

run_hook_handler(MM, SM, Term, Event) ->
  [fsm:clear_timeout(__, answer_timeout),
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ](SM).

apply_settings(SM, reference_position, {Lat, Lon}) when Lat /= nothing, Lon /= nothing ->
  env:put(SM, reference_position, {Lat, Lon});
apply_settings(SM, reference_position, _) ->
  SM.
apply_settings(SM, {Lat, Lon, _, _, _, _, _}) ->
  lists:foldl(fun({Key, Value}, SM_acc) ->
                  apply_settings(SM_acc, Key, Value)
              end, SM, [{reference_position, {Lat, Lon}}]).

handle_idle(_MM, #sm{event = start} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = start};
handle_idle(_MM, #sm{event = nb_send_pbm} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  Local_address = share:get(SM, local_address),
  {request, {Pid, Src, Dst, Poll_type}} = nl_hf:find_event_params(SM, request),
  Broadcast = share:get(SM, broadcast),
  PBMData = create_pbm(SM, Src, Poll_type, Broadcast),
  PBM = {at, {pid, Pid}, "*SENDPBM", Src, PBMData},

  PBM_handler =
    fun (LSM) when Local_address == Dst ->
          [fsm:maybe_send_at_command(__, PBM),
           fsm:set_event(__, eps)
          ](LSM);
        (LSM) ->
          fsm:set_event(LSM, eps)
    end,
    PBM_handler(SM);
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_polling_loop(_MM, #sm{event = start} = SM, Term) ->
  ?TRACE(?ID, "handle_polling_loop ~120p~n", [Term]),
  Burst_available = share:get(SM, burst_data_on),
  Broadcast = share:get(SM, broadcast),

  [Type, Tuple] = create_request(SM, Burst_available, Broadcast),
  Type_handler =
  fun (LSM) when Type == burst_exist ->
        [nl_hf:add_event_params(__, {poller_data, Tuple}),
         fsm:set_event(__, poller_data)
        ](LSM);
      (LSM) ->
        [fsm:maybe_send_at_command(__, Tuple),
         fsm:clear_timeout(__, Tuple),
         fsm:set_event(__, poller_request)
        ](LSM)
  end,
  [fsm:clear_timeouts(__),
   Type_handler(__)
  ](SM);
handle_polling_loop(_MM, SM, Term) when SM#sm.event == poll_next;
                                        SM#sm.event == wait_data_tmo;
                                        SM#sm.event == complete_data->
  ?TRACE(?ID, "handle_polling_loop ~120p~n", [Term]),
  [next_address(__),
   fsm:set_event(__, start)
  ](SM);
handle_polling_loop(_MM, #sm{event = stop} = SM, Term) ->
  ?TRACE(?ID, "handle_polling_loop ~120p~n", [Term]),
  SM#sm{event = stop};
handle_polling_loop(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_polling_loop ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_poller_transmit(_MM, #sm{event = next_packet} = SM, Term) ->
  ?TRACE(?ID, "handle_poller_transmit ~120p~n", [Term]),
  {send_params, {Send_params, {_, _, Send_tuple}, Tail}} = nl_hf:find_event_params(SM, send_params),
  {send, {_, Dst}} = Send_params,
  [NTail, Type, LocalPC, Payload] = create_polled_data(SM, Tail, <<"CDB">>),
  PC = share:get(SM, pc),
  PCS = share:get(SM, poller_async_pcs),
  PC_handler =
  fun (LSM, true) -> LSM;
      (LSM, _) -> share:put(LSM, poller_async_pcs, [PC | PCS])
  end,
  ?INFO(?ID, "next packet PC ~p add to ~p~n", [PC, PCS]),
  Poller_handler =
    fun (LSM) when Payload == nothing ->
          [PC_handler(__, lists:member(PC, PCS)),
           fsm:maybe_send_at_command(__, Send_tuple),
           share:put(__, wait_sync, true),
           fsm:set_event(__, eps)
          ](LSM);
        (LSM) ->
          Pid = share:get(SM, pid),
          Next_tuple = {at, {pid, Pid}, "*SEND", Dst, Payload},
          NT = {send_params, {Send_params, {Type, LocalPC, Next_tuple}, NTail}},
          [PC_handler(__, lists:member(PC, PCS)),
           nl_hf:add_event_params(__, NT),
           fsm:set_event(__, eps),
           fsm:maybe_send_at_command(__, Send_tuple)
          ](LSM)
    end,
  Poller_handler(SM);
handle_poller_transmit(_MM, #sm{event = poller_data} = SM, Term) ->
  ?TRACE(?ID, "handle_poller_transmit ~120p~n", [Term]),
  {poller_data, {at, _,"*SENDIM", Dst, ack, _}} = nl_hf:find_event_params(SM, poller_data),
  Local_address = share:get(SM, local_address),
  Send_tuple = {send, {Local_address, Dst}},
  [Tail, Type, LocalPC, Data] = prepare_polled_data(SM, Dst, <<"CDB">>),
  Pid = share:get(SM, pid),
  Tuple = {at, {pid, Pid}, "*SEND", Dst, Data},
  NT = {send_params, {Send_tuple, {Type, LocalPC, Tuple}, Tail}},
  [share:put(__, poller_async_pcs, []),
   nl_hf:add_event_params(__, NT),
   fsm:set_event(__, eps),
   fsm:maybe_send_at_command(__, {at, "?PC", ""})
  ] (SM);
handle_poller_transmit(_MM, #sm{event = complete_data} = SM, Term) ->
  ?TRACE(?ID, "handle_poller_transmit ~120p~n", [Term]),
  SM#sm{event = poller_data};
handle_poller_transmit(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_poller_transmit ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_poller_wait_pbm(_MM, #sm{event = poller_ready} = SM, Term) ->
  ?TRACE(?ID, "handle_poller_wait_pbm ~120p~n", [Term]),
  Burst_available = share:get(SM, burst_data_on),
  Broadcast = share:get(SM, broadcast),
  [_Type, Tuple] = create_request(SM, Burst_available, Broadcast),
  [fsm:maybe_send_at_command(__, Tuple),
   fsm:clear_timeout(__, Tuple),
   fsm:set_event(__, poller_request)
  ](SM);
handle_poller_wait_pbm(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_poller_wait_pbm ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_poller_wait_data(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_poller_wait_data ~120p~n", [Term]),
  SM#sm{event = eps}.


handle_wait_async(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_wait_async ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_polled_transmit(_MM, #sm{event = next_packet} = SM, Term) ->
  {send_params, {Recv_tuple, {_, _, Send_tuple}, Tail}} = nl_hf:find_event_params(SM, send_params),
  {request, {Pid, Src, _, _}} = Recv_tuple,
  [NTail, Type, LocalPC, Payload] = create_polled_data(SM, Tail, <<"V">>),
  ?INFO(?ID, "create_polled_data ~p ~p ~p ~p~n", [NTail, Type, LocalPC, Payload]),
  PC = share:get(SM, pc),
  PCS = share:get(SM, polled_async_pcs),
  PC_handler =
  fun (LSM, true) -> LSM;
      (LSM, _) -> share:put(LSM, polled_async_pcs, [PC | PCS])
  end,
  ?INFO(?ID, "next packet PC ~p add to ~p~n", [PC, PCS]),
  Polled_handler =
    fun (LSM) when Payload == nothing ->
          [PC_handler(__, lists:member(PC, PCS)),
           nl_hf:clear_spec_event_params(__, Term),
           fsm:maybe_send_at_command(__, Send_tuple),
           share:put(__, wait_sync, true),
           fsm:set_event(__, eps)
          ](LSM);
        (LSM) ->
          Next_tuple = {at, {pid, Pid}, "*SEND", Src, Payload},
          NT = {send_params, {Recv_tuple, {Type, LocalPC, Next_tuple}, NTail}},
          [PC_handler(__, lists:member(PC, PCS)),
           nl_hf:add_event_params(__, NT),
           fsm:set_event(__, eps),
           fsm:maybe_send_at_command(__, Send_tuple)
          ](LSM)
    end,
  Polled_handler(SM);
handle_polled_transmit(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_polled_transmit ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_polled_wait_request(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_polled_wait_request ~120p~n", [Term]),
  Local_address = share:get(SM, local_address),
  Recv_tuple = {request, {Pid, Src, Dst, Poll_type}} = nl_hf:find_event_params(SM, request),

  Broadcast = share:get(SM, broadcast),
  PBMData = create_pbm(SM, Src, Poll_type, Broadcast),
  PBM = {at, {pid, Pid}, "*SENDPBM", Src, PBMData},
  Len = length_data(SM, Src),

  [Tail, Type, PC, Data] = prepare_polled_data(SM, Src, <<"V">>),

  Length_handler =
  fun (LSM) when Len == 0 ->
        fsm:set_event(LSM, polled_empty);
      (LSM) ->
        fsm:set_event(LSM, eps)
  end,

  Polled_handler =
  fun (LSM) when Local_address == Dst, SM#sm.event == b_send_pbm ->
        [fsm:maybe_send_at_command(__, PBM),
         Length_handler(__)
        ](LSM);
      (LSM) when Data == nothing ->
       fsm:set_event(LSM, polled_empty);
      (LSM) when Local_address == Dst ->
       Send_tuple = {at, {pid, Pid}, "*SEND", Src, Data},
       Tuple = {send_params, {Recv_tuple, {Type, PC, Send_tuple}, Tail}},
       [share:put(__, polled_async_pcs, []),
        fsm:maybe_send_at_command(__, {at, "?PC", ""}),
        nl_hf:add_event_params(__, Tuple),
        fsm:set_event(__, polled_request)
       ](LSM);
      (LSM) ->
        fsm:set_event(LSM, eps)
  end,
  Polled_handler(SM).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions------------------------
init_poll(SM)->
  share:put(SM, polling_seq, []),
  share:put(SM, buffer, []),
  share:put(SM, local_pc, 1),
  share:put(SM, polling_pc, 1),
  share:put(SM, recv_packages, []),
  share:put(SM, burst_data_on, nb),
  init_poller(SM).

init_poller(SM) ->
  share:put(SM, current_polling_i, 1).

init_pc(SM, PC) ->
  ?INFO(?ID, "init_pc ~p~n", [PC]),
  share:put(SM, pc, PC).

async_pc(#sm{state = wait_async} = SM, _PC) ->
  {send_params, {Tuple, _, _}} = nl_hf:find_event_params(SM, send_params),

  Polled_PCS = share:get(SM, nothing, polled_async_pcs, []),
  Poller_PCS = share:get(SM, nothing, poller_async_pcs, []),

  ?INFO(?ID, ">>> async_pc ~p ~p~n", [Polled_PCS, Poller_PCS]),
  Transmission_handler =
  fun (LSM, {request, _}) when Polled_PCS == [] ->
        % cancel formed pbm message
        [fsm:maybe_send_at_command(__, {at, "Z3", ""}),
         fsm:set_event(__, polled_ready)
        ](LSM);
      (LSM, {send, _}) when Poller_PCS == [] ->
        fsm:set_event(LSM, poller_ready);
      (LSM, _) -> LSM
  end,
  Transmission_handler(SM, Tuple);
async_pc(SM, _) -> SM.

increase_local_pc(SM, Name) ->
  PC = share:get(SM, Name),
  if PC > 127 ->
    share:put(SM, Name, 1);
  true ->
    share:put(SM, Name, PC + 1)
  end.

get_current_polled(SM) ->
  Sequence = share:get(SM, polling_seq),
  ?TRACE(?ID, "Sequence = ~p Current Poll Ind ~p~n", [Sequence, share:get(SM, current_polling_i)]),
  case Sequence of
   _  when Sequence == nothing; Sequence == []->
       nothing;
  _ -> Ind = share:get(SM, current_polling_i),
       lists:nth(Ind, Sequence)
  end.

process_asyncs(SM, PC) ->
  Polled_PCS = share:get(SM, nothing, polled_async_pcs, []),
  Poller_PCS = share:get(SM, nothing, poller_async_pcs, []),
  ?INFO(?ID, ">>> delete PC ~p from ~p ~p~n", [PC, Polled_PCS, Poller_PCS]),
  [share:put(__, poller_async_pcs, lists:delete(PC, Poller_PCS)),
   share:put(__, polled_async_pcs, lists:delete(PC, Polled_PCS))
  ](SM).
%process_pc(#sm{state = wait_async} = SM, _) ->
%  SM;
process_pc(SM, LPC) ->
  PC = list_to_integer(LPC),
  Send_params = nl_hf:find_event_params(SM, send_params),
  case Send_params of
    {send_params, {_, Tuple, _}} ->
      [init_pc(__, PC),
       change_status(__, PC, Tuple),
       fsm:set_event(__, next_packet)
      ](SM);
    _ ->
      init_pc(SM, PC)
  end.

process_data(SM, Tuple) ->
  {recv, _, Src, Dst , _,  _,  _,  _,  _, Data} = Tuple,
  [Type, Poll_data] = extract_poll_data(SM, Data),
  Time = share:get(SM, wait_data_tmo),

  PBM_handler =
  fun (LSM, {request, {_, _, _, b}}) ->
        fsm:set_event(LSM, b_send_pbm);
      (LSM, {request, {_, _, _, nb}}) ->
        fsm:set_event(LSM, nb_send_pbm);
      (LSM, _) ->
        fsm:set_event(LSM, ignore)
  end,

  Length_handler =
  fun (LSM, Rest) when Rest =< 0 ->
        [fsm:clear_timeout(__, wait_data_tmo),
         fsm:set_event(__, complete_data)
        ](LSM);
      (LSM, _Rest) ->
        [fsm:set_event(__, polled_data),
         fsm:clear_timeout(__, wait_data_tmo),
         fsm:set_timeout(__, {s, Time}, wait_data_tmo)
        ](LSM)
  end,

  Data_handler =
  fun (LSM, ignore) -> LSM;
      (LSM, _) when Type == <<"CDB">> ->
        [fsm:cast(__, nl_impl, {send, {nl, recv, Src, Dst, Poll_data}}),
         PBM_handler(__, nl_hf:find_event_params(SM, request))
        ](LSM);
      (LSM, _) ->
        Name = share_name(Src, wait_data_len),
        {Name, {Src, Whole_len}} = nl_hf:find_event_params(SM, Name, {Name, {Src, 0}}),
        Len = byte_size(Poll_data),
        Waiting_rest = Whole_len - Len,
        ?TRACE(?ID, "<<<<  Received data ~p ~p~n", [Src, Poll_data]),
        ?TRACE(?ID, "<<<<  Len ~p Whole_len ~p Waiting ~p~n", [Len, Whole_len, Waiting_rest]),

        [nl_hf:add_event_params(__, {Name, {Src, Waiting_rest}}),
         Length_handler(__, Waiting_rest),
         fsm:cast(__, nl_impl, {send, {nl, recv, Src, Dst, Poll_data}})
        ](LSM)
  end,
  Data_handler(SM, Poll_data).

process_pbm(SM, _, mine) when SM#sm.state == idle ->
  SM;
process_pbm(SM, Tuple, mine) ->
  {recvpbm, _, Src, Dst, _, _, _, _, Payload} = Tuple,
  [Type, Len, Broadcast] = extract_pbm(SM, Payload),
  Name = share_name(Src, wait_data_len),
  Time = share:get(SM, wait_data_tmo),

  ?TRACE(?ID, "process_pbm mine ~120p, Type=~p, Len=~p, Broadcast=~p~n", [Tuple, Type, Len, Broadcast]),
  Broadcast_handler =
  fun (LSM, _) when Broadcast == <<>> -> LSM;
      (LSM, <<"B">>) ->
        fsm:cast(LSM, nl_impl, {send, {nl, recv, Src, ?ADDRESS_MAX, Broadcast}});
      (LSM, _) ->
        fsm:cast(LSM, nl_impl, {send, {nl, recv, Src, Dst, Broadcast}})
  end,

  Length_handler =
  fun (LSM) when Len == 0 ->
        fsm:set_event(LSM, eps);
      (LSM) ->
        [fsm:set_timeout(__, {s, Time}, wait_data_tmo),
         nl_hf:add_event_params(__, {Name, {Src, Len}}),
         fsm:set_event(__, polled_data)
        ](LSM)
  end,
  [Broadcast_handler(__, Type),
   Length_handler(__)
  ](SM);
process_pbm(SM, Tuple, overheared) ->
  ?TRACE(?ID, "process_pbm overheared ~120p~n", [Tuple]),
  {recvpbm, _, Src, _, _, _, _, _, Payload} = Tuple,
  try
    [Type, Len, Broadcast] = extract_pbm(SM, Payload),
    ?TRACE(?ID, "process_pbm overheared Type=~p, Len=~p, Broadcast=~p~n", [Type, Len, Broadcast]),
    Pmb_handler =
    fun (LSM, <<"B">>) when Broadcast =/= nothing ->
          fsm:cast(LSM, nl_impl, {send, {nl, recv, Src, ?ADDRESS_MAX, Broadcast}});
        (LSM, _) -> LSM
    end,
    Pmb_handler(SM, Type)
  catch error:_ -> SM
  end.

process_nl_send(SM, Address, {nl, send, _Type, Address, _Payload}) ->
  fsm:cast(SM, nl_impl, {send, {nl, send, error}});
process_nl_send(SM, _, {nl, send, tolerant, ?ADDRESS_MAX, _Payload}) ->
  fsm:cast(SM, nl_impl, {send, {nl, send, error}});
process_nl_send(SM, _, {nl, send, sensitive, ?ADDRESS_MAX, _Payload}) ->
  fsm:cast(SM, nl_impl, {send, {nl, send, error}});
process_nl_send(SM, _, T = {nl, send, Type, _Dst, Payload}) ->
  Member = lists:member(Type, [sensitive, tolerant, alarm, broadcast]),
  Len = byte_size(Payload),
  Message_handler =
  fun (LSM, _) when not Member ->
        fsm:cast(LSM, nl_impl, {send, {nl, send, error}});
      (LSM, broadcast) when Len > 50 ->
        fsm:cast(LSM, nl_impl, {send, {nl, send, error}});
      (LSM, _) ->
        [push_poller_queue(__, T),
         fsm:cast(__, nl_impl, {send, {nl, send, 0}})
        ](LSM)
  end,
  Message_handler(SM, Type).

process_request(SM, Pid, Tuple, mine) ->
  {recvim, _, Src, Dst, _, _, _, _,_, Payload} = Tuple,
  extract_position(SM, Payload),
  [Type, Burst, Len, Poll_data, _, Poll_type, Process] = extract_request(SM, Payload),

  Length_handler =
  fun (LSM, 0) -> LSM;
      (LSM, _) when Type == <<"B">> ->
        fsm:cast(LSM, nl_impl, {send, {nl, recv, Src, ?ADDRESS_MAX, Poll_data}});
      (LSM, _) ->
        fsm:cast(LSM, nl_impl, {send, {nl, recv, Src, Dst, Poll_data}})
  end,

  ?TRACE(?ID, "process_request mine ~120p Process ~p~n", [Tuple, Process]),
  Request_handler =
  fun (LSM) when Burst == <<"B">> ->
        [nl_hf:add_event_params(__, {request, {Pid, Src, Dst, Poll_type}}),
         nl_hf:add_event_params(__, {send_pbm, Process}),
         fsm:set_event(__, ignore)
        ](LSM);
      (LSM) when Process == ignore ->
       fsm:set_event(LSM, ignore);
      (LSM) when Process == b_send_pbm, SM#sm.state == polled_wait_request ->
        fsm:set_event(LSM, ignore);
      (LSM) ->
        [Length_handler(__, Len),
         nl_hf:add_event_params(__, {request, {Pid, Src, Dst, Poll_type}}),
         nl_hf:add_event_params(__, {send_pbm, Process}),
         fsm:set_event(__, Process)
        ](LSM)
  end,
  Request_handler(SM).
process_request(SM, Tuple, overheared) ->
  ?TRACE(?ID, "process_request overheared ~120p~n", [Tuple]),
  {recvim, _, Src, _, _, _, _, _, _, Payload} = Tuple,
  try
    [Type, _, Len, Poll_data, _, _, _] = extract_request(SM, Payload),
    Recvim_handler =
    fun (LSM, <<"B">>) when Len > 0, Poll_data =/= nothing ->
          fsm:cast(LSM, nl_impl, {send, {nl, recv, Src, ?ADDRESS_MAX, Poll_data}});
        (LSM, _) -> LSM
    end,
    Recvim_handler(SM, Type)
  catch error:_ -> SM
  end.

push_poller_queue(SM, {nl, send, broadcast, Dst, Payload}) ->
  Time = erlang:monotonic_time(micro_seconds),
  Len = byte_size(Payload),
  Tuple = {Time, broadcast, not_sent, Len, Payload},
  ?TRACE(?ID, "push_poller_queue ~p~n", [Tuple]),
  [nl_hf:list_push(__, buffer, Dst, 10),
   share:put(__, broadcast, Tuple)
  ](SM);
push_poller_queue(SM, {nl, send, Type, Dst, Payload}) ->
  LocalPC = share:get(SM, local_pc),
  Time = erlang:monotonic_time(micro_seconds),
  Len = byte_size(Payload),
  Tuple = {unknown, LocalPC, not_delivered, Time, Type, Len, Payload},

  Qname = share_name(Dst, Type),
  Q = share:get(SM, nothing, Qname, queue:new()),

  ?TRACE(?ID, "Add to poller queue ~p~n", [Tuple]),
  Type_handler =
  fun (LSM, tolerant) ->
        share:put(LSM, Qname, queue:in(Tuple, Q));
      (LSM, sensitive) ->
        Max = share:get(LSM, max_sensitive_queue),
        nl_hf:queue_push(LSM, Qname, Tuple, Max)
  end,
  [increase_local_pc(__, local_pc),
   nl_hf:list_push(__, buffer, Dst, 10),
   Type_handler(__, Type)
  ](SM).

share_name(Dst, Name) ->
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),
  list_to_atom(atom_to_list(Name) ++ atom_to_list(DstA)).

create_polled_data(_SM, L, Header) ->
  case L of
    nothing ->
      [nothing, nothing, nothing, nothing];
    [] ->
      [nothing, nothing, nothing, nothing];
    _ ->
      [{Type, LocalPC, _, Data} | Tail] = L,
      [Tail, Type, LocalPC, <<Header/binary, Data/binary>>]
  end.
prepare_polled_data(SM, Dst, Header) ->
  Data = prepare_data(SM, Dst),
  Len = length_data(SM, Dst),
  case Len of
    0 ->
      [nothing, nothing, nothing, nothing];
    _ ->
    [{Type, LocalPC, _, Payload} | Tail] = Data,
    [Tail, Type, LocalPC, <<Header/binary, Payload/binary>>]
  end.

extract_position(SM, Msg) ->
  try
    CPollingFlagBurst = nl_hf:count_flag_bits(1),
    CBitsPosLen = nl_hf:count_flag_bits(63),
    CPollingCounterLen = nl_hf:count_flag_bits(127),
    <<"C", _:8/bitstring, _:8/bitstring, _:CPollingFlagBurst, _:CPollingCounterLen, PLen:CBitsPosLen, RPayload/bitstring>> = Msg,
    <<Pos:PLen/binary, _/bitstring>> = RPayload,
    fsm:cast(SM, nmea, {send, decode_position(share:get(SM, reference_position), Pos)})
  catch _:_ ->
      nothing
  end.

extract_poll_data(_SM, Payload) ->
  try
    {match, [Type, Data]} = re:run(Payload,"^(CDB|V)(.*)", [dotall, {capture, [1, 2], binary}]),
    [Type, Data]
  catch error: _Reason -> ignore
  end.

extract_pbm(SM, Payload) ->
  try
    Max_len = share:get(SM, max_burst_len),
    C_Max_len = nl_hf:count_flag_bits(Max_len),
    <<"VPbm", Type:8/bitstring, Len:C_Max_len, Rest/bitstring>> = Payload,
    ?TRACE(?ID, ">>>> extract_pbm Type=~p Len=~p C_Max_len=~p Rest=~p~n", [Type, Len, C_Max_len, Rest]),
    Data_bin = (bit_size(Payload) rem 8) =/= 0,
    Broadcast =
    if Data_bin =:= false ->
      Add = bit_size(Rest) rem 8,
      <<_:Add, Data/binary>> = Rest,
      Data;
    true -> Rest
    end,
    [Type, Len, Broadcast]
  catch error: _Reason -> [0, 0, <<>>]
  end.

create_request(SM, FlagBurst, Broadcast) ->
  Polled_address = get_current_polled(SM),
  PC = share:get(SM, polling_pc),
  Data_pos = encode_position(share:get(SM, gps_diff)),
  Len_pos = byte_size(Data_pos),

  Flag_burst =
    case FlagBurst of
      nb -> 1;
      b -> 0
    end,

  LenData = length_data(SM, Polled_address),
  CFlagBurst = nl_hf:count_flag_bits(1),
  CCounterLen = nl_hf:count_flag_bits(127),
  CPosLen = nl_hf:count_flag_bits(63),

  BFlagBurst = <<Flag_burst:CFlagBurst>>,
  BPC = <<PC:CCounterLen>>,
  BLenPos = <<Len_pos:CPosLen>>,

  [Result, Header] =
  case LenData of
    0 ->
      [no_burst, <<"N">>];
    _ when FlagBurst == nb; Broadcast =/= nothing ->
      [no_burst, <<"N">>];
    _ ->
      [burst_exist, <<"B">>]
  end,

  increase_local_pc(SM, polling_pc),
  Pid = share:get(SM, pid),
  ?WARNING(?ID, "CDT: Pid = ~p~n", [Pid]),

  [Broadcast_flag, Add_payload] =
  case Broadcast of
    {_Time, broadcast, _Status, _TransmitLen, Broadcast_payload} ->
      [<<"B">>, Broadcast_payload];
    _ ->
      [<<"N">>, <<"">>]
  end,

  TmpData = <<"C", Broadcast_flag:8/bitstring, Header:8/bitstring, BFlagBurst/bitstring, BPC/bitstring,
              BLenPos/bitstring, Data_pos/binary, Add_payload/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"C", Broadcast_flag:8/bitstring, Header:8/bitstring, BFlagBurst/bitstring, BPC/bitstring,
      BLenPos/bitstring, Data_pos/binary, 0:Add, Add_payload/binary>>;
  true ->
    TmpData
  end,
  [Result, {at, {pid, Pid},"*SENDIM", Polled_address, ack, Data}].

extract_request(SM, Msg) ->
  CFlag = nl_hf:count_flag_bits(1),
  CPosLen = nl_hf:count_flag_bits(63),
  CCounter = nl_hf:count_flag_bits(127),

  <<"C", Type:8/bitstring, Burst_exist:8/bitstring, Flag:CFlag, PC:CCounter,
    PLen:CPosLen, RPayload/bitstring>> = Msg,

  <<Pos:PLen/binary, Rest/bitstring>> = RPayload,
  case decode_position(share:get(SM, reference_position), Pos) of
    Position when is_tuple(Position) ->
      fsm:cast(SM, nmea, {send, Position});
    _ ->
      nothing
  end,
  Data_bin = (bit_size(Msg) rem 8) =/= 0,
  Payload =
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    Data;
  true ->
    Rest
  end,

  PC_exist = lists:member(PC, share:get(SM, recv_packages)),
  nl_hf:list_push(SM, recv_packages, PC, 6),

  ?TRACE(?ID, ">>>> extract_request Flag=~p = Type=~p BurstExist=~p Len=~p Payload=~p Pos=~p~n",
    [Flag, Type, Burst_exist, byte_size(Payload), Payload, Pos]),

  case Flag of
    _ when PC_exist == true ->
         [Type, Burst_exist, byte_size(Payload), Payload, Pos, b, ignore];
    1 -> [Type, Burst_exist, byte_size(Payload), Payload, Pos, nb, nb_send_pbm];
    0 -> [Type, Burst_exist, byte_size(Payload), Payload, Pos, b, b_send_pbm]
  end.

create_pbm(SM, Dst, FlagBurst, Broadcast) ->
  Max = share:get(SM, max_burst_len),
  CLenBurst = nl_hf:count_flag_bits(Max),

  Len =
  case FlagBurst of
    nb -> 0;
    b -> length_data(SM, Dst)
  end,

  [Broadcast_flag, Add_payload] =
  case Broadcast of
    {Time, broadcast, _Status, TransmitLen, Broadcast_payload} ->
      Tuple = {Time, broadcast, sent, TransmitLen, Broadcast_payload},
      share:put(SM, broadcast, Tuple),
      [<<"B">>, Broadcast_payload];
    _ ->
      [<<"N">>, <<"">>]
  end,

  BLenBurst = <<Len:CLenBurst>>,

  ?TRACE(?ID, ">>>> create_pbm Len ~p Maxlen ~p BLenBurst~p ~n", [Len, Max, BLenBurst]),
  TmpData = <<"VPbm", Broadcast_flag:8/bitstring, BLenBurst/bitstring, Add_payload/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<"VPbm",  Broadcast_flag:8/bitstring, BLenBurst/bitstring, 0:Add, Add_payload/binary>>;
  true ->
    TmpData
  end.

encode_position(nothing) ->
  <<>>;
encode_position({MTime, TID, LatD, LonD}) ->
  DT =
    case erlang:monotonic_time(seconds) - MTime of
      T when T < ?ADDRESS_MAX -> T;
      _ -> ?ADDRESS_MAX
    end,
  <<TID:8, DT:8, LatD:24/signed, LonD:24/signed>>.

decode_position({LatRef,LonRef}, <<TID:8, _DT:8, LatD:24/signed, LonD:24/signed>>) ->
  Lat = LatD / 1.0e6 + LatRef,
  Lon = LonD / 1.0e6 + LonRef,
  MTime = erlang:system_time(millisecond)/1000,
  {nmea, {evossb, MTime, TID, nothing, ok, nothing, geod, reconstructed, Lat, Lon, nothing, nothing, nothing, nothing}};
decode_position(_, <<>>) ->
  nothing.

get_buffer(SM) ->
  Sequence = share:get(SM, buffer),
  F = fun(X) ->
    QSensitive = share_name(X, sensitive),
    QTolerant = share_name(X, tolerant),
    Sensitive = get_list(share:get(SM, QSensitive), X),
    Tolerant = get_list(share:get(SM, QTolerant), X),
    lists:append([Sensitive, Tolerant])
  end,
  lists:flatten([ F(X) || X <- Sequence]).

get_list(nothing, _) ->
 [];
get_list(Q, Dst) ->
 L = queue:to_list(Q),
 F = fun(X) ->
    {_, _, XStatus, _, XMsgType, _, Payload} = X,
    %<<Hash:16, _/binary>> = crypto:hash(md5,Payload),
    {Payload, XStatus, Dst, XMsgType}
  end,
  [ F(X) || X <- L].

clear_buffer(SM) ->
  Sequence = share:get(SM, buffer),
  F = fun(X) ->
    QSensitive = share_name(X, sensitive),
    QTolerant = share_name(X, tolerant),
    share:put(SM, QSensitive, queue:new()),
    share:put(SM, QTolerant, queue:new()),
    share:clean(SM, broadcast)
  end,
  [ F(X) || X <- Sequence],
  SM.

pop_delivered(SM, Type, PC, Dst) ->
  ?TRACE(?ID, "pop_delivered Type=~p, PC=~p, Dst=~p~n", [Type, PC, Dst]),
  Qname = share_name(Dst, Type),
  Q = share:get(SM, nothing, Qname, queue:new()),
  QL = queue:to_list(Q),
  ?TRACE(?ID, "Waiting for delivery ~p~n", [QL]),
  NL =
  lists:filtermap(fun(X) ->
  case X of
    {PC, _, _, _, _, _, _} -> false;
    _ -> {true, X}
  end end, QL),
  NQ = queue:from_list(NL),
  share:put(SM, Qname, NQ).

failed_pc(SM, Type, PC, Dst) ->
  Qname = share_name(Dst, Type),
  Max = share:get(SM, max_sensitive_queue),
  QL = queue:to_list(share:get(SM, nothing, Qname, queue:new())),
  NQ =
  lists:foldr(
  fun(X, Q) ->
    Queue_handler =
    fun (tolerant, Item) ->
          ?INFO(?ID, "failed_pc ~p~n", [Item]),
          queue:in(Item, Q);
        (sensitive, Item) ->
          ?INFO(?ID, "failed_pc ~p~n", [Item]),
          nl_hf:queue_push(Q, Item, Max)
    end,
    {_, XPC, XStatus, XTime, XMsgType, XTransmitLen, _} = X,
    case X of
      {PC, _, _, _, Type, _, Payload} ->
        Item = {unknown, XPC, XStatus, XTime, XMsgType, XTransmitLen, Payload},
        Queue_handler(Type, Item);
      _ -> Queue_handler(Type, X)
    end
  end, queue:new(), QL),
  share:put(SM, Qname, NQ).

change_status(SM, PC, {Type, LocalPC, AT}) ->
  {at, {pid, _}, "*SEND", Dst, Data} = AT,
  Max = share:get(SM, max_sensitive_queue),
  Qname = share_name(Dst, Type),
  QL = queue:to_list(share:get(SM, nothing, Qname, queue:new())),
  [_, Payload] = extract_poll_data(SM, Data),
  NQ =
  lists:foldr(
  fun(X, Q) ->
    Queue_handler =
    fun (tolerant, Item) ->
          ?INFO(?ID, "add tolerant ~p~n", [Item]),
          queue:in(Item, Q);
        (sensitive, Item) ->
          ?INFO(?ID, "add sensitive ~p~n", [Item]),
          nl_hf:queue_push(Q, Item, Max)
    end,
    {_, XPC, XStatus, XTime, XMsgType, XTransmitLen, _} = X,
    case X of
      {unknown, LocalPC, _, _, Type, _, Payload} ->
        Item = {PC, XPC, XStatus, XTime, XMsgType, XTransmitLen, Payload},
        Queue_handler(Type, Item);
      _ -> Queue_handler(Type, X)
    end
  end, queue:new(), QL),
  share:put(SM, Qname, NQ).

length_data(SM, Dst) ->
  Send_data = prepare_data(SM, Dst),
  F = fun(X) -> {_Type, _LocalPC, _Dst, Data} = X, Data end,
  Payload = list_to_binary(lists:join(<<"">>, [ F(X)  || X <- Send_data])),
  ?TRACE(?ID, ">>>> length_data Len ~p~n", [byte_size(Payload)]),
  SumLen = byte_size(Payload),
  Max = share:get(SM, max_burst_len),
  if(SumLen > Max) -> Max; true -> SumLen end.

next_address(SM) ->
  Sequence = share:get(SM, polling_seq),
  Polling_i = share:get(SM, current_polling_i),
  Ind =
  if Polling_i >= length(Sequence) -> 1;
  true -> Polling_i + 1
  end,
  share:put(SM, current_polling_i, Ind).

prepare_data(SM, Dst) ->
  QSensitive = share:get(SM, share_name(Dst, sensitive)),
  QTolerant = share:get(SM, share_name(Dst, tolerant)),

  Max_sensitive = share:get(SM, max_pt_sensitive),
  Max_tolerant = share:get(SM, max_pt_tolerant),
  Data_handler =
  fun
    (nothing, nothing) -> [];
    (Q, nothing) ->
      QPart = partly_list(Max_tolerant, Q),
      queue:to_list(QPart);
    (nothing, Q) ->
      QPart = partly_list(Max_sensitive, Q),
      queue:to_list(QPart);
    (Q1, Q2) ->
      QPart1 = partly_list(Max_tolerant, Q1),
      QPart2 = partly_list(Max_sensitive, Q2),
      NQ = queue:join(QPart2, QPart1),
      queue:to_list(NQ)
  end,
  NL = Data_handler(QTolerant, QSensitive),
  lists:foldr(
  fun(X, A) ->
    {_PC, LocalPC, _Status, _Time, Type, _Len, Data} = X,
    [{Type, LocalPC, Dst, Data} | A]
  end, [], NL).

partly_list(Max, Q) ->
  case Max >= queue:len(Q) of
    true -> Q;
    false ->
      {Q1, _Q2} = queue:split(Max, Q),
      Q1
  end.
