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
-export([handle_idle/3, handle_init_roles/3, handle_ready_nl/3, handle_alarm/3, handle_final/3]).

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
                 []},

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
  io:format("++  state ~p Ev ~p term ~p~n", [SM#sm.state, SM#sm.event,  Term]),
  case Term of
    {timeout, {get_protocol, _}} ->
        Protocols = share:get(SM, protocol_roles),
        SM1 = init_nl_protocols(SM, Protocols),
        fsm:run_event(MM, SM1, {});
    {timeout, Event} ->
        fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
        SM;
    {rcv_ul, discovery} ->
        start_discovery(SM),
        SM;
    {rcv_ul, {set, protocol, Protocol}} ->
        % clear everything and set current protocol
        set_protocol(SM, Protocol);
    {rcv_ul, NLCommand} ->
        io:format("++  ~p~n", [NLCommand]),
        process_ul_command(SM, NLCommand);
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
    {rcv_ll, Tuple} ->
        Role = share:get(SM, main_role),
        cast(Role, {send, Tuple}),
        SM;
    {rcv_ll, _AProtocolID, Tuple} ->
        Role = share:get(SM, main_role),
        cast(Role, {send, Tuple}),
        SM;
    {nl, error} ->
        Role = share:get(SM, main_role),
        cast(Role, {send, Term}),
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
    io:format("!!!!!!!!!!!!!!!!!!!!  start_discovery ~n", []),
    SM.

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