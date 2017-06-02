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
-include("sensor.hrl").

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
  Waiting_neighbours = share:get(SM, waiting_neighbours),
  Discovery_period_tmo = fsm:check_timeout(SM, discovery_perod_tmo),
  %% Stop_polling = share:get(SM, stop_polling),
  case Term of
    {timeout, discovery_period_tmo} ->
      Discovery_period = share:get(SM, discovery_period),
      get_routing(SM),
      [
       fsm:set_timeout(__, {s, Discovery_period}, discovery_period_tmo),
       fsm:set_event(__, discovery_period),
       fsm:run_event(MM, __, {})
      ] (SM);
    {timeout, discovery_end_tmo} ->
      %% get neighbours
      [
       get_neighbours(__),
       fsm:clear_timeout(__, discovery_period_tmo),
       fsm:set_event(__, discovery_end),
       fsm:run_event(MM, __, {})
      ] (SM);
    {timeout, {get_protocol, Some_MM}} ->
      [
       fsm:set_timeout(__, {s, 1}, {get_protocol, Some_MM}),
       fsm:cast(__, Some_MM, [], {send, {nl, get, protocol}}, ?TO_MM)
      ] (SM);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      case MM#mm.role of
        nl ->
          [
           fsm:set_timeout(__, {s, 1}, {get_protocol, MM}),
           fsm:cast(__, MM, [], {send, {nl, get, protocol}}, ?TO_MM)
          ] (SM);
        _ ->
          SM
      end;
    {disconnected, _} ->
      %% TODO: handle: remove from configure protocols and change state to init_roles?
      SM;
    {nl, stop, discovery} ->
      fsm:cast(SM, nl_impl, {send, {nl, discovery, ok}}),
      fsm:clear_timeouts(SM#sm{state = ready_nl});
    {nl, get, version} ->
      Discovery_protocol = share:get(SM, discovery_protocol),
      ProtocolMM = share:get(SM, Discovery_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, Term}, ?TO_MM);
    {nl, get, discovery} ->
      Period = share:get(SM, discovery_period),
      Time = share:get(SM, time_discovery),
      TupleDiscovery = {nl, discovery, Period, Time},
      fsm:cast(SM,nl_impl, {send, TupleDiscovery});
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
      NL = share:get(SM, nothing, neighbours, []),
      Routing_table = lists:map(fun( {A, _I, _R, _T} ) -> {A, A} end, NL),
      Tuple = {nl, routing, Routing_table},
      fsm:cast(SM, nl_impl, {send, Tuple});
    {nl, get, neighbours} ->
      Tuple = {nl, neighbours, share:get(SM, nothing, neighbours, empty)},
      fsm:cast(SM, nl_impl, {send, Tuple});
    {nl, start, discovery, _, _} when Discovery_period_tmo =:= true->
      fsm:cast(SM, nl_impl, {send, {nl, discovery, busy}});
    {nl, start, discovery, Discovery_period, Time_discovery} when State =:= ready_nl ->
      share:put(SM, [{time_discovery,  Time_discovery},
                     {discovery_period, Discovery_period}]),
      fsm:cast(SM, nl_impl, {send, {nl, discovery, ok}}),
      [
       start_discovery(__),
       fsm:set_event(__, discovery_start),
       fsm:run_event(MM, __, {})
      ] (SM);
    {nl, set, protocol, Protocol} when State =/= discovery ->
      %% clear everything and set current protocol
      set_protocol(SM, Protocol);
    %% {rcv_ul, <<"\n">>} ->
    %%   fsm:cast(nl_impl, {send, {answer, {nl, error}} });
    %% {help, NLCommand} ->
    %%   ConfPr = share:get(SM, configured_protocols),
    %%   if ConfPr =/= [] ->
    %%       {_, TmpRole, _} = lists:last(ConfPr),
    %%       fsm:cast(SM, nl_impl, {send, list_to_binary(get_mux_commands())}),
    %%       fsm:cast(SM, TmpRole, {send, NLCommand});
    %%      true ->
    %%       fsm:cast(SM, nl_impl, {send, {answer, {nl, error}}} )
    %%   end;
    
    {nl, delivered, _, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, failed, _, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    %% {nl, routing, _} when State == discovery ->
    %%   fsm:cast(SM, nl_impl, {send, Term}),
    %%   fsm:run_event(MM, SM#sm{event = set_routing}, {});
    {nl, routing, _} when Waiting_neighbours ->
      share:put(SM, waiting_neighbours, false);
    {nl, routing, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, neighbours, NL} when Waiting_neighbours;
                              State == discovery ->
      %% set protocol static
      %% set routing
      set_routing(SM, NL),
      fsm:run_event(MM, SM#sm{event = set_routing}, {});
    {nl, neighbours, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, version, Major, Minor, Description} ->
      fsm:cast(SM, nl_impl, {send, {nl, version, Major, Minor, "mux:" ++ Description}});
    {nl, protocol, NPA} when SM#sm.state == init_roles ->
      %% bind MM with protocol here
      %% NOTE: protocol must be unique per MM
      NLRoles = [Role || {nl,_,_,_,_} = Role <- SM#sm.roles],
      Configured_protocols = share:get(SM, configured_protocols),
      Event = case length(NLRoles) of
                NLCount when NLCount == (length(Configured_protocols) + 1) -> ready;
                _ -> eps
              end,
      [
       share:put(__, NPA, MM),
       share:update_with(__, configured_protocols, fun(Lst) -> [NPA|Lst] end),
       fsm:clear_timeout(__, {get_protocol, MM}),
       fsm:set_event(__, Event),
       fsm:run_event(MM, __, {})
      ] (SM);
    {nl, recv, _Src, Dst, Data, _Tuple} when Dst == 255,
                                        Data == <<"D">> ->
      share:put(SM, waiting_neighbours, true),
      get_neighbours(SM);
    {nl, send, alarm, _Src, Data} ->
        stop_polling(SM, Data);
    {recv, Src, Dst, Data, Tuple} ->
        NTuple =
          case Data of
            <<"A", DataT/binary>> ->
              {nl, recv, Src, Dst, DataT};
            _ ->
              Tuple
          end,
        fsm:cast(SM, nl_impl, {send, NTuple});
    %% ??? NOTE: what is the reason to update neighbours on each incoming sync telegram
    %% {rcv_ll, {sync, _Tuple}} when Stop_polling == true ->
    %%     Data = share:get(SM, polling_data),
    %%     share:put(SM, stop_polling, false),
    %%     send_alarm_msg(SM, Data),
    %%     fsm:clear_timeouts(SM#sm{state = ready_nl});
    {nl, error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    _ when MM#mm.role == nl_impl, State =/= discovery ->
      process_ul_command(SM, Term);
    _ when MM#mm.role == nl_impl ->
      %% TODO: add Subject to busy report
      fsm:cast(SM, nl_impl, {send, {nl, busy}});
    _ when MM#mm.role == nl, State =/= discovery,
           Waiting_neighbours == false ->
           %% Waiting_sync == false ->
      fsm:cast(SM, nl_impl, {send, Term});
    %% {rcv_ll, _} ->
    %%   share:put(SM, waiting_sync, false);
    %% {rcv_ll, _AProtocolID, Tuple} when State =/= discovery,
    %%                                    Waiting_neighbours == false ->
    %%   fsm:cast(nl_impl, {send, Tuple});
    %% {nl, error} when State =/= discovery,
    %%                  Waiting_neighbours == false ->
    %%   fsm:cast(nl_impl, {send, Term});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

%%--------------------------------Handler functions-------------------------------
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case SM#sm.event of
    internal ->
      %% NLRoles = [Role || {nl,_,_,_,_} = Role <- SM#sm.roles],
      %% Protocols = queue:from_list(NLRoles),
      %% share:put(SM, protocol_roles, Protocols),
      share:put(SM, configured_protocols, []),
      share:put(SM, waiting_neighbours, false),
      %% share:put(SM, setting_routing, false),
      %% share:put(SM, waiting_sync, false),
      %% SM1 = init_nl_protocols(SM, Protocols),
      SM#sm{event = init};
    _  ->
      SM#sm{event = eps}
  end.

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
set_protocol(SM, Protocol) ->
  case share:get(SM, Protocol) of
    nothing ->
      %% this protocol is not configured yet
      fsm:cast(SM, nl_impl, {send, {nl, protocol, error}}),
      SM;
    _ ->
      fsm:cast(SM, nl_impl, {send, {nl, protocol, ok}}),
      share:put(SM, current_protocol, Protocol),
      fsm:clear_timeouts(SM)
  end.

process_ul_command(SM, NLCommand) ->
  CurrProtocol = share:get(SM, current_protocol),
  ProtocolMM = share:get(SM, CurrProtocol),
  case {ProtocolMM, share:get(SM, configured_protocols)} of
    {nothing, nothing} ->
      fsm:cast(SM, nl_impl, {send, {nl, error, noprotocol}});
    {nothing, Protocols} ->
      share:put(SM, current_protocol, hd(Protocols)),
      MM = share:get(SM, hd(Protocols)),
      fsm:cast(SM, MM, [], {send, NLCommand}, ?TO_MM);
    _ ->
      fsm:cast(SM, ProtocolMM, [], {send, NLCommand}, ?TO_MM)
  end.

stop_polling(SM, Data) ->
    Burst_protocol = share:get(SM, burst_protocol),
    ProtocolMM = share:get(SM, Burst_protocol),
    case ProtocolMM of
      nothing ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
        SM;
      _ ->
        Tuple = {nl, set, polling, stop},
        fsm:cast(SM, ProtocolMM, [], {send, Tuple}, ?TO_MM),
        share:put(SM, stop_polling, true),
        share:put(SM, polling_data, Data)
    end.

start_discovery(SM) ->
  Time_discovery  = share:get(SM, time_discovery),
  Discovery_period = share:get(SM, discovery_period),
  get_routing(SM),
  [
   fsm:set_timeout(__, {s, Time_discovery }, discovery_end_tmo),
   fsm:set_timeout(__, {s, Discovery_period}, discovery_period_tmo)
  ] (SM).

get_routing(SM) ->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  case ProtocolMM of
    nothing ->
      ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
      SM;
    _ ->
      Tuple = {nl, send, 255, <<"D">> },
      fsm:cast(SM, ProtocolMM, [], {send, Tuple}, ?TO_MM)
  end.

set_routing(SM, empty) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  case ProtocolMM of
    nothing ->
      ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
      SM;
    _ ->
      fsm:cast(SM, ProtocolMM, [], {send, {nl, get, routing}}, ?TO_MM)
  end;
set_routing(SM, NL) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  case ProtocolMM of
    nothing ->
      ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
      SM;
    _ ->
      Routing_table = lists:map(fun( {A, _I, _R, _T} ) -> {A, A} end, NL),
      %% Tuple = {nl, set, routing, Routing_table},
      %% share:put(SM, setting_routing, {true, NL}),
      share:put(SM, neighbours, NL),
      fsm:cast(SM, nl_impl, {send, {nl, routing, Routing_table}})
      %% fsm:cast(SM, ProtocolMM, [], {send, {nl, get, routing}}, ?TO_MM)
  end.

%% set_neighbours(SM, empty) ->
%%   SM;
%% set_neighbours(SM, LNeighbours) ->
%%   Burst_protocol = share:get(SM, burst_protocol),
%%   ProtocolMM = share:get(SM, Burst_protocol),
%%   case ProtocolMM of
%%     nothing ->
%%       ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
%%       SM;
%%     _ ->
%%       Tuple = {nl, set, neighbours, LNeighbours},
%%       fsm:cast(SM, ProtocolMM, [], {send, Tuple}, ?TO_MM)
%%   end.

get_neighbours(SM) ->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  case ProtocolMM of
    nothing ->
      ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
      SM;
    _ ->
      Tuple = {nl, get, neighbours},
      fsm:cast(SM, ProtocolMM, [], {send, Tuple}, ?TO_MM)
  end.

%% send_alarm_msg(SM, Data) ->
%%   Discovery_protocol = share:get(SM, discovery_protocol),
%%   ProtocolMM = share:get(SM, Discovery_protocol),
%%   case ProtocolMM of
%%     nothing ->
%%       ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
%%       SM;
%%     _ ->
%%       Tuple = {nl, send, 255, <<"A",Data/binary>>},
%%       fsm:cast(SM, ProtocolMM, [], {send, Tuple}, ?TO_MM)
%%   end.

%% get_mux_commands() ->
%%   ["=========================================== MUX commands ===========================================\r\n",
%%    "NL,discovery,<Discovery_period>,<Time_discovery>\t- Run discovery, Time_discovery - whole discovery time in s,
%%                                                     \t\t\tDiscovery_period - time for one discovery try in s
%%                                                     \t\t\tTime_discovery / Discovery_period = Retry_count\r\n",
%%    "NL,discovery,stop\t\t\t\t\t- Stop discovery\r\n\r\n"
%%    "NL,get,protocols,configured\t\t\t\t- Get list of currently configured protocolsfor MUX\r\n\r\n",
%%    "NL,get,discovery,period\t\t\t\t\t- Time for one discovery try in s\r\n\r\n",
%%    "NL,get,discovery,time\t\t\t\t\t- Whole discovery time in s\r\n\r\n",
%%    "=========================================== Sync MUX responses =====================================\r\n",
%%    "NL,error,norouting\t\t\t\t- Sync error message, if no routing to dst exists (Static routing)\r\n",
%%    "NL,error,noprotocol\t\t\t\t- Sync error message, if no protocol specified\r\n",
%%    "\r\n\r\n\r\n"].
