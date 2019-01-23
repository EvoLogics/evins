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

-module(fsm_nl_burst).
-behaviour(fsm).
-compile({parse_transform, pipeline}).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).
-export([handle_recv/3, handle_sensing/3, handle_transmit/3, handle_busy/3]).
-export([handle_idle/3, handle_alarm/3, handle_final/3]).

-define(TRANS, [
                {idle,
                 [{try_transmit, sensing},
                  {routing_updated, sensing},
                  {recv_data, recv},
                  {reset, idle}
                 ]},

                {recv,
                 [{recv_data, recv},
                  {pick, sensing},
                  {busy_online, recv},
                  {reset, idle}
                 ]},

                {sensing,
                 [{routing_updated, sensing},
                  {try_transmit, sensing},
                  {initiation_listen, transmit},
                  {empty, idle},
                  {no_routing, idle},
                  {busy_backoff, busy},
                  {busy_online, busy},
                  {recv_data, recv},
                  {reset, idle}
                 ]},

                {transmit,
                 [{pick, sensing},
                  {next_packet, transmit},
                  {recv_data, recv},
                  {busy_online, busy},
                  {reset, idle}
                 ]},

                {busy,
                 [{initiation_listen, sensing},
                  {recv_data, recv},
                  {reset, idle}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  [init_nl_burst(__),
   env:put(__, channel_state, initiation_listen),
   env:put(__, channel_state_msg, {status, 'INITIATION', 'LISTEN'}),
   env:put(__, service_msg, [])
  ](SM).
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT ~p ~p Term:~p~n", [SM#sm.state, SM#sm.event, Term]),
  Local_address = share:get(SM, local_address),
  Pid = share:get(SM, pid),
  State = SM#sm.state,
  Protocol_Name = share:get(SM, nl_protocol),

  case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, nl_impl, {send, {nl, error, <<"ANSWER TIMEOUT">>}});
    {timeout, check_state} ->
      [fsm:maybe_send_at_command(__, {at, "?S", ""}),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, {wait_data_tmo, Src}} when State == recv ->
      [fsm:set_event(__, pick),
       send_acks(__, Src),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, pc_timeout} when State == busy ->
      SM;
    {timeout, pc_timeout} ->
      fsm:maybe_send_at_command(SM, {at, "?PC", ""});
    {timeout, {wait_nl_async, Dst, PC}} ->
      fsm:cast(SM, nl_impl, {send, {nl, failed, PC, Local_address, Dst}});
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
    {nl, set, debug, ON} ->
      share:put(SM, debug, ON),
      fsm:cast(SM, nl_impl, {send, {nl, debug, ok}});
    {nl, path, failed, Dst} ->
      ?INFO(?ID, "Path to ~p failed to find~n", [Dst]),
      SM;
    {nl, set, address, Address} ->
      nl_hf:process_set_command(SM, {address, Address});
    {nl, set, neighbours, Neighbours} ->
      nl_hf:process_set_command(SM, {neighbours, Neighbours});
    {nl, set, routing, Routing} ->
      [nl_hf:process_set_command(__, {routing, Routing}),
       set_routing(__, Routing),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, set, protocol, Protocol} ->
      nl_hf:process_set_command(SM, {protocol, Protocol});
    {nl, set, Command} ->
      nl_hf:process_set_command(SM, Command);
    {nl, get, buffer} ->
      Buffer = get_buffer(SM),
      fsm:cast(SM, nl_impl, {send, {nl, buffer, Buffer}});
    {nl, flush, buffer} ->
      [fsm:maybe_send_at_command(__, {at, "Z3", ""}),
       clear_buffer(__),
       fsm:clear_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, buffer, ok}})
      ] (SM);
    {nl, get, protocol} ->
      fsm:cast(SM, nl_impl, {send, {nl, protocol, Protocol_Name}});
    {nl, get, help} ->
      fsm:cast(SM, nl_impl, {send, {nl, help, ?HELP}});
    {nl, get, version} ->
      %% FIXME: define rules to generate version
      fsm:cast(SM, nl_impl, {send, {nl, version, 0, 1, "emb"}});
    {nl, get, time, monotonic} ->
      Current_time = erlang:monotonic_time(milli_seconds) - share:get(SM, nl_start_time),
      fsm:cast(SM, nl_impl, {send, {nl, time, monotonic, Current_time}});
    {nl, get, statistics, Some_statistics} ->
      nl_hf:process_get_command(SM, {statistics, Some_statistics});
    {nl, get, protocolinfo, Some_protocol} ->
      nl_hf:process_get_command(SM, {protocolinfo, Some_protocol});
    {nl, get, service} ->
      Status = env:get(SM, channel_state_msg),
      SRV = env:get(SM, service_msg),
      fsm:cast(SM, nl_impl, {send, {nl, service, Status, SRV}});
    {nl, get, Command} ->
      nl_hf:process_get_command(SM, Command);
    {nl, delete, neighbour, Address} ->
      nl_hf:process_get_command(SM, {delete, neighbour, Address});
    {nl, clear, statistics, data} ->
      share:put(SM, statistics_queue, queue:new()),
      share:put(SM, statistics_neighbours, queue:new()),
      fsm:cast(SM, nl_impl, {send, {nl, statistics, data, empty}});
    {nl, send, error} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, _, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, tolerant, Local_address, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, tolerant, _, _} ->
      Event_handler =
      fun (LSM) when LSM#sm.state == idle ->
            fsm:set_event(LSM, try_transmit);
          (LSM) ->
            fsm:set_event(LSM, eps)
      end,
      [process_nl_send(__, Local_address, Term),
       Event_handler(__),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, send, _, _, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {nl, reset, state} ->
      [nl_hf:clear_spec_timeout(__, pc_timeout),
       nl_hf:clear_spec_timeout(__, check_state),
       nl_hf:clear_spec_timeout(__, wait_data_tmo),
       fsm:cast(__, nl_impl, {send, {nl, state, ok}}),
       fsm:set_event(__, reset),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, ack, Dst, Local_address, Data} ->
      case burst_nl_hf:try_extract_ack(SM, Data) of
        [] -> SM;
        [_Count, L] ->
          recv_ack(SM, Dst, L)
      end;
    {async, Recv_Tuple = {recvsrv,Src,_,_,_,_,_,_}} when Src =/=0 ->
      env:put(SM, service_msg, Recv_Tuple);
    {sync,"?S", Status} ->
     [fsm:clear_timeout(__, check_state),
      fsm:clear_timeout(__, answer_timeout),
      extract_status(__, Status),
      fsm:run_event(MM, __, Term)
     ](SM);
    {sync,"?PC", PC} ->
      [fsm:clear_timeout(__, pc_timeout),
       fsm:clear_timeout(__, answer_timeout),
       process_pc(__, PC),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync,"*SEND",{error, _}} ->
      [share:put(__, wait_sync, false),
       fsm:cast(__, nl_impl, {send, {nl, send, error}}),
       run_hook_handler(MM, __, Term, error)
      ](SM);
    {sync,"*SEND", {busy, _}} ->
      [fsm:clear_timeout(__, answer_timeout),
       set_timeout(__, 1, check_state),
       fsm:set_event(__, busy_online),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync, "*SEND", "OK"} ->
      [fsm:maybe_send_at_command(__, {at, "?PC", ""}),
       set_timeout(__, 1, pc_timeout),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {async, Notification = {status, _, _}} ->
      Channel_state = nl_hf:process_async_status(Notification),
      Busy_handler =
      fun (LSM, initiation_listen) when SM#sm.state == busy ->
           fsm:set_event(LSM, initiation_listen);
          (LSM, _) -> LSM
      end,
      [Busy_handler(__, Channel_state),
       env:put(__, channel_state, Channel_state),
       env:put(__, channel_state_msg, Notification),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {bitrate, _, Bitrate}} ->
      share:put(SM, bitrate, Bitrate);
    {async, {pid, Pid}, Recv_Tuple =
                          {recv, _, _, Local_address , _,  _,  _,  _,  _, P}} ->
      ?INFO(?ID, "Received: ~p~n", [Recv_Tuple]),
      [process_received(__, Recv_Tuple),
       fsm:set_event(__, recv_data),
       fsm:run_event(MM, __, P)
      ](SM);
    {async, {pid, _Pid}, Recv_Tuple} ->
      ?INFO(?ID, "Received: ~p~n", [Recv_Tuple]),
      [process_received(__, Recv_Tuple),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {delivered, PC, _Src}} ->
      [burst_nl_hf:pop_delivered(__, PC),
       check_pcs(__),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {failed, PC, _Src}} ->
      [burst_nl_hf:failed_pc(__, PC),
       check_pcs(__),
       fsm:run_event(MM, __, {})
      ](SM);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

%nl_hf:add_neighbours(__, NL_Src, {Rssi, Integrity}

check_pcs(SM) ->
  State = SM#sm.state,
  PCS = share:get(SM, nothing, wait_async_pcs, []),
  if PCS == [], State =/= busy ->
    fsm:set_event(SM, pick);
  true ->
    fsm:set_event(SM, eps)
  end.

run_hook_handler(MM, SM, Term, Event) ->
  [fsm:clear_timeout(__, answer_timeout),
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ](SM).

init_nl_burst(SM) ->
  share:put(SM, [{burst_data_buffer, queue:new()},
                {local_pc, 1},
                {current_neighbours, []},
                {neighbours_channel, []},
                {wait_async_pcs, []},
                {last_states, queue:new()},
                {statistics_neighbours, queue:new()},
                {statistics_queue, queue:new()}
  ]).

%------------------------------Handle functions---------------------------------
handle_idle(_MM, #sm{event = no_routing} = SM, _Term) ->
  Params = nl_hf:find_event_params(SM, no_routing),
  Routing_handler =
  fun (LSM, {no_routing, Dst}) ->
        fsm:cast(LSM, nl_impl, {send, {nl, update, routing, Dst}});
      (LSM, _) -> LSM
  end,

  [Routing_handler(__, Params),
   nl_hf:update_states(__),
   fsm:set_event(__, eps)
  ](SM);
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_idle ~120p~n", [Term]),
  [nl_hf:update_states(__),
   fsm:set_event(__, eps)
  ](SM).

handle_recv(_MM, #sm{event = recv_data} = SM, Term) ->
  [nl_hf:update_states(__),
   process_data(__, Term)
  ](SM);
handle_recv(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_recv ~120p~n", [Term]),
  [nl_hf:update_states(__),
   fsm:set_event(__, eps)
  ](SM).

handle_sensing(_MM, #sm{event = pick} = SM, Term) ->
  ?TRACE(?ID, "handle_sensing ~120p~n", [Term]),
  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  Queue_handler =
  fun (LSM, true)  -> LSM#sm{event = empty};
      (LSM, false) -> LSM#sm{event = try_transmit}
  end,
  [nl_hf:update_states(__),
   Queue_handler(SM, queue:is_empty(Q))
  ](SM);
handle_sensing(_MM, #sm{event = Ev} = SM, _) when (Ev == try_transmit) or
                                                  (Ev == routing_updated) or
                                                  (Ev == initiation_listen)->
  % 1. check if there are messages in the buffer with existing
  %    routing to dst address
  % 2. if exist -> check state and try transmit
  %    if not, go back to idle
  Cast_handler =
  fun (LSM, try_transmit) ->
        fsm:cast(LSM, nl_impl, {send, {nl, get, routing}});
      (LSM, _) -> LSM
  end,

  Routing_handler =
  fun (#sm{env = #{channel_state := initiation_listen}} = LSM, {true, _}) ->
        fsm:set_event(LSM, initiation_listen);
      (LSM, {true, _}) ->
        Channel_state = env:get(LSM, channel_state),
        fsm:set_event(LSM, Channel_state);
      (LSM, {false, Dst}) ->
        [nl_hf:add_event_params(__, {no_routing, Dst}),
         fsm:set_event(__, eps)
        ](LSM);
      (LSM, false) ->
        fsm:set_event(LSM, no_routing)
  end,
  Exist = burst_nl_hf:check_routing_existance(SM),
  [Cast_handler(__, Ev),
   nl_hf:update_states(__),
   Routing_handler(__, Exist)
  ](SM);
handle_sensing(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_sensing ~120p~n", [Term]),
  [nl_hf:update_states(__),
   fsm:set_event(__, eps)
  ](SM).

handle_transmit(_MM, #sm{event = next_packet} = SM, _Term) ->
  Local_address = share:get(SM, local_address),
  {send_params, {Whole_len, Tuple, Tail}} =
    nl_hf:find_event_params(SM, send_params),

  Packet_handler =
  fun(Packets) when Packets == [] -> [nothing, []];
     (Packets) -> [H | T] = Packets, [H, T]
  end,

  Wait_async_handler =
  fun(LSM, Src, Dst, PC) when Src == Local_address ->
      Wait_ack = share:get(SM, wait_ack),
      fsm:set_timeout(LSM, {s, Wait_ack}, {wait_nl_async, Dst, PC});
     (LSM, _, _, _) -> LSM
  end,

  Transmit_handler =
  fun(LSM, T, Rest) ->
      Pid = share:get(LSM, pid),
      [PC, PC_local, Src, Dst] = burst_nl_hf:getv([id_at, id_local, src, dst], T),
      Data = burst_nl_hf:create_nl_burst_header(LSM, T),
      Route_Addr = nl_hf:get_routing_address(LSM, Dst),

      AT = {at, {pid, Pid}, "*SEND", Route_Addr, Data},
      [P, NTail] = Packet_handler(Rest),
      NT = {send_params, {Whole_len, P, NTail}},
      PCS = share:get(SM, nothing, wait_async_pcs, []),
      [share:put(__, wait_async_pcs, [PC | PCS]),
       nl_hf:add_event_params(__, NT),
       Wait_async_handler(__, Src, Dst, PC_local),
       fsm:set_event(__, eps),
       fsm:maybe_send_at_command(__, AT)
      ](LSM)
  end,

  Params_handler =
  fun(LSM, nothing, []) ->
        fsm:set_event(LSM, eps);
      (LSM, T, Rest) ->
        Transmit_handler(LSM, T, Rest)
  end,

  ?INFO(?ID, "try transmit ~p Rest ~p~n", [Tuple, Tail]),
  [nl_hf:update_states(__),
   Params_handler(__, Tuple, Tail)
  ](SM);
handle_transmit(_MM, #sm{event = initiation_listen} = SM, _Term) ->
  % 1. get packets from the queue for one dst where routing exist for
  % 2. get current package counter and bind
  [Whole_len, Packet, Tail] = burst_nl_hf:get_packets(SM),
  Packet_handler =
  fun (LSM) when Packet == nothing, Tail == [] ->
        fsm:set_event(LSM, pick);
      (LSM) ->
        NT = {send_params, {Whole_len, Packet, Tail}},
        [share:put(__, wait_async_pcs, []),
         fsm:maybe_send_at_command(__, {at, "?PC", ""}),
         nl_hf:add_event_params(__, NT),
         set_timeout(__, 1, pc_timeout),
         fsm:set_event(__, eps)
        ](LSM)
  end,
  ?TRACE(?ID, "Try to send packet Packet ~120p Tail ~p ~n", [Packet, Tail]),
  [nl_hf:update_states(__),
   Packet_handler(__)
  ](SM);
handle_transmit(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_transmit ~120p~n", [Term]),
  [nl_hf:update_states(__),
   fsm:set_event(__, eps)
  ](SM).

handle_busy(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_busy ~120p~n", [Term]),
  [nl_hf:update_states(__),
   fsm:set_event(__, eps)
  ](SM).

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

% ------------------------------- Helper functions -----------------------------
set_routing(SM, Routing) ->
  Data_buffer = share:get(SM, nothing, burst_data_buffer, queue:new()),
  Params = nl_hf:find_event_params(SM, no_routing),
  Exist =
  case Params of
    {no_routing, Dst} ->
      nl_hf:routing_exist(SM, Dst);
    _ -> false
  end,

  State = SM#sm.state,
  Routing_handler =
  fun (LSM, idle) when Data_buffer =/= {[],[]} ->
       fsm:set_event(LSM, routing_updated);
      (LSM, sensing) when Routing == [{default,63}];
                          not Exist ->
       fsm:set_event(LSM, no_routing);
      (LSM, sensing) when Exist ->
       fsm:set_event(LSM, routing_updated);
      (LSM, _) ->
       fsm:set_event(LSM, eps)
  end,
  Routing_handler(SM, State).

process_nl_send(SM, _, {nl, send, tolerant, ?ADDRESS_MAX, _Payload}) ->
  fsm:cast(SM, nl_impl, {send, {nl, send, error}});
process_nl_send(SM, _, T) ->
  push_tolerant_queue(SM, T).

push_tolerant_queue(SM, {nl, send, tolerant, Dst, Payload}) ->
  LocalPC = share:get(SM, local_pc),
  Len = byte_size(Payload),
  Src = share:get(SM, local_address),

  Tuple =
  burst_nl_hf:replace([id_local, id_remote, src, dst, len, payload],
                      [LocalPC, LocalPC, Src, Dst, Len, Payload],
              burst_nl_hf:create_default()),

  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  ?TRACE(?ID, "Add to burst queue ~p~n", [Tuple]),

  [burst_nl_hf:increase_local_pc(__, local_pc),
   share:put(__, burst_data_buffer, queue:in(Tuple, Q)),
   fsm:cast(__, nl_impl, {send, {nl, send, LocalPC}})
  ](SM).

extract_status(SM, Status) ->
  Parsed = [string:rstr(X, "INITIATION LISTEN") || X <- string:tokens (Status, "\r\n")],
  ?TRACE(?ID, "~p~n", [Status]),
  Listen =
  lists:filtermap(fun(X) ->
                    if X == 0 -> false;
                      true -> {true, true}
                  end end, Parsed),
  Status_handler =
  fun (LSM, [true]) ->
        fsm:set_event(LSM, initiation_listen);
      (LSM, _) ->
        [fsm:set_event(__, busy_online),
         fsm:clear_timeout(__, check_state),
         fsm:set_timeout(__, {s, 1}, check_state)
        ](LSM)
  end,
  Status_handler(SM, Listen).

init_pc(SM, PC) ->
  ?INFO(?ID, "init_pc ~p~n", [PC]),
  share:put(SM, pc, PC).

process_pc(SM, LPC) ->
  PC = list_to_integer(LPC),
  Send_params = nl_hf:find_event_params(SM, send_params),
  case Send_params of
    {send_params, {Whole_len, Tuple, Tail}} when Tuple =/= nothing ->
      ?INFO(?ID, "process_pc for ~p~n", [Tuple]),
      PC_Tuple = burst_nl_hf:replace(id_at, PC, Tuple),
      NT = {send_params, {Whole_len, PC_Tuple, Tail}},
      [init_pc(__, PC),
       burst_nl_hf:bind_pc(__, PC, Tuple),
       nl_hf:add_event_params(__, NT),
       fsm:set_event(__, next_packet)
      ](SM);
    _ ->
      init_pc(SM, PC)
  end.

process_data(SM, Data) ->
  Local_address = share:get(SM, local_address),
  try
    Tuple = burst_nl_hf:extract_nl_burst_header(SM, Data),
    ?TRACE(?ID, "Received ~p~n", [Tuple]),
    [Id_remote, Src, Dst, Len, Whole_len, Payload] =
      burst_nl_hf:getv([id_remote, src, dst, len, whole_len, payload], Tuple),
    Params_name = atom_name(wait_len, Dst),
    Params = nl_hf:find_event_params(SM, Params_name),

    Packet_handler =
    fun (LSM, EP, Rest) when Rest =< 0 ->
          ?TRACE(?ID, "Packet_handler len ~p~n", [Rest]),
          [send_acks(__, Src),
           nl_hf:clear_spec_event_params(__, EP),
           nl_hf:clear_spec_timeout(__, wait_data_tmo),
           %fsm:clear_timeout(__, {wait_data_tmo, Src}),
           fsm:set_event(__, pick)
          ](LSM);
        (LSM, _EP, Rest) ->
          NT = {Params_name, {Len, Rest}},
          ?TRACE(?ID, "Packet_handler ~p ~p~n", [Len, Rest]),
          Time = calc_burst_time(LSM, Rest),
          [nl_hf:add_event_params(__, NT),
           %fsm:clear_timeout(__, {wait_data_tmo, Src}),
           nl_hf:clear_spec_timeout(__, wait_data_tmo),
           fsm:set_timeout(__, {s, Time}, {wait_data_tmo, Src}),
           fsm:set_event(__, eps)
          ](LSM)
    end,

    %Check whole len: pick or wait for more data
    Wait_handler =
    fun (LSM, []) when Whole_len - Len =< 0 ->
          ?TRACE(?ID, "Wait_handler len ~p~n", [Whole_len - Len]),
          [send_acks(__, Src),
           %fsm:clear_timeout(__, {wait_data_tmo, Src}),
           nl_hf:clear_spec_timeout(__, wait_data_tmo),
           fsm:set_event(__, pick)
          ](LSM);
        (LSM, []) ->
          NT = {Params_name, {Len, Whole_len - Len}},
          ?TRACE(?ID, "Wait_handler ~p ~p~n", [Len, Whole_len]),
          Time = calc_burst_time(LSM, Whole_len),
          [nl_hf:add_event_params(__, NT),
           fsm:set_timeout(__, {s, Time}, {wait_data_tmo, Src}),
           fsm:set_event(__, eps)
          ](LSM);
        (LSM, EP = {_P, {_L, WL}})->
          Waiting_rest = WL - Len,
          Packet_handler(LSM, EP, Waiting_rest)
    end,

    Name = atom_name(acks, Src),
    Destination_handler =
    fun (LSM) when Dst == Local_address ->
          Acks = nl_hf:find_event_params(SM, Name),
          Updated =
          case Acks of
            {Name, UAcks} ->
              Member = lists:member(Id_remote, UAcks),
              ?INFO(?ID, "Add ack ~p to ~p, is member ~p~n", [Id_remote, UAcks, Member]),
              if Member -> UAcks; true -> [Id_remote | UAcks] end;
            _ -> [Id_remote]
          end,
          [nl_hf:add_event_params(__, {Name, Updated}),
           fsm:cast(__, nl_impl, {send, {nl, recv, Src, Dst, Payload}})
          ](LSM);
        (LSM) ->
          burst_nl_hf:check_dublicated(LSM, Tuple)
    end,

    [Destination_handler(__),
     burst_nl_hf:increase_local_pc(__, local_pc),
     Wait_handler(__, Params)
    ](SM)
  catch error: Reason ->
    % Got a message not for NL, no NL header
    ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
    fsm:set_event(SM, eps)
  end.

get_buffer(SM) ->
  QL = queue:to_list(share:get(SM, nothing, burst_data_buffer, queue:new())),
  lists:foldl(
  fun(X, A) ->
    [Src, Dst, Len, Payload] = burst_nl_hf:getv([src, dst, len, payload], X),
    [{Payload, Src, Dst, Len} | A]
  end, [], QL).

clear_buffer(SM) ->
  share:put(SM, burst_data_buffer, queue:new()).

calc_burst_time(SM, Len) ->
    Bitrate = share:get(SM, bitrate),
    Byte_per_s = Bitrate / 8,
    T = Len / Byte_per_s,
    ?INFO(?ID, "Wait for length ~p bytes, time ~p~n", [Len, T]),
    %TODO: find out if its real time
    if T < 1 -> 1; true -> T end.

atom_name(Name, Dst) ->
  DstA = binary_to_atom(integer_to_binary(Dst), utf8),
  list_to_atom(atom_to_list(Name) ++ atom_to_list(DstA)).

set_timeout(SM, S, Timeout) ->
  Check = fsm:check_timeout(SM, Timeout),
  if not Check ->
      fsm:set_timeout(SM, {s, S}, Timeout);
    true -> SM
  end.

process_received(SM, Tuple) ->
  {Src, Rssi, Integrity} =
  case Tuple of
    {recvpbm,_,RSrc,_,_,  RRssi,RIntegrity,_,_} ->
      {RSrc, RRssi, RIntegrity};
    {Format,_,RSrc,_,_,_,RRssi,RIntegrity,_,_} when Format == recvim;
                                                    Format == recvims;
                                                    Format == recv ->
      {RSrc, RRssi, RIntegrity}
  end,

  [nl_hf:fill_statistics(__, neighbours, Src),
   nl_hf:add_neighbours(__, Src, {Rssi, Integrity})
  ](SM).

send_acks(SM, Src) ->
  Name = atom_name(acks, Src),
  Acks = nl_hf:find_event_params(SM, Name),
  send_acks_helper(SM, Src, Acks).
send_acks_helper(SM, _, []) -> SM;
send_acks_helper(SM, Src, {_, Acks}) ->
  ?INFO(?ID, "Send acks ~p to src ~p~n", [Acks, Src]),
  Name = atom_name(acks, Src),
  Payload = burst_nl_hf:encode_ack(lists:reverse(Acks)),
  [nl_hf:add_event_params(__, {Name, []}),
   fsm:cast(__, nl_impl, {send, {nl, ack, Src, Payload}})
  ](SM).

recv_ack(SM, Dst, L) ->
  ?INFO(?ID, "Received acks from ~p: ~w~n", [Dst, L]),
  recv_ack_helper(SM, Dst, L).
recv_ack_helper(SM, _Dst, []) -> SM;
recv_ack_helper(SM, Dst, [PC | T]) ->
  Wait_ack = fsm:check_timeout(SM, {wait_nl_async, Dst, PC}),
  ?INFO(?ID, "Wait_ack ~p: ~p ~n", [Dst, PC]),
  if Wait_ack ->
    Local_address = share:get(SM, local_address),
    [fsm:cast(__, nl_impl, {send, {nl, delivered, PC, Local_address, Dst}}),
     fsm:clear_timeout(__, {wait_nl_async, Dst, PC}),
     recv_ack_helper(__, Dst, T)
    ](SM);
  true ->
    recv_ack_helper(SM, Dst, T)
  end.
