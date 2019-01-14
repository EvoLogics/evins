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
                  {recv_data, recv}
                 ]},

                {recv,
                 [{recv_data, recv},
                  {pick, sensing}
                 ]},

                {sensing,
                 [{try_transmit, sensing},
                  {check_state, sensing},
                  {initiation_listen, transmit},
                  {empty, idle},
                  {no_routing, idle},
                  {busy_backoff, busy},
                  {busy_online, busy},
                  {recv_data, recv}
                 ]},

                {transmit,
                 [{pick, sensing},
                  {next_packet, transmit},
                  {recv_data, recv}
                 ]},

                {busy,
                 [{backoff_timeout, sensing},
                  {check_state, sensing},
                  {recv_data, recv}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> init_nl_burst(SM), SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT ~p ~p Term:~p~n", [SM#sm.state, SM#sm.event, Term]),
  Local_address = share:get(SM, local_address),
  Pid = share:get(SM, pid),
  State = SM#sm.state,

  case Term of
    {timeout, answer_timeout} ->
      fsm:cast(SM, nl_impl, {send, {nl, error, <<"ANSWER TIMEOUT">>}});
    {timeout, check_state} ->
      [fsm:maybe_send_at_command(__, {at, "?S", ""}),
       fsm:set_event(__, check_state),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, pc_timeout} when State == busy ->
      SM;
    {timeout, pc_timeout} ->
      fsm:maybe_send_at_command(SM, {at, "?PC", ""});
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
    {nl, get, help} ->
      fsm:cast(SM, nl_impl, {send, {nl, help, ?HELP}});
    {nl, get, routing} ->
      Routing = {nl, routing, nl_hf:routing_to_list(SM)},
      fsm:cast(SM, nl_impl, {send, Routing});
    {nl, get, protocol} ->
      Protocol = share:get(SM, nl_protocol),
      fsm:cast(SM, nl_impl, {send, {nl, protocol, Protocol}});
    {nl, get, address} ->
      fsm:cast(SM, nl_impl, {send, {nl, address, Local_address}});
    {nl, send, error} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, _, _} ->
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
    % TODO: check if busy state needed
    %{sync,"*SEND", {busy, _}} ->
    %  [fsm:maybe_send_at_command(__, {at, "?S", ""}),
    %   run_hook_handler(MM, __, Term, eps)
    %  ](SM);
    {sync, "*SEND", "OK"} ->
      [fsm:maybe_send_at_command(__, {at, "?PC", ""}),
       fsm:set_timeout(__, {s, 1}, pc_timeout),
       run_hook_handler(MM, __, Term, eps)
      ](SM);
    {async, {pid, Pid}, {recv, _, _, Local_address , _,  _,  _,  _,  _, P}} ->
      [fsm:set_event(__, recv_data),
       fsm:run_event(MM, __, P)
      ](SM);
    {async, {delivered, PC, _Src}} ->
      [burst_nl_hf:pop_delivered(__, PC),
       fsm:set_event(__, check_pcs(__)),
       fsm:run_event(MM, __, {})
      ](SM);
    {async, {failed, PC, _Src}} ->
      [burst_nl_hf:failed_pc(__, PC),
       fsm:set_event(__, check_pcs(__)),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, error, {parseError, _}} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

check_pcs(SM) ->
  PCS = share:get(SM, nothing, wait_async_pcs, []),
  if PCS == [] -> pick; true -> eps end.

run_hook_handler(MM, SM, Term, Event) ->
  [fsm:clear_timeout(__, answer_timeout),
   fsm:set_event(__, Event),
   fsm:run_event(MM, __, Term)
  ](SM).

init_nl_burst(SM) ->
  [share:put(__, burst_data_buffer, queue:new()),
   share:put(__, local_pc, 1),
   share:put(__, wait_async_pcs, [])
  ](SM).

%------------------------------Handle functions---------------------------------
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_idle ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_recv(_MM, #sm{event = recv_data} = SM, Term) ->
  process_data(SM, Term);
handle_recv(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_recv ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_sensing(_MM, #sm{event = pick} = SM, Term) ->
  ?TRACE(?ID, "handle_sensing ~120p~n", [Term]),
  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  Queue_handler =
  fun (LSM, true)  -> LSM#sm{event = empty};
      (LSM, false) -> LSM#sm{event = try_transmit}
  end,
  Queue_handler(SM, queue:is_empty(Q));
handle_sensing(_MM, #sm{event = check_state} = SM, _) ->
  [fsm:maybe_send_at_command(__, {at, "?S", ""}),
   fsm:set_timeout(__, {s, 1}, check_state),
   fsm:set_event(__, eps)
  ](SM);
handle_sensing(_MM, #sm{event = try_transmit} = SM, _) ->
  % 1. check if there are messages in the buffer with existing
  %    routing to dst address
  % 2. if exist -> check state and try transmit
  %    if not, go back to idle
  Routing_handler =
  fun (LSM, true) -> fsm:set_event(LSM, check_state);
      (LSM, false) -> fsm:set_event(LSM, no_routing)
  end,
  Routing_handler(SM, burst_nl_hf:check_routing_existance(SM));
handle_sensing(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_sensing ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_transmit(_MM, #sm{event = next_packet} = SM, _Term) ->
  {send_params, {Whole_len, Tuple, Tail}} =
    nl_hf:find_event_params(SM, send_params),

  Packet_handler =
  fun(Packets) when Packets == [] -> [nothing, []];
     (Packets) -> [H | T] = Packets, [H, T]
  end,

  Transmit_handler =
  fun(LSM, T, Rest) ->
      Pid = share:get(LSM, pid),
      [PC, Dst] = burst_nl_hf:getv([id, dst], T),
      Data = burst_nl_hf:create_nl_burst_header(LSM, T),
      Route_Addr = nl_hf:get_routing_address(LSM, Dst),

      AT = {at, {pid, Pid}, "*SEND", Route_Addr, Data},
      [P, NTail] = Packet_handler(Rest),
      NT = {send_params, {Whole_len, P, NTail}},
      PCS = share:get(SM, nothing, wait_async_pcs, []),

      [share:put(__, wait_async_pcs, [PC | PCS]),
       nl_hf:add_event_params(__, NT),
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
  Params_handler(SM, Tuple, Tail);
handle_transmit(_MM, #sm{event = initiation_listen} = SM, _Term) ->
  % 1. get packets from the queue for one dst where routing exist for
  % 2. get current package counter and bind
  [Whole_len, Packet, Tail] = burst_nl_hf:get_packets(SM),
  % TODO: check if Packet is nothing
  NT = {send_params, {Whole_len, Packet, Tail}},
  ?TRACE(?ID, "Try to send packet Packet ~120p Tail ~p ~n", [Packet, Tail]),
  [share:put(__, wait_async_pcs, []),
   fsm:maybe_send_at_command(__, {at, "?PC", ""}),
   nl_hf:add_event_params(__, NT),
   fsm:set_timeout(__, {s, 1}, pc_timeout),
   fsm:set_event(__, eps)
  ](SM);
handle_transmit(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_transmit ~120p~n", [Term]),
  SM#sm{event = eps}.

handle_busy(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_busy ~120p~n", [Term]),
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

% ------------------------------- Helper functions -----------------------------
process_nl_send(SM, _, {nl, send, tolerant, ?ADDRESS_MAX, _Payload}) ->
  fsm:cast(SM, nl_impl, {send, {nl, send, error}});
process_nl_send(SM, _, T) ->
  [push_tolerant_queue(__, T),
   fsm:cast(__, nl_impl, {send, {nl, send, 0}})
  ](SM).

push_tolerant_queue(SM, {nl, send, tolerant, Dst, Payload}) ->
  LocalPC = share:get(SM, local_pc),
  Len = byte_size(Payload),
  Src = share:get(SM, local_address),

  Tuple =
  burst_nl_hf:replace([id_local, src, dst, len, payload],
                      [LocalPC, Src, Dst, Len, Payload],
              burst_nl_hf:create_default()),

  Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
  ?TRACE(?ID, "Add to burst queue ~p~n", [Tuple]),

  [burst_nl_hf:increase_local_pc(__, local_pc),
   share:put(__, burst_data_buffer, queue:in(Tuple, Q))
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
      PC_Tuple = burst_nl_hf:replace(id, PC, Tuple),
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
    [Src, Dst, Payload] = burst_nl_hf:getv([src, dst, payload], Tuple),
    if Dst == Local_address ->
      %TODO: send ack
      [fsm:cast(__, nl_impl, {send, {nl, recv, Src, Dst, Payload}}),
       fsm:set_event(__, eps)
      ](SM);
    true ->
      Q = share:get(SM, nothing, burst_data_buffer, queue:new()),
      ?TRACE(?ID, "Add to burst queue ~p~n", [Tuple]),
      %TODO: Check whole len: pick or recv_data
      [burst_nl_hf:increase_local_pc(__, local_pc),
       share:put(__, burst_data_buffer, queue:in(Tuple, Q)),
       fsm:set_event(__, pick)
      ](SM)
    end
  catch error: Reason ->
    % Got a message not for NL, no NL header
    ?ERROR(?ID, "~p ~p ~p~n", [?ID, ?LINE, Reason]),
    fsm:set_event(SM, eps)
  end.
