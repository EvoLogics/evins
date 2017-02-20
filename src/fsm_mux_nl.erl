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
                 [{discovery_perod, discovery},
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

%%--------------------------------Handler Event----------------------------------
handle_event(MM, SM, Term) ->
  ?INFO(?ID, "HANDLE EVENT~n", []),
  ?TRACE(?ID, "state ~p ev ~p term ~p~n", [SM#sm.state, SM#sm.state, Term]),
  Main_role = share:get(SM, main_role),
  State = SM#sm.state,
  Waiting_neighbours = share:get(SM, waiting_neighbours),
  Setting_routing = share:get(SM, setting_routing),
  Waiting_sync = share:get(SM, waiting_sync),
  %io:format("++  state ~p Ev ~p term ~p~n", [SM#sm.state, SM#sm.event,  Term]),
  case Term of
    {timeout, discovery_perod_tmo} ->
        Discovery_perod = share:get(SM, discovery_perod),
        get_routing(SM),
        SM1 = fsm:set_timeout(SM, {s, Discovery_perod}, discovery_perod_tmo),
        fsm:run_event(MM, SM1#sm{event = discovery_perod}, {});
    {timeout, discovery_end_tmo} ->
        % get neighbours
        get_neighbours(SM),
        SM1 = fsm:clear_timeout(SM, discovery_perod_tmo),
        fsm:run_event(MM, SM1#sm{event = discovery_end}, {});
    {timeout, {get_protocol, _}} ->
        Protocols = share:get(SM, protocol_roles),
        SM1 = init_nl_protocols(SM, Protocols),
        fsm:run_event(MM, SM1, {});
    {timeout, Event} ->
        fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
        SM;
    {rcv_ul, {get, configured, protocols}} ->
        ConfPr = share:get(SM, configured_protocols),
        ListPs = [  atom_to_list(NamePr) || {NamePr, _, _} <- ConfPr],
        BinP = list_to_binary(lists:join(",", ListPs)),
        cast(Main_role, {send, {nl, confprotocols, BinP}}),
        SM;
    {rcv_ul, discovery} when State =:= ready_nl->
        cast(Main_role, {send, {nl, ok}}),
        SM1 = start_discovery(SM),
        fsm:run_event(MM, SM1#sm{event = discovery_start}, {});
    {rcv_ul, {set, protocol, Protocol}} when State =/= discovery ->
        % clear everything and set current protocol
        set_protocol(SM, Protocol);
    {rcv_ul, <<"\n">>} ->
        cast(Main_role, {send, {nl, error} }),
        SM;
    {rcv_ul, {help, NLCommand}} ->
        ConfPr = share:get(SM, configured_protocols),
        if ConfPr =/= [] ->
            {_, TmpRole, _} = lists:last(ConfPr),
            cast(Main_role, {send, list_to_binary(get_mux_commands())}),
            cast(TmpRole, {send, NLCommand});
        true ->
            cast(Main_role, {send, {nl, error}})
        end,
        SM;
    {rcv_ul, NLCommand} when State =/= discovery ->
        process_ul_command(SM, NLCommand);
    {rcv_ul, _} ->
        cast(Main_role, {send, {nl, busy}}),
        SM;
    {rcv_ll, {delivered, L}} ->
        cast(Main_role, {send, L}),
        SM;
    {rcv_ll, {failed, L}} ->
        cast(Main_role, {send, L}),
        SM;
    {rcv_ll, {routing, L}} when State == discovery ->
        cast(Main_role, {send, L}),
        fsm:run_event(MM, SM#sm{event = set_routing}, {});
    {rcv_ll, {routing, _L}} when Waiting_neighbours ->
        share:put(SM, waiting_neighbours, false),
        SM;
    {rcv_ll, {routing, L}} ->
        cast(Main_role, {send, L}),
        SM;

    {rcv_ll, {neighbours, _, NL}} when Waiting_neighbours;
                                       State == discovery ->
        % set protocol static
        % set routing
        set_routing(SM, NL),
        SM;
    {rcv_ll, {neighbours, L, _}} ->
        cast(Main_role, {send, L}),
        SM;
    {rcv_ll, {nl, protocol, NPA}} when SM#sm.state == init_roles ->
        Protocol = nl_mac_hf:get_params_spec_timeout(SM, get_protocol),
        ConfProtocols = share:get(SM, configured_protocols),
        case Protocol of
            [] -> SM;
            [{Role, RoleID, NQ}] ->
                share:put(SM, NPA, {RoleID, Role} ),
                share:put(SM, protocol_roles, NQ ),
                share:put(SM, configured_protocols, [ {NPA, RoleID, Role} | ConfProtocols]),
                SM1 = nl_mac_hf:clear_spec_timeout(SM, get_protocol),
                SM2 = init_nl_protocols(SM1, NQ),
                fsm:run_event(MM, SM2, {})
        end;

    {rcv_ll, {recv, Dst, Data, _Tuple}} when Dst == 255,
                                            Data == <<"D">> ->
        share:put(SM, waiting_neighbours, true),
        get_neighbours(SM),
        SM;
    {rcv_ll, {recv, _Dst, _Data, Tuple}} ->
        cast(Main_role, {send, Tuple}),
        SM;
    {rcv_ll, {sync, _Tuple}} when Setting_routing =/= false ->
        {true, LNeighbours} = share:get(SM, setting_routing),
        NLBin = neighbours_to_bin(LNeighbours),
        set_neighbours(SM, NLBin),
        share:put(SM, setting_routing, false),
        share:put(SM, waiting_sync, true),
        SM;
    {rcv_ll, {sync, Tuple}} when State =/= discovery,
                                 Waiting_neighbours == false,
                                 Waiting_sync == false ->
        cast(Main_role, {send, Tuple}),
        SM;
    {rcv_ll, Tuple} when State =/= discovery,
                         Waiting_neighbours == false,
                         Waiting_sync == false ->
        cast(Main_role, {send, Tuple}),
        SM;
    {rcv_ll, _} ->
        share:put(SM, waiting_sync, false),
        SM;
    {rcv_ll, _AProtocolID, Tuple} when State =/= discovery,
                                       Waiting_neighbours == false ->
        cast(Main_role, {send, Tuple}),
        SM;
    {nl, error} when State =/= discovery,
                     Waiting_neighbours == false ->
        cast(Main_role, {send, Term}),
        SM;
    UUg ->
        ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
        SM
  end.

%%--------------------------------Handler functions-------------------------------
handle_idle(_MM, SM, Term) ->
    ?TRACE(?ID, "~120p~n", [Term]),
    case SM#sm.event of
        internal ->
            % we do not use the first role, it opens only ports to work with other roles 
            [{_, RoleID , _, _, []} | RolesDiffProtocols] = SM#sm.roles,
            Protocols = queue:from_list(RolesDiffProtocols),
            share:put(SM, main_role, RoleID),
            share:put(SM, protocol_roles, Protocols),
            share:put(SM, configured_protocols, []),
            share:put(SM, waiting_neighbours, false),
            share:put(SM, setting_routing, false),
            share:put(SM, waiting_sync, false),
            SM1 = init_nl_protocols(SM, Protocols),
            SM1#sm{event = init};
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
    Role = share:get(SM, main_role),
    case share:get(SM, Protocol) of
        nothing ->
            % this protocol is not configured yet
            cast(Role, {send, {nl, error, noprotocol} }),
            SM;
        _ ->
            cast(Role, {send, {nl, ok} }),
            share:put(SM, current_protocol, Protocol),
            fsm:clear_timeouts(SM)
    end.

process_ul_command(SM, NLCommand) ->
    Role = share:get(SM, main_role),
    CurrProtocol = share:get(SM, current_protocol),
    ConfProtocol = share:get(SM, CurrProtocol),
    Protocol_configured = (CurrProtocol =/= nothing) and (ConfProtocol =/= nothing),
    case Protocol_configured of
        true ->
            %T = list_to_tuple([nl | tuple_to_list(NLCommand)]),
            {RoleProtocol, _} = ConfProtocol,
            cast(RoleProtocol, {send, NLCommand} );
        false ->
            cast(Role, {send, {nl, error, noprotocol} })
    end,
    SM.

start_discovery(SM) ->
    Time_discovery  = share:get(SM, time_discovery),
    Discovery_perod = share:get(SM, discovery_perod),
    get_routing(SM),
    SM1 = fsm:set_timeout(SM, {s, Time_discovery }, discovery_end_tmo),
    fsm:set_timeout(SM1, {s, Discovery_perod}, discovery_perod_tmo).



get_routing(SM) ->
    Discovery_protocol = share:get(SM, discovery_protocol),
    ConfProtocol = share:get(SM, Discovery_protocol),
    Protocol_configured = (ConfProtocol =/= nothing) and (Discovery_protocol =/= nothing),
    case Protocol_configured of
        true ->
            CurrProtocol = share:get(SM, current_protocol),
            share:put(SM, current_protocol, Discovery_protocol),
            {SncfloodrRole, _} = share:get(SM, Discovery_protocol),
            Tuple = {nl, send, 1, 255, <<"D">> },
            cast(SncfloodrRole, {send, Tuple}),
            share:put(SM, current_protocol, CurrProtocol);
        _ ->
            ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
            SM
    end.

set_routing(SM, empty) ->
    Burst_protocol = share:get(SM, burst_protocol),
    ConfProtocol = share:get(SM, Burst_protocol),
    Protocol_configured = (ConfProtocol =/= nothing) and (Burst_protocol =/= nothing),
    case Protocol_configured of
        true ->
            CurrProtocol = share:get(SM, current_protocol),
            share:put(SM, current_protocol, Burst_protocol),
            {StaticrRole, _} = share:get(SM, Burst_protocol),
            cast(StaticrRole, {send, {nl, get, routing}}),
            share:put(SM, current_protocol, CurrProtocol);
        _ ->
            ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
            SM
    end;
set_routing(SM, NL) ->
    Burst_protocol = share:get(SM, burst_protocol),
    ConfProtocol = share:get(SM, Burst_protocol),
    Protocol_configured = (ConfProtocol =/= nothing) and (Burst_protocol =/= nothing),
    case Protocol_configured of
        true ->
            CurrProtocol = share:get(SM, current_protocol),
            share:put(SM, current_protocol, Burst_protocol),
            {StaticrRole, _} = share:get(SM, Burst_protocol),

            Routing_table = lists:map(fun( {A, _I, _R, _T} ) -> {A, A} end, NL),
            RoutingBin = routing_to_bin(Routing_table),
            Tuple = {nl, set, routing, RoutingBin},
            share:put(SM, setting_routing, {true, NL}),
            cast(StaticrRole, {send, Tuple}),
            cast(StaticrRole, {send, {nl, get, routing}}),
            share:put(SM, current_protocol, CurrProtocol);
        _ ->
            ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
            SM
    end.

set_neighbours(SM, empty) ->
    SM;
set_neighbours(SM, NLBin) ->
    Burst_protocol = share:get(SM, burst_protocol),
    ConfProtocol = share:get(SM, Burst_protocol),
    Protocol_configured = (ConfProtocol =/= nothing) and (Burst_protocol =/= nothing),
    case Protocol_configured of
        true ->
            CurrProtocol = share:get(SM, current_protocol),
            share:put(SM, current_protocol, Burst_protocol),
            {StaticrRole, _} = share:get(SM, Burst_protocol),
            Tuple = {nl, set, neighbours, NLBin},
            cast(StaticrRole, {send, Tuple}),
            share:put(SM, current_protocol, CurrProtocol);
        _ ->
            ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
            SM
    end.

get_neighbours(SM) ->
    Discovery_protocol = share:get(SM, discovery_protocol),
    ConfProtocol = share:get(SM, Discovery_protocol),
    Protocol_configured = (ConfProtocol =/= nothing) and (Discovery_protocol =/= nothing),
    case Protocol_configured of
        true ->
            CurrProtocol = share:get(SM, current_protocol),
            {SncfloodrRole, _} = share:get(SM, Discovery_protocol),
            Tuple = {nl, get, neighbours },
            cast(SncfloodrRole, {send, Tuple}),
            share:put(SM, current_protocol, CurrProtocol);
        _ ->
            ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
            SM
    end.

init_nl_protocols(SM, nothing) ->
    SM#sm{event = eps};
init_nl_protocols(SM, {[],[]}) ->
    SM#sm{event = ready};
init_nl_protocols(SM, Protocols) ->
    {{value, {Role, RoleID , _, _, []}}, NQ } = queue:out(Protocols),
    cast(RoleID, {send, {nl, get, protocol} }),
    fsm:set_timeout(SM#sm{event = eps}, {s, 1}, {get_protocol, {Role, RoleID, NQ} }).

cast(RoleID, Message) ->
    gen_server:cast(RoleID, {self(), Message}).

routing_to_bin(Routing_table) ->
    Path = lists:map(fun({From, To}) ->
        [integer_to_binary(From),"->",integer_to_binary(To)]
    end, Routing_table),
    list_to_binary(lists:join(",", Path)).

get_mux_commands() ->
    ["=========================================== MUX commands ===========================================\n",
    "NL,discovery\t\t\t\t\t- Run discovery\n",
    "NL,get,protocols,configured\t\t\t- Get list of currently configured protocolsfor MUX\n\n",
    "=========================================== Sync MUX responses =====================================\n",
    "NL,error,norouting\t\t\t\t- Sync error message, if no routing to dst exists (Static routing)\n",
    "NL,error,noprotocol\t\t\t\t- Sync error message, if no protocol specified\n",
    "\n\n\n"].

neighbours_to_bin(NL) ->
  F = fun(X) ->
      case X of
        {Addr, Rssi, Integrity, Time} ->
          Baddr = nl_mac_hf:convert_type_to_bin(Addr),
          Brssi = nl_mac_hf:convert_type_to_bin(Rssi),
          Bintegrity = nl_mac_hf:convert_type_to_bin(Integrity),
          BTime = nl_mac_hf:convert_type_to_bin(Time),
          list_to_binary([Baddr, ":", Brssi, ":", Bintegrity, ":", BTime]);
        Addr ->
          Baddr = nl_mac_hf:convert_type_to_bin(Addr),
          list_to_binary([Baddr])
      end
  end,

  list_to_binary(lists:join(",", [F(X) || X <- NL])).