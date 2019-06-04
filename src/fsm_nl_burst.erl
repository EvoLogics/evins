%% Copyright (c) 2017, Veronika Kebkal <veronika.kebkal@evologics.de>
%%                     Oleksiy Kebkal <lesha@evologics.de>
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
                  {initiation_listen, idle},
                  {routing_updated, sensing},
                  {recv_data, recv},
                  {reset, idle},
                  {busy_online, idle},
                  {no_routing, idle},
                  {connection_failed, idle},
                  {pick, sensing},
                  {next_packet, idle}
                 ]},

                {recv,
                 [{recv_data, recv},
                  {no_routing, recv},
                  {pick, sensing},
                  {busy_online, recv},
                  {reset, idle},
                  {initiation_listen, recv},
                  {connection_failed, idle}
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
                  {reset, idle},
                  {next_packet,transmit},
                  {pick, sensing},
                  {connection_failed, idle}
                 ]},

                {transmit,
                 [{routing_updated, sensing},
                  {pick, sensing},
                  {next_packet, transmit},
                  {recv_data, recv},
                  {no_routing, idle},
                  {reset, idle},
                  {busy_online, transmit},
                  {initiation_listen, transmit},
                  {connection_failed, idle}
                 ]},

                {busy,
                 [{next_packet, busy},
                  {initiation_listen, sensing},
                  {recv_data, recv},
                  {busy_online, busy},
                  {no_routing, idle},
                  {reset, idle},
                  {connection_failed, idle}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  ?INFO(?ID, "init nl burst ~n",[]),
   [init_nl_burst(__),
   env:put(__, status, "Idle"),
   env:put(__, channel_state, initiation_listen),
   env:put(__, channel_state_msg, {status, 'INITIATION', 'LISTEN'}),
   env:put(__, updating, false),
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
    {timeout, update_routing} ->
      [fsm:set_event(__, no_routing),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, {wait_data_tmo, Src}} when State == recv ->
      Send_ack = share:get(SM, send_ack_tmo),
      [fsm:set_event(__, pick),
       fsm:set_timeout(__, {s, Send_ack}, {send_acks, Src}),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, {send_acks, Src}} ->
      send_acks(SM, Src);
    {timeout, try_transmit} when State == sensing; State == idle ->
      [fsm:set_event(__, try_transmit),
      fsm:run_event(MM, __, {})
      ](SM);
    {timeout, try_transmit} ->
      SM;
    {timeout, pc_timeout} when State == busy ->
      SM;
    {timeout, pc_timeout} ->
      fsm:maybe_send_at_command(SM, {at, "?PC", ""});
    {timeout, {wait_nl_async, Dst, PC}} ->
      [burst_nl_hf:update_statistics_tolerant(__, state, {PC, src, failed}),
       fsm:cast(__, nl_impl, {send, {nl, failed, PC, Local_address, Dst}})
      ](SM);
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
      [process_failed_update(__, Dst),
       fsm:run_event(MM, __, {})
      ](SM);
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
    {nl, get, statistics, tolerant} ->
      QS = share:get(SM, nothing, statistics_tolerant, queue:new()),
      Statistics = burst_nl_hf:get_statistics_data(QS),
      fsm:cast(SM, nl_impl, {send, {nl, statistics, tolerant, Statistics}});
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
    {nl, get, bitrate} ->
      Bitrate = share:get(SM, nothing, bitrate, empty),
      fsm:cast(SM, nl_impl, {send, {nl, bitrate, Bitrate}});
    {nl, get, status} ->
      Status = env:get(SM, status),
      fsm:cast(SM, nl_impl, {send, {nl, status, Status}});
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
      Updating = env:get(SM, updating),
      Event_handler =
      fun (LSM) when LSM#sm.state == idle, Updating == false ->
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
    {sync, "*SEND", {error, "ERROR CONNECTION CLOSED"}} ->
      PCS = share:get(SM, nothing, wait_async_pcs, []),
      PC_handler =
      fun (LSM, []) -> LSM;
          (LSM, [PC | _]) -> burst_nl_hf:failed_pc(LSM, PC)
      end,
      [PC_handler(__, PCS),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync,"*SEND",{error, _}} ->
      [share:put(__, wait_sync, false),
       set_timeout(__, {s, 1}, check_state),
       fsm:clear_timeout(__, answer_timeout),
       fsm:set_event(__, busy_online),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync,"*SEND", {busy, _}} ->
      PCS = share:get(SM, nothing, wait_async_pcs, []),
      PC_handler =
      fun (LSM, []) -> LSM;
          (LSM, [PC | _]) -> burst_nl_hf:failed_pc(LSM, PC)
      end,
      ?INFO(?ID, "PCS ~w~n", [share:get(SM, wait_async_pcs)]),
      [PC_handler(__, PCS),
       fsm:clear_timeout(__, answer_timeout),
       set_timeout(__, {s, 1}, check_state),
       fsm:set_event(__, busy_online),
       fsm:run_event(MM, __, {})
      ](SM);
    {sync, "*SEND", "OK"} ->
      [fsm:maybe_send_at_command(__, {at, "?PC", ""}),
       set_timeout(__, {ms, 100}, pc_timeout),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {async, Notification = {status, _, _}} ->
      Channel_state = nl_hf:process_async_status(Notification),
      Busy_handler =
      fun (LSM, initiation_listen) when LSM#sm.state == busy;
                                        LSM#sm.state == idle->
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
      [process_received(__, Recv_Tuple),
       fsm:set_event(__, recv_data),
       fsm:run_event(MM, __, P)
      ](SM);
    {async, {pid, _Pid}, Recv_Tuple} ->
      [process_received(__, Recv_Tuple),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {delivered, PC, _Src}} ->
      [burst_nl_hf:pop_delivered(__, PC),
       check_pcs(__),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {failed, PC, _}} ->
      [burst_nl_hf:failed_pc(__, PC),
       check_pcs(__),
       fsm:run_event(MM, __, {})
      ](SM);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

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
process_failed_update(SM, Dst) ->
  Update_retries = share:get(SM, update_retries),
  ?INFO(?ID, "Check retries ~p ~p~n", [Update_retries, env:get(SM, update)]),
  case env:get(SM, update) of
    {C, D} when D == Dst, C >= Update_retries ->
      [burst_nl_hf:remove_packet(__, Dst),
       env:put(__, update, nothing),
       nl_hf:clear_spec_event_params(__, {no_routing, Dst}),
       env:put(__, updating, false),
       fsm:set_event(__, try_transmit)
      ](SM);
    {C, D} when D == Dst ->
      [fsm:cast(__, nl_impl, {send, {nl, update, routing, Dst}}),
       env:put(__, updating, true),
       env:put(__, update, {C + 1, D})
      ](SM);
    _ ->
      [fsm:cast(__, nl_impl, {send, {nl, update, routing, Dst}}),
       env:put(__, updating, true),
       env:put(__, update, {1, Dst})
      ](SM)
  end.

handle_idle(_MM, #sm{event = connection_failed} = SM, _Term) ->
  fsm:set_event(SM, no_routing);
handle_idle(_MM, #sm{event = initiation_listen} = SM, _Term) ->
  BD = share:get(SM, nothing, burst_data_buffer, queue:new()),
  Updating = env:get(SM, updating),
  Transmit = (BD =/= {[],[]}) and (Updating == false),
  if Transmit ->
    fsm:set_event(SM, try_transmit);
  true ->
    fsm:set_event(SM, eps) end;
handle_idle(_MM, #sm{event = no_routing, env = #{channel_state := initiation_listen}} = SM, _Term) ->
  Params = nl_hf:find_event_params(SM, no_routing),
  Routing_handler =
  fun (LSM, {no_routing, Dst}) ->
    Status = lists:flatten([io_lib:format("Update routing to ~p",[Dst])]),
    [env:put(__, status, Status),
     env:put(__, updating, true),
     fsm:cast(__, nl_impl, {send, {nl, update, routing, Dst}})
    ](LSM);
    (LSM, _) ->
     env:put(LSM, status, "Idle")
  end,
  [fsm:set_event(__, eps),
   Routing_handler(__, Params),
   nl_hf:update_states(__)
  ](SM);
handle_idle(_MM, #sm{event = no_routing} = SM, Term) ->
  ?TRACE(?ID, "handle_idle ~120p~n", [Term]),
  [fsm:set_timeout(__, {s, 1}, update_routing),
   fsm:set_event(__, eps)
  ](SM);
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_idle ~120p~n", [Term]),
  [env:put(__, status, "Idle"),
   nl_hf:update_states(__),
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
  Transmit = nl_hf:rand_float(SM, tmo_transmit),
  Queue_handler =
  fun (LSM, true)  -> fsm:set_event(LSM, empty);
      (LSM, false) ->
        [fsm:set_timeout(__, {ms, Transmit}, try_transmit),
         fsm:set_event(__, eps)
        ](LSM)
  end,
  [nl_hf:update_states(__),
   Queue_handler(__, queue:is_empty(Q))
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
      (LSM, initiation_listen) ->
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
        fsm:set_event(LSM, empty)
  end,
  Exist = burst_nl_hf:check_routing_existance(SM),

  ?INFO(?ID, "Sensing ~p ~p ~p~n", [Ev, env:get(SM, channel_state), Exist]),

  [env:put(__, status, "Check channel state and try transmit"),
   Cast_handler(__, Ev),
   nl_hf:update_states(__),
   Routing_handler(__, Exist)
  ](SM);
handle_sensing(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_sensing ~120p~n", [Term]),
  [nl_hf:update_states(__),
   set_timeout(__, {s, 1}, check_state),
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
      Wait_ack = share:get(LSM, wait_ack),
      fsm:set_timeout(LSM, {s, Wait_ack}, {wait_nl_async, Dst, PC});
     (LSM, _, _, _) -> LSM
  end,

  Transmit_handler =
  fun(LSM, T, Rest) ->
      Pid = share:get(LSM, pid),
      [PC, PC_local, Src, Dst] = burst_nl_hf:getv([id_at, id_local, src, dst], T),
      Data = burst_nl_hf:create_nl_burst_header(LSM, T),
      Route_Addr = nl_hf:get_routing_address(LSM, Dst),
      Status = lists:flatten([io_lib:format("Transmitting packet ~p", [PC_local])]),
      AT = {at, {pid, Pid}, "*SEND", Route_Addr, Data},
      [P, NTail] = Packet_handler(Rest),
      NT = {send_params, {Whole_len, P, NTail}},
      PCS = share:get(LSM, nothing, wait_async_pcs, []),
      [burst_nl_hf:update_statistics_tolerant(__, time, T),
       env:put(__, status, Status),
       share:put(__, wait_async_pcs, [PC | PCS]),
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

  ?INFO(?ID, "try transmit ~p~n", [Tuple]),
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
        PC = burst_nl_hf:getv(id_local, Packet),
        Status = lists:flatten([io_lib:format("Transmitting packet ~p", [PC])]),
        [env:put(__, status, Status),
         share:put(__, wait_async_pcs, []),
         fsm:maybe_send_at_command(__, {at, "?PC", ""}),
         nl_hf:add_event_params(__, NT),
         set_timeout(__, {ms, 100}, pc_timeout),
         fsm:set_event(__, eps)
        ](LSM)
  end,
  ?TRACE(?ID, "Try to send packet Packet ~120p~n", [Packet]),
  [nl_hf:update_states(__),
   Packet_handler(__)
  ](SM);
handle_transmit(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_transmit ~120p~n", [Term]),
  [nl_hf:update_states(__),
   fsm:set_event(__, eps),
   set_timeout(__, {s, 1}, check_state)
  ](SM).

handle_busy(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_busy ~120p~n", [Term]),
  {status, P1, P2} = env:get(SM, channel_state_msg),
  Status = lists:flatten([io_lib:format("Busy state ~s ~p", [P1, P2])]),
  [env:put(__, status,Status ),
   nl_hf:update_states(__),
   fsm:set_event(__, eps),
   set_timeout(__, {s, 1}, check_state)
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
    [] -> true;
    {no_routing, Dst} ->
      nl_hf:routing_exist(SM, Dst);
    _ -> false
  end,

  No_routing =
  (Data_buffer =/= {[],[]}) and
  ((Routing == [{default,63}]) or (Exist == false)),

  Routing_updated =
  (Data_buffer =/= {[],[]}) and (Exist == true),

  State = SM#sm.state,
  ?INFO(?ID, "SET_ROUTING State ~p ~p ~p ~p ~p ~n", [Params, State, Data_buffer == {[],[]}, Routing, Exist]),

  Routing_handler =
  fun (LSM, _) when No_routing ->
       [env:put(__, updating, false),
        fsm:set_event(__, no_routing)
       ](LSM);
      (LSM, Ev) when Routing_updated and
                    ((Ev == idle) or (Ev == sensing) or (Ev == transmit)) ->
       [env:put(__, updating, false),
        fsm:set_event(__, routing_updated)
       ](LSM);
      (LSM, _) ->
       fsm:set_event(LSM, eps)
  end,

  Status = lists:flatten(
            [io_lib:format("Set routing in state ~s", [State])]),
  [env:put(__, status, Status),
   Routing_handler(__, State)
  ](SM).

process_nl_send(SM, _, {nl, send, tolerant, ?ADDRESS_MAX, _Payload}) ->
  fsm:cast(SM, nl_impl, {send, {nl, send, error}});
process_nl_send(SM, _, T) ->
  push_tolerant_queue(SM, T).

get_role(SM, Src, Dst) ->
  Local_address = share:get(SM, local_address),
  case Src of
    Local_address -> source;
    _ when Dst == Local_address -> destination;
    _ -> relay
  end.

push_tolerant_queue(SM, {nl, send, tolerant, Dst, Payload}) ->
  LocalPC = share:get(SM, local_pc),
  Len = byte_size(Payload),
  Src = share:get(SM, local_address),

  Tuple =
  burst_nl_hf:replace([id_local, id_remote, src, dst, len, payload],
                      [LocalPC, LocalPC, Src, Dst, Len, Payload],
              burst_nl_hf:create_default()),

  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  %QS = share:get(SM, nothing, statistics_tolerant, queue:new()),

  Role = get_role(SM, Src, Dst),
  <<Hash:16, _/binary>> = crypto:hash(md5,Payload),
  STuple = {Role, LocalPC, Hash, Len, 0, unknown, Src, Dst},
  [burst_nl_hf:increase_local_pc(__, local_pc),
   nl_hf:queue_push(__, statistics_tolerant, STuple, 1000),
   %share:put(__, statistics_tolerant, queue:in(STuple, QS)),
   share:put(__, burst_data_buffer, queue:in(Tuple, Q)),
   fsm:cast(__, nl_impl, {send, {nl, send, LocalPC}})
  ](SM).

extract_status(SM, Status) when is_list(Status)->
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
  Status_handler(SM, Listen);
extract_status(SM, Status) ->
  ?ERROR(?ID, "Status ~p~n", [Status]),
  [fsm:clear_timeout(__, check_state),
   fsm:set_timeout(__, {s, 1}, check_state)
  ](SM).

init_pc(SM, PC) ->
  ?INFO(?ID, "init_pc ~p~n", [PC]),
  share:put(SM, pc, PC).

process_pc(SM, LPC) ->
  PC = list_to_integer(LPC),
  Send_params = nl_hf:find_event_params(SM, send_params),
  case Send_params of
    {send_params, {Whole_len, Tuple, Tail}} when Tuple =/= nothing ->
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
    Send_ack = share:get(SM, send_ack_tmo),
    Packet_handler =
    fun (LSM, EP, Rest) when Rest =< 0 ->
          ?TRACE(?ID, "Packet_handler len ~p~n", [Rest]),
          Status = lists:flatten([io_lib:format("Received data ~p", [Id_remote])]),
          [env:put(__, status, Status),
           fsm:set_timeout(__, {s, Send_ack}, {send_acks, Src}),
           nl_hf:clear_spec_event_params(__, EP),
           nl_hf:clear_spec_timeout(__, wait_data_tmo),
           fsm:set_event(__, pick)
          ](LSM);
        (LSM, _EP, Rest) ->
          NT = {Params_name, {Len, Rest}},
          ?TRACE(?ID, "Packet_handler ~p ~p~n", [Len, Rest]),
          Time = calc_burst_time(LSM, Rest),
          Status = lists:flatten(
            [io_lib:format("Receive data ~p, wait for ~p bits",
              [Id_remote, Rest])]),
          [env:put(__, status, Status),
           nl_hf:add_event_params(__, NT),
           nl_hf:clear_spec_timeout(__, wait_data_tmo),
           fsm:set_timeout(__, {s, Time}, {wait_data_tmo, Src}),
           fsm:set_event(__, eps)
          ](LSM)
    end,

    %Check whole len: pick or wait for more data
    Wait_handler =
    fun (LSM, []) when Whole_len - Len =< 0 ->
          ?TRACE(?ID, "Wait_handler len ~p~n", [Whole_len - Len]),
          Status = lists:flatten(
            [io_lib:format("Receive data ~p, wait for ~p bits",
              [Id_remote, Whole_len - Len])]),
          [env:put(__, status, Status),
           fsm:set_timeout(__, {s, Send_ack}, {send_acks, Src}),
           nl_hf:clear_spec_timeout(__, wait_data_tmo),
           fsm:set_event(__, pick)
          ](LSM);
        (LSM, []) ->
          NT = {Params_name, {Len, Whole_len - Len}},
          ?TRACE(?ID, "Wait_handler ~p ~p~n", [Len, Whole_len]),
          Time = calc_burst_time(LSM, Whole_len),
          Status = lists:flatten(
            [io_lib:format("Receive data ~p, wait for ~p bits",
              [Id_remote, Whole_len - Len])]),
          [env:put(__, status, Status),
           nl_hf:add_event_params(__, NT),
           fsm:set_timeout(__, {s, Time}, {wait_data_tmo, Src}),
           fsm:set_event(__, eps)
          ](LSM);
        (LSM, EP = {_P, {_L, WL}})->
          Waiting_rest = WL - Len,
          Packet_handler(LSM, EP, Waiting_rest)
    end,

    Name = atom_name(acks, Src),
    Acks = env:get(SM, Name),
    ?INFO(?ID, "Current acks ~p, got ID ~p~n", [Acks, Id_remote]),

    Destination_handler =
    fun (LSM) when Dst == Local_address ->
          Updated =
          if Acks == nothing -> [Id_remote];
          true ->
            Member = lists:member(Id_remote, Acks),
            ?INFO(?ID, "Add ack ~p to ~w, is member ~p~n", [Id_remote, Acks, Member]),
            if Member -> Acks; true -> [Id_remote | Acks] end
          end,
          ?INFO(?ID, "Updated ack list ~p~n", [Updated]),
          [env:put(__, status, "Receive data on destination"),
           env:put(__, Name, Updated),
           fsm:cast(__, nl_impl, {send, {nl, recv, tolerant, Src, Dst, Payload}})
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
    [PC, Src, Dst, Len, Payload] = burst_nl_hf:getv([id_local, src, dst, len, payload], X),
    [{Payload, Src, Dst, Len, PC} | A]
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
      fsm:set_timeout(SM, S, Timeout);
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
  Acks = env:get(SM, Name),
  send_acks_helper(SM, Src, Acks).
send_acks_helper(SM, _, nothing) -> SM;
send_acks_helper(SM, _, []) -> SM;
send_acks_helper(SM, Src, Acks) ->
  ?INFO(?ID, "Send acks ~p to src ~p~n", [Acks, Src]),
  Name = atom_name(acks, Src),
  Max = get_acks_len(SM),
  NA =
  lists:reverse(
   lists:foldl(
    fun(X, A) when length(A) =< Max -> [X | A];
       (_X, A) -> A end,
  [], Acks)),

  ?INFO(?ID, "Next acks ~w~n", [NA]),
  A = lists:reverse(NA),
  Payload = burst_nl_hf:encode_ack(SM, A),
  L = lists:flatten(lists:join(",",[integer_to_list(I) || I <- A])),
  Status = lists:flatten([io_lib:format("Sending ack of packets ~p to ~p",[L, Src])]),
  [env:put(__, status, Status),
   env:put(__, Name, NA),
   fsm:cast(__, nl_impl, {send, {nl, send, ack, byte_size(Payload), Src, Payload}})
  ](SM).

get_acks_len(SM) ->
  Maxim = 60,
  Max = share:get(SM, max_queue),
  if Max < Maxim ->
    round( (Maxim / Max) - 0.5) * Max;
  true -> Maxim
  end.

recv_ack(SM, Dst, L) ->
  ?INFO(?ID, "Received acks from ~p: ~w~n", [Dst, L]),
  recv_ack_helper(SM, Dst, L).
recv_ack_helper(SM, _Dst, []) -> SM;
recv_ack_helper(SM, Dst, [PC | T]) ->
  Wait_ack = fsm:check_timeout(SM, {wait_nl_async, Dst, PC}),
  ?INFO(?ID, "Wait_ack ~p: ~p ~n", [Dst, PC]),
  if Wait_ack ->
    Local_address = share:get(SM, local_address),
    [burst_nl_hf:update_statistics_tolerant(__, state, {PC, src, delivered}),
     fsm:cast(__, nl_impl, {send, {nl, delivered, PC, Local_address, Dst}}),
     fsm:clear_timeout(__, {wait_nl_async, Dst, PC}),
     recv_ack_helper(__, Dst, T)
    ](SM);
  true ->
    recv_ack_helper(SM, Dst, T)
  end.
