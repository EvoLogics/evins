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
-module(fsm_mux_nl).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3, handle_alarm/3, handle_final/3]).
-export([handle_init_roles/3, handle_ready_nl/3, handle_discovery/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                 {init, init_roles}
                 ]},

                {init_roles,
                 [
                 {ready, ready_nl}
                 ]},

                {ready_nl,
                 [
                 {set_routing, ready_nl},
                 {discovery_start, discovery}
                 ]},

                {discovery,
                 [{discovery_period, discovery},
                 {discovery_end, discovery},
                 {set_routing, ready_nl}
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

-define(TO_MM, fun(#mm{role_id = ID}, {_,Role_ID,_,_,_}, _) -> ID == Role_ID end).

%%--------------------------------Handler Event----------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT~n", []),
  ?TRACE(?ID, "state ~p ev ~p term ~p~n", [SM#sm.state, SM#sm.event, Term]),

  State = SM#sm.state,
  Discovery_period_tmo = fsm:check_timeout(SM, discovery_perod_tmo),
  Alarm_data = share:get(SM, alarm_data),

  case Term of
    {timeout, reset_state} ->
      Burst_protocol = share:get(SM, burst_protocol),
      ProtocolMM = share:get(SM, Burst_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, {nl, reset, state}}, ?TO_MM);
    {timeout, discovery_period_tmo} ->
      Discovery_period = share:get(SM, discovery_period),
      get_routing(SM),
      [fsm:set_timeout(__, {s, Discovery_period}, discovery_period_tmo),
       fsm:set_event(__, discovery_period),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, discovery_end_tmo} ->
      %% get neighbours
      [get_neighbours(__),
       fsm:clear_timeout(__, discovery_period_tmo),
       fsm:set_event(__, discovery_end),
       fsm:run_event(MM, __, {})
      ](SM);
    {timeout, {get_protocol, Some_MM}} ->
      [fsm:set_timeout(__, {s, 1}, {get_protocol, Some_MM}),
       fsm:cast(__, Some_MM, [], {send, {nl, get, protocol}}, ?TO_MM)
      ](SM);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      case MM#mm.role of
        nl ->
          [fsm:set_timeout(__#sm{state = init_roles}, {s, 1}, {get_protocol, MM}),
           fsm:cast(__, MM, [], {send, {nl, get, protocol}}, ?TO_MM)
          ](SM);
        _ ->
          SM
      end;
    {disconnected, _} ->
      %% TODO: handle: remove from configure protocols and change state to init_roles?
      SM;
      %share:put(SM, configured_protocols, []),
      %fsm:clear_timeouts(SM#sm{state = init_roles});
    {nl, get, buffer} ->
      Discovery_protocol = share:get(SM, current_protocol),
      ProtocolMM = share:get(SM, Discovery_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, Term}, ?TO_MM);
    {nl, reset, state} ->
      Discovery_protocol = share:get(SM, current_protocol),
      ProtocolMM = share:get(SM, Discovery_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, {nl, reset, state}}, ?TO_MM),
      fsm:clear_timeouts(SM#sm{state = ready_nl});
    {nl, stop, discovery} ->
      fsm:cast(SM, nl_impl, {send, {nl, discovery, ok}}),
      fsm:clear_timeouts(SM#sm{state = ready_nl});
    {nl, get, time, monotonic} ->
      Discovery_protocol = share:get(SM, discovery_protocol),
      ProtocolMM = share:get(SM, Discovery_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, Term}, ?TO_MM);
    {nl, get, version} ->
      Discovery_protocol = share:get(SM, discovery_protocol),
      ProtocolMM = share:get(SM, Discovery_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, Term}, ?TO_MM);
    {nl, get, discovery} ->
      Period = share:get(SM, discovery_period),
      Time = share:get(SM, time_discovery),
      TupleDiscovery = {nl, discovery, Period, Time},
      fsm:cast(SM,nl_impl, {send, TupleDiscovery});
    {nl, get, help} ->
      NHelp = string:concat(?MUXHELP, ?HELP),
      fsm:cast(SM, nl_impl, {send, {nl, help, NHelp}});
    {nl, get, protocols} ->
      Tuple = {nl, protocols, share:get(SM, nothing, configured_protocols, [])},
      fsm:cast(SM, nl_impl, {send, Tuple});
    {nl, get, protocolinfo, Some_protocol} ->
      Burst_protocol = share:get(SM, burst_protocol),
      ProtocolMM =
      case Some_protocol of
        Burst_protocol -> share:get(SM, Some_protocol);
        _ -> share:get(SM, share:get(SM, discovery_protocol))
      end,
      fsm:cast(SM, ProtocolMM, [], {send, Term}, ?TO_MM);
    {nl, get, routing} ->
      NL = share:get(SM, nothing, neighbours, empty),
      NL_handler =
      fun (LSM, empty) ->
            fsm:cast(LSM, nl_impl, {send, {nl, routing, empty}});
          (LSM, _) ->
            Routing_table = lists:map(fun( {A, _I, _R, _T} ) -> {A, A} end, NL),
            Tuple = {nl, routing, Routing_table},
            fsm:cast(LSM, nl_impl, {send, Tuple})
      end,
      NL_handler(SM, NL);
    {nl, get, neighbours} when State =/= discovery ->
      get_neighbours(SM);
    {nl, get, neighbours} ->
      Tuple = {nl, neighbours, share:get(SM, nothing, neighbours, empty)},
      fsm:cast(SM, nl_impl, {send, Tuple});
    {nl, start, discovery, _, _} when Discovery_period_tmo =:= true->
      fsm:cast(SM, nl_impl, {send, {nl, discovery, busy}});
    {nl, start, discovery, Discovery_period, Time_discovery} when Discovery_period =< 0;
                                                                  Time_discovery =< 0 ->
      fsm:cast(SM, nl_impl, {send, {nl, discovery, error}});
    {nl, start, discovery, Discovery_period, Time_discovery} when State =:= ready_nl ->
      share:put(SM, [{time_discovery,  Time_discovery},
                     {discovery_period, Discovery_period}]),
      share:put(SM, neighbours, empty),
      fsm:cast(SM, nl_impl, {send, {nl, discovery, ok}}),
      [stop_polling(__, empty),
       start_discovery(__),
       fsm:set_event(__, discovery_start),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl,neighbour,ok} ->
      fsm:cast(SM, nl_impl, {send, Term}),
      get_neighbours(SM);
    {nl, set, protocol, Protocol} when State =/= discovery ->
      %% clear everything and set current protocol
      set_protocol(SM, MM#mm.role, Protocol);
    {nl, delivered, _, _, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, failed, _, _, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, routing, _} when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, neighbours, NL} when State == discovery, is_list(NL), MM#mm.role == nl ->
      %% set protocol static
      %% set routing
      set_routing(SM, NL);
    {nl, neighbours, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, time, monotonic, Time} ->
      fsm:cast(SM, nl_impl, {send, {nl, time, monotonic, Time}});
    {nl, version, Major, Minor, Description} ->
      fsm:cast(SM, nl_impl, {send, {nl, version, Major, Minor, "mux:" ++ Description}});
    {nl, protocol, NPA} when SM#sm.state == init_roles ->
      %% bind MM with protocol here
      %% NOTE: protocol must be unique per MM
      Current_protocol = share:get(SM, current_protocol),
      if Current_protocol == nothing ->
        share:put(SM, current_protocol, NPA);
        true -> nothing
      end,
      NLRoles = [Role || {nl,_,_,_,_} = Role <- SM#sm.roles],
      Configured_protocols = share:get(SM, configured_protocols),
      Event = case length(NLRoles) of
                NLCount when NLCount == (length(Configured_protocols) + 1);
                             NLCount == length(Configured_protocols) -> ready;
                _ -> eps
              end,
      NL =
      case lists:member(NPA, Configured_protocols) of
        true -> Configured_protocols;
        false -> [NPA|Configured_protocols]
      end,
      [
       share:put(__, NPA, MM),
       share:put(__, configured_protocols, NL),
       fsm:clear_timeout(__, {get_protocol, MM}),
       fsm:set_event(__, Event),
       fsm:run_event(MM, __, {})
      ] (SM);
    {nl, state, ok} when MM#mm.role == nl,
                         Alarm_data =/= nothing ->
      send_alarm_msg(SM, Alarm_data),
      fsm:clear_timeouts(SM#sm{state = ready_nl});
    {nl, polling, PL} when is_list(PL), State == discovery ->
      set_protocol(SM, MM#mm.role, polling),
      fsm:run_event(MM, SM#sm{event = set_routing}, {});
    {nl, send, alarm, _Src, Data} ->
      %TODO: we do not need a Src in alarm messages, it will be broadcasted
      stop_polling(SM, Data);
    {nl, recv, _Src, ?ADDRESS_MAX, <<"D">>} ->
      SM;
    {nl, recv, Src, Dst, <<"A", DataT/binary>>} ->
      stop_polling(SM, alarm),
      fsm:cast(SM, nl_impl, {send, {nl, recv, Src, Dst, DataT}});
    {nl, recv, _Src, _Dst, _Data} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    _ when MM#mm.role == nl_impl, State =/= discovery ->
      process_ul_command(SM, Term);
    _ when MM#mm.role == nl_impl ->
      %% TODO: add Subject to busy report
      fsm:cast(SM, nl_impl, {send, {nl, busy}});
    _ when MM#mm.role == nl, State =/= discovery ->
      fsm:cast(SM, nl_impl, {send, Term});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p from ~p~n", [?MODULE, UUg, MM#mm.role]),
      SM
  end.

%%--------------------------------Handler functions-------------------------------
handle_idle(_MM, #sm{event = internal} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  [share:put(__, configured_protocols, []),
   fsm:set_event(__, init)
  ](SM);
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_init_roles(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_ready_nl(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_discovery(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
    ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------Helper functions-------------------------------
set_protocol(SM, Role, Protocol) ->
  ProtocolMM = share:get(SM, Protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        fsm:cast(LSM, nl_impl, {send, {nl, protocol, error}});
      (LSM, _) when Role == nl ->
        [share:put(__, current_protocol, Protocol),
         fsm:clear_timeouts(__)
        ](LSM);
      (LSM, _) ->
        [fsm:cast(__, nl_impl, {send, {nl, protocol, Protocol}}),
         share:put(__, current_protocol, Protocol),
         fsm:clear_timeouts(__)
        ](LSM)
  end,
  Protocol_handler(SM, ProtocolMM).

process_ul_command(SM, NLCommand) ->
  Discovery_protocol = share:get(SM, current_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        fsm:cast(LSM, nl_impl, {send, {nl, error, noprotocol}});
      (LSM, _) ->
        fsm:cast(LSM, ProtocolMM, [], {send, NLCommand}, ?TO_MM)
  end,
  Protocol_handler(SM, ProtocolMM).

stop_polling(SM, Data) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  case ProtocolMM of
    nothing ->
      ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
      SM;
    _ when Data == empty ->
      Tuple = {nl, stop, polling},
      fsm:cast(SM, ProtocolMM, [], {send, Tuple}, ?TO_MM);
    _ ->
      Tuple = {nl, stop, polling},
      [share:put(__, alarm_data, Data),
       fsm:cast(__, ProtocolMM, [], {send, Tuple}, ?TO_MM),
       fsm:set_timeout(__, {s, 1}, reset_state)
      ](SM)
  end.

start_discovery(SM) ->
  Time_discovery  = share:get(SM, time_discovery),
  Discovery_period = share:get(SM, discovery_period),
  [get_routing(__),
   fsm:set_timeout(__, {s, Time_discovery }, discovery_end_tmo),
   fsm:set_timeout(__, {s, Discovery_period}, discovery_period_tmo)
  ](SM).

get_routing(SM) ->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
        LSM;
      (LSM, _) ->
        Tuple = {nl, send, ?ADDRESS_MAX, <<"D">> },
        fsm:cast(LSM, ProtocolMM, [], {send, Tuple}, ?TO_MM)
  end,
  Protocol_handler(SM, ProtocolMM).

set_routing(SM, []) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
        LSM;
      (LSM, _) ->
        [fsm:cast(__, nl_impl, {send, {nl, routing, []}}),
         fsm:clear_timeouts(__#sm{state = ready_nl})
        ](LSM)
  end,
  Protocol_handler(SM, ProtocolMM);
set_routing(SM, empty) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
        LSM;
      (LSM, _) ->
        [fsm:cast(__, nl_impl, {send, {nl, routing, []}}),
         fsm:clear_timeouts(__#sm{state = ready_nl})
        ](LSM)
  end,
  Protocol_handler(SM, ProtocolMM);
set_routing(SM, [H|_] = NL) when is_number(H) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  Routing_table = [ {X, X} ||  X <- NL],
  share:put(SM, neighbours, NL),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
        LSM;
      (LSM, _) when LSM#sm.state == discovery ->
        [fsm:cast(__, ProtocolMM, [], {send, {nl, set, polling, NL}}, ?TO_MM),
         fsm:cast(__, nl_impl, {send, {nl, routing, Routing_table}})
        ](LSM);
      (LSM, _) -> LSM
  end,
  Protocol_handler(SM, ProtocolMM);
set_routing(SM, NL) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  Routing_table = lists:map(fun( {A, _I, _R, _T} ) -> {A, A} end, NL),
  Neighbours    = lists:map(fun( {A, _I, _R, _T} ) -> A end, NL),
  share:put(SM, neighbours, NL),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
        LSM;
      (LSM, _) when LSM#sm.state == discovery ->
        [fsm:cast(__, ProtocolMM, [], {send, {nl, set, polling, Neighbours}}, ?TO_MM),
         fsm:cast(__, nl_impl, {send, {nl, routing, Routing_table}})
        ](LSM);
      (LSM, _) -> LSM
  end,
  Protocol_handler(SM, ProtocolMM).

get_neighbours(SM) ->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
        LSM;
      (LSM, _) ->
        Tuple = {nl, get, neighbours},
        fsm:cast(LSM, ProtocolMM, [], {send, Tuple}, ?TO_MM)
  end,
  Protocol_handler(SM, ProtocolMM).

send_alarm_msg(SM, alarm) ->
  share:clean(SM, alarm_data);
send_alarm_msg(SM, Data) ->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
        LSM;
      (LSM, _) ->
        Tuple = {nl, send, ?ADDRESS_MAX, <<"A",Data/binary>>},
        [share:clean(__, alarm_data),
         fsm:cast(__, ProtocolMM, [], {send, Tuple}, ?TO_MM)
        ](LSM)
  end,
  Protocol_handler(SM, ProtocolMM).
