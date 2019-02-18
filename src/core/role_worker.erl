%% Copyright (c) 2015, Oleksiy Kebkal <lesha@evologics.de>
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
-module(role_worker).

-behaviour(gen_server).

-include("fsm.hrl").

-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-export([start/4, start/5, to_term/4, bridge/2]).

-define(SER_OPEN, 0).
-define(SER_SEND, 1).
-define(SER_RECV, 2).
-define(SER_ERROR, 3).

-callback start(ref(), ref(), #mm{}) -> {ok,pid()} | ignore | {error,any()}.
-callback stop(any()) -> ok.
-callback to_term(Tail :: binary(), Bin :: binary() | list(), Cfg :: any()) -> [list() | [list() | [list() | [binary() | list(any())]]]].
-callback from_term(any(), any()) -> any().
-callback ctrl(any(), any()) -> any().

-record(ifstate, {
          behaviour,            % Calling behaviour module name (for callbacks)
          listener = nothing,   % Listening socket
          acceptor = nothing,   % Asynchronous acceptor's internal reference
          socket = nothing,     % Active TCP Socket
          port = nothing,       % Port reference
          id,                   % Role_ID
          module_id,            % FSM handling module name
          fsm_pids = [],        % FSM controller module PID
          type = client,        % TCP/UDP client or server
          opt = [],             % TCP/UDP Socket options
          proto = nothing,      % tcp | udp -- protocol
          mm,                   % #mm - more info about this interface:
                                % {role,role_id,ip,port,type,status,params}).
          tail = <<>>,          % Not yet processed data tail
          cfg                   % Optional custom behaviour config parameters
         }).

start(Behaviour, Role_ID, Mod_ID, MM) ->
  start(Behaviour, Role_ID, Mod_ID, MM, nothing).

start(Behaviour, Role_ID, Mod_ID, MM, Cfg) ->
  gen_event:notify(error_logger, {fsm_core, self(), {Role_ID, {start, Mod_ID}}}),
  Ret = gen_server:start_link({local, Role_ID}, ?MODULE,
                              #ifstate{behaviour = Behaviour, id = Role_ID, module_id = Mod_ID, mm = MM, cfg = Cfg}, []),
  case Ret of
    {error, Reason} ->  error_logger:error_report({error, Reason, Mod_ID, Role_ID});
    _ -> nothing
  end,
  Ret.

init(#ifstate{id = ID, module_id = Mod_ID, mm = #mm{iface = {cowboy,I,P}}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {init, {cowboy,I,P}}}}),
  process_flag(trap_exit, true),
  Self = self(),
  gen_server:cast(Mod_ID, {Self, ID, ok}),
  {ok, State};    

init(#ifstate{id = ID, module_id = Mod_ID, mm = #mm{iface = {erlang,Target}}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {init, {erlang,Target}}}}),
  process_flag(trap_exit, true),
  Self = self(),
  gen_server:cast(Mod_ID, {Self, ID, ok}),
  {ok, State};

init(#ifstate{id = ID, module_id = Mod_ID, mm = #mm{iface = {port,Port,PortSettings}}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {init, {port,Port,PortSettings}}}}),
  process_flag(trap_exit, true),
  Self = self(),
  gen_server:cast(Mod_ID, {Self, ID, ok}),
  connect(State);

init(#ifstate{id = ID, module_id = Mod_ID, mm = #mm{iface = {serial,Port,BaudRate,StartBits,Parity,StopBits,FlowControl}}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {init, {serial,Port,BaudRate,StartBits,Parity,StopBits,FlowControl}}}}),
  process_flag(trap_exit, true),
  Self = self(),
  gen_server:cast(Mod_ID, {Self, ID, ok}),
  connect(State#ifstate{proto = serial});

init(#ifstate{id = ID, module_id = Mod_ID, mm = #mm{iface = {socket,IP,Port,Opts}}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {init, {socket,IP,Port,Opts}}}}),
  Type = case Opts of
           L when is_list(L) ->
             Tserver = [server || server <- L],
             Tclient = [client || client <- L],
             case {Tserver, Tclient} of
               {[server],[]} -> server;
               {[],[client]} -> client;
               _ ->
                 ?ERROR(ID, "Undefined connection type: ~p, set to client per default~n", [L]),
                 client
             end;
           A -> A
         end,
  Pkt = case Opts of
          L1 when is_list(L1) ->
            case [X || {packet, X} <- L1] of
              [] -> {packet, 0};
              [X] -> {packet, X}
            end;
          _ -> {packet, 0}
        end,
  SOpts = case Type of
            client -> [{keepalive, true}, {send_timeout, 1000}, binary, {active, true}, Pkt];
            server -> [{keepalive, true}, {send_timeout, 1000}, binary, {ip, IP}, {active, true}, {reuseaddr, true}, {backlog, 0}, Pkt]
          end,
  Self = self(),
  gen_server:cast(Mod_ID, {Self, ID, ok}),
  connect(State#ifstate{type = Type, opt = SOpts, proto = tcp});

init(#ifstate{id = ID, module_id = Mod_ID, mm = #mm{iface = {udp,IP,Port,Opts}}} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {init, {socket,IP,Port,Opts}}}}),
  Type = case Opts of
           L when is_list(L) ->
             Tserver = [server || server <- L],
             Tclient = [client || client <- L],
             case {Tserver, Tclient} of
               {[server],[]} -> server;
               {[],[client]} -> client;
               _ ->
                 ?ERROR(ID, "Undefined connection type: ~p, set to client per default~n", [L]),
                 client
             end;
           A -> A
         end,
  IsMulticast = try {HdIP, _, _, _} = IP, (HdIP >= 224) andalso (HdIP =< 239)
                catch error:_ -> false end,
  SOpts = case Type of
            client -> [binary, {active, true}, {broadcast, true}];
            server ->
                  Mcast = case IsMulticast of
                              true -> [{multicast_if, IP}, {add_membership, {IP, {0, 0, 0, 0}}}];
                              _ -> []
                          end,
                  [binary, {ip, IP}, {active, true}, {reuseaddr, true}] ++ Mcast
          end,
  Self = self(),
  gen_server:cast(Mod_ID, {Self, ID, ok}),
  connect(State#ifstate{type = Type, opt = SOpts, proto = udp}).

cast_connected(#ifstate{fsm_pids = FSMs} = State) ->
  lists:map(fun(FSM) -> cast_connected(FSM, State) end, FSMs),
  lists:map(fun(FSM) -> maybe_cast_allowed(FSM, State) end, FSMs),
  State.

cast_connected(FSM, #ifstate{mm = MM, socket = Socket, port = Port} = State) ->
  case MM#mm.iface of
    {socket,_,_,_} when Socket /= nothing ->
      gen_server:cast(FSM, {chan, MM, {connected}});
    {udp,_,_,_} when Socket /= nothing ->
      gen_server:cast(FSM, {chan, MM, {connected}});
    {port,_,_} when Port /= nothing ->
      gen_server:cast(FSM, {chan, MM, {connected}});
    {serial,_,_,_,_,_,_} when Port /= nothing ->
      gen_server:cast(FSM, {chan, MM, {connected}});
    _ ->
      nothing
  end,
  maybe_cast_allowed(FSM, State).

maybe_cast_allowed(FSM, #ifstate{mm = MM, cfg = #{allow := Allow}} = State) ->
  case Allow of
    all ->
      gen_server:cast(FSM, {chan, MM, {allowed}});
    FSM ->
      gen_server:cast(FSM, {chan, MM, {allowed}});
    _ ->
      nothing
  end,
  State;
maybe_cast_allowed(_, State) ->
  State.

connect(#ifstate{id = ID, mm = #mm{iface = {port,Port,PortSettings}}} = State) ->
  process_flag(trap_exit, true),
  PortID = 
  case Port of
    {Type, _} when Type == spawn; Type == spawn_driver; Type == spawn_executable; Type == fd ->
      open_port(Port,PortSettings);
    {Application, Executable} when is_atom(Application), is_atom(Executable) ->
      Path = code:priv_dir(Application) ++ "/" ++ atom_to_list(Executable),
      open_port({spawn, Path}, PortSettings)
  end,
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {port_id, PortID}}}),
  {ok, cast_connected(State#ifstate{port = PortID})};

connect(#ifstate{id = ID, mm = #mm{iface = {serial,Port,BaudRate,DataBits,Parity,StopBits,FlowControl}}} = State) ->
  process_flag(trap_exit, true),
  PortID = open_port({spawn, code:priv_dir(evins) ++ "/evo_serial"}, [binary, {packet, 1}, overlapped_io]),
  Par = case Parity of
            none -> 0;
            odd -> 1;
            even -> 2
        end,
  FC = case FlowControl of
           none -> 0;
           ctsrts -> 1
       end,
  DB = DataBits - 1,
  SB = StopBits - 1,
  Zero = 0,
  BPort = list_to_binary(Port),
  PortID ! {self(), {command, <<?SER_OPEN:8, BaudRate:24/integer-native, DB:3/integer, Par:2/integer, SB:1/integer, FC:1/integer, Zero:1/integer, BPort/binary>>}},
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {port_id, PortID}}}),
  {ok, cast_connected(State#ifstate{port = PortID})};

connect(#ifstate{id = ID, mm = #mm{iface = {socket,IP,Port,_}}, type = client, proto = tcp, opt = SOpts} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, connecting}}),
  case gen_tcp:connect(IP, Port, SOpts, 1000) of
    {ok, Socket} ->
      {ok, cast_connected(State#ifstate{socket = Socket})};
    {error, econnrefused} ->
      gen_event:notify(error_logger, {fsm_core, self(), {ID, retry}}),
      {ok, _} = timer:send_after(1000, timeout),
      {ok, State};
    Error ->
      gen_event:notify(error_logger, {fsm_core, self(), {ID, retry}}),
      error_logger:warning_report([{file,?MODULE,?LINE},{id, ID}, Error]),
      {ok, _} = timer:send_after(1000, timeout),
      {ok, State}
  end;

connect(#ifstate{id = ID, mm = #mm{iface = {socket,IP,Port,_}}, type = server, proto = tcp, opt = SOpts} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {listening, IP, Port}}}),
  case gen_tcp:listen(Port, SOpts) of
    {ok, LSock} ->
      {ok, Ref} = prim_inet:async_accept(LSock, -1),
      {ok, State#ifstate{listener = LSock, acceptor = Ref}};
    {error, Reason} ->
      gen_event:notify(error_logger, {fsm_core, self(), {ID, retry}}),
      error_logger:warning_report([{file,?MODULE,?LINE},{id, ID}, Reason]),
      {ok, _} = timer:send_after(1000, timeout),
      {ok, State}
  end;

connect(#ifstate{id = ID, mm = #mm{iface = {udp,_IP,_Port,_}}, type = client, proto = udp, opt = SOpts} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, connecting}}),
  case gen_udp:open(0, SOpts) of
    {ok, Socket} ->
      {ok, cast_connected(State#ifstate{socket = Socket})};
    Error ->
      gen_event:notify(error_logger, {fsm_core, self(), {ID, retry}}),
      error_logger:warning_report([{file,?MODULE,?LINE},{id, ID}, Error]),
      {ok, _} = timer:send_after(1000, timeout),
      {ok, State}
  end;

connect(#ifstate{id = ID, mm = #mm{iface = {udp,IP,Port,_}}, type = server, proto = udp, opt = SOpts} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {listening, IP, Port}}}),
  case gen_udp:open(Port, SOpts) of
    {ok, Socket} ->
      {ok, cast_connected(State#ifstate{socket = Socket})};
    {error, Reason} ->
      gen_event:notify(error_logger, {fsm_core, self(), {ID, retry}}),
      error_logger:warning_report([{file,?MODULE,?LINE},{id, ID}, Reason]),
      {ok, _} = timer:send_after(1000, timeout),
      {ok, State}
  end.

broadcast(FSMs, Term) ->
  lists:map(fun(FSM) -> gen_server:cast(FSM, Term) end, FSMs).

%% allow = all | nobody | pid()
conditional_cast(_, #{allow := nobody} = _Cfg, _) ->
  nothing;
conditional_cast(FSMs, #{allow := Allow} = _Cfg, Term) when is_pid(Allow) ->
  lists:map(fun(FSM) when Allow == FSM ->
                gen_server:cast(FSM, Term);
               (_) ->
                nothing
            end, FSMs);
conditional_cast(FSMs, _, Term) ->
  broadcast(FSMs, Term).

handle_call(Request, From, #ifstate{id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {Request, From}}}),
  {noreply, State}.

handle_cast_helper({_, {send, Term}}, #ifstate{behaviour = B, cfg = Cfg, mm = #mm{iface = {cowboy,_,_}}} = State) ->
  NewCfg = B:from_term(Term, Cfg),
  {noreply, State#ifstate{cfg = NewCfg}};

handle_cast_helper({_, {send, Term}}, #ifstate{mm = #mm{iface = {erlang,Target}}} = State) ->
  Target ! {bridge, Term},
  {noreply, State};

handle_cast_helper({Src, {send, Term}}, #ifstate{behaviour = B, mm = MM, port = Port, socket = Socket, fsm_pids = FSMs, cfg = Cfg} = State) ->
  %% Self = self(),
  case B:from_term(Term, Cfg) of
    [<<>>, NewCfg] ->
      {noreply, State#ifstate{cfg = NewCfg}};
    [Bin, NewCfg] ->
      case MM#mm.iface of
        {socket,_,_,_} when Socket == nothing ->
          broadcast(FSMs, {chan_error, MM, disconnected});
        {socket,_,_,_} ->
          gen_tcp:send(Socket, Bin);
        {udp,IP,P,_} ->
          gen_udp:send(Socket, IP, P, Bin);
        {port,_,_} when Port == nothing -> 
          broadcast(FSMs, {chan_error, MM, disconnected});
        {port,_,_} ->
          Port ! {self(), {command, Bin}};
        {serial,_,_,_,_,_,_} ->
          serial_send(Port, Bin);
        {erlang,_,_,_} -> todo
      end,
      {noreply, State#ifstate{cfg = NewCfg}};
    {error, Reason} ->
      gen_server:cast(Src, {send_error, MM, Reason}),
      {noreply, State}
  end.

handle_cast({_, {fsm, Pid, ok}}, #ifstate{id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {fsm, Pid, ok}}}),
  process_bin(<<>>, cast_connected(Pid, State#ifstate{fsm_pids = [Pid | State#ifstate.fsm_pids]}));

handle_cast({_, {ctrl, reconnect}}, #ifstate{type = client, proto = tcp, mm = MM, fsm_pids = FSMs, socket = Socket} = State) when Socket =/= nothing ->
    ok = gen_tcp:close(Socket),
    broadcast(FSMs, {chan_error, MM, disconnected}),
    {ok, NewState} = connect(State),
    {noreply, NewState};

handle_cast({_, {ctrl, reconnect}}, #ifstate{mm = MM, fsm_pids = FSMs} = State) ->
    broadcast(FSMs, {chan_error, MM, disconnected}),
    cast_connected(State),
    {noreply, State};

handle_cast({_, {ctrl, Term}}, #ifstate{id = ID, behaviour = B, fsm_pids = FSMs, mm = MM, cfg = #{allow := Allow} = Cfg} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {ctrl, Term}}}),
  NewCfg = B:ctrl(Term, Cfg),
  Events =
    case {Term, Allow} of
      {{allow,nobody}, nobody} -> [];
      {{allow,nobody}, all} ->
        [{denied, PIDx} || PIDx <- FSMs];
      {{allow,nobody}, PID} when is_pid(PID) -> [{denied, PID}];
      {{allow,all}, all} -> [];
      {{allow,all}, nobody} ->
        [{allowed, PIDx} || PIDx <- FSMs];
      {{allow,all}, PID} when is_pid(PID) ->
        [{allowed, PIDx} || PIDx <- lists:delete(PID, FSMs)];
      {{allow,PID}, all}  when is_pid(PID) ->
        [{denied, PIDx} || PIDx <- lists:delete(PID, FSMs)];
      {{allow,PID}, nobody} when is_pid(PID)  -> [{allowed, PID}];
      {{allow,PID}, PID_prev} when is_pid(PID), is_pid(PID_prev), PID == PID_prev -> [];
      {{allow,PID}, PID_prev} when is_pid(PID), is_pid(PID_prev) ->
        [{allowed, PID}, {denied, PID_prev}];
      _ -> []
      end,
  [gen_server:cast(PIDx, {chan, MM, {Event}}) || {Event, PIDx} <- Events],
  {noreply, State#ifstate{cfg = NewCfg}};
handle_cast({_, {ctrl, Term}}, #ifstate{id = ID, behaviour = B, cfg = Cfg} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {ctrl, Term}}}),
  NewCfg = B:ctrl(Term, Cfg),
  {noreply, State#ifstate{cfg = NewCfg}};

handle_cast({_, {send, _}}, #ifstate{cfg = #{allow := nobody}} = State) ->
  {noreply, State};
handle_cast({SrcPid, {send, _}}, #ifstate{cfg = #{allow := Pid}} = State) when is_pid(Pid), Pid /= SrcPid ->
  {noreply, State};
handle_cast({_, {send, _}} = Message, State) ->
  handle_cast_helper(Message, State);

handle_cast(close, #ifstate{id = ID, port = Port} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, close}}),
  Self = self(),
  Port ! {Self, close},
  {noreply, State};

handle_cast(tcp_close, #ifstate{id = ID, socket = Socket} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, tcp_close}}),
  gen_tcp:close(Socket),
  {noreply, State};

handle_cast(Request, #ifstate{id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, Request}}),
  {stop, Request, State}.

handle_info({inet_async, LSock, Ref, {ok, NewCliSocket}},
            #ifstate{id = ID, listener = LSock, acceptor = Ref, socket = CliSocket} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {accepting, LSock, NewCliSocket}}}),
  case CliSocket of 
    nothing -> nothing;
    _ -> ok = gen_tcp:close(CliSocket)
  end,
  try
    case set_sockopt(LSock, NewCliSocket) of
      ok              -> ok;
      {error, Reason} -> exit({set_sockopt, Reason})
    end,
    %% Signal the network driver that we are ready to accept another connection
    {ok, NewRef} =  prim_inet:async_accept(LSock, -1),
    gen_event:notify(error_logger, {fsm_core, self(), {ID, {accepting, ok}}}),
    {noreply, cast_connected(State#ifstate{acceptor=NewRef, socket = NewCliSocket})}
  catch exit:Why ->
      error_logger:error_report([{file,?MODULE,?LINE},{id, ID},"Error in async accept",Why]),
      {stop, Why, State}
  end;

handle_info({inet_async, LSock, Ref, Error}, #ifstate{id = ID, listener=LSock, acceptor=Ref} = State) ->
  error_logger:error_report([{file,?MODULE,?LINE},{id, ID},"Error in socket acceptor",Error]),
  {stop, Error, State};

handle_info({tcp, Socket, Bin}, #ifstate{socket = Socket} = State) ->
  process_bin(Bin, State);

handle_info({udp, Socket, _IP, _Port, Bin}, #ifstate{socket = Socket} = State) ->
  process_bin(Bin, State);

handle_info({tcp, Socket1, Bin}, #ifstate{socket = Socket2} = State) ->
  error_logger:error_report([{file,?MODULE,?LINE},"Socket not matching",Socket1, Socket2, Bin]),
  {noreply, State};

handle_info({udp, Socket1, _IP, _Port, Bin}, #ifstate{socket = Socket2} = State) ->
  error_logger:error_report([{file,?MODULE,?LINE},"Socket not matching",Socket1, Socket2, Bin]),
  {noreply, State};

handle_info({PortID,{data,<<Type:8/integer, Bin/binary>>}}, #ifstate{port = PortID, proto = serial} = State) ->
  case Type of
    ?SER_RECV -> process_bin(Bin, State);
    _ -> {noreply, State}
  end;

handle_info({PortID,{data,Bin}}, #ifstate{port = PortID} = State) ->
  process_bin(Bin, State);

handle_info({PortID,eof}, #ifstate{port = PortID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {PortID, eof}}),
  {ok, _} = timer:send_after(1000, timeout),
  {noreply, State#ifstate{port = nothing}};

handle_info({bridge,Term}, #ifstate{fsm_pids = FSMs, mm = MM, cfg = Cfg} = State) ->
  conditional_cast(FSMs, Cfg, {chan, MM, Term}),
  {noreply, State};

handle_info(timeout, #ifstate{id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, timeout}}),
  case connect(State) of
    {ok, NewState} -> {noreply, NewState};
    {stop, Reason} -> {stop, Reason, State}
  end;

handle_info({Port, closed}, #ifstate{id = ID, fsm_pids = FSMs, port = Port, mm = MM} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {closed, Port}}}),
  broadcast(FSMs, {chan_closed, MM}),
  {ok, _} = timer:send_after(1000, timeout),
  {noreply, State#ifstate{port = nothing}};

handle_info({tcp_closed, _}, #ifstate{id = ID, fsm_pids = FSMs, type = client, mm = MM} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, tcp_closed}}),
  broadcast(FSMs, {chan_closed, MM}),
  {ok, _} = timer:send_after(1000, timeout),
  {noreply, State#ifstate{socket = nothing}};

handle_info({tcp_closed, _}, #ifstate{id = ID, fsm_pids = FSMs, type = server, mm = MM} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, tcp_closed}}),
  broadcast(FSMs, {chan_closed_client, MM}),
  {noreply, State#ifstate{socket = nothing}};

handle_info({http, _Socket, Request}, #ifstate{id = ID, fsm_pids = FSMs, cfg = Cfg, type = server, mm = MM} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {http_request, Request}}}),
  conditional_cast(FSMs, Cfg, {chan, MM, Request}),
  {noreply, State};

handle_info({'EXIT', PortID, _Reason}, #ifstate{id = ID, port = PortID, fsm_pids = FSMs, mm = MM} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {exit, PortID}}}),
  %% Self = self(),
  broadcast(FSMs, {chan_error, MM, timeout}),
  {ok, _} = timer:send_after(1000, timeout),
  {noreply, State#ifstate{port = nothing}};

handle_info(Info, #ifstate{id = ID} = State) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {unhandled_info, Info, State}}}),
  {stop, Info, State}.

terminate(Reason, #ifstate{behaviour = B, id = ID, cfg = Cfg, mm = #mm{iface = {cowboy,_,_}}}) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {terminate, Reason}}}),
  B:stop(Cfg),
  ok;

terminate(Reason, #ifstate{id = ID}) ->
  gen_event:notify(error_logger, {fsm_core, self(), {ID, {terminate, Reason}}}),
  ok.

code_change(_, State, _) ->
  {ok, State}.

to_term(Module, Tail, Chunk, Cfg) ->
  Answers = Module:split(list_to_binary([Tail,Chunk]), Cfg),
  [TermList, ErrorList, MoreList, NewCfg] = 
    lists:foldr(fun(Elem, [TermList, ErrorList, MoreList, CfgAcc]) ->
                    case Elem of
                      {more, <<>>} ->
                        [TermList, ErrorList, MoreList, CfgAcc];
                      {more, MoreElem} -> 
                        [TermList, ErrorList, [MoreElem|MoreList], CfgAcc];
                      {error, _} ->
                        [TermList, [Elem|ErrorList], MoreList, CfgAcc];
                      {ctrl, Ctrl} ->
                        [TermList, ErrorList, MoreList, Module:ctrl(Ctrl, CfgAcc)];
                      _ ->
                        [[Elem | TermList], ErrorList, MoreList, CfgAcc]
                    end
                end, [[],[],[],Cfg], Answers),
  [TermList, ErrorList, [], list_to_binary(MoreList), NewCfg].

bridge(Target, {ctrl, Term}) ->
  gen_server:cast(Target, {self(), {ctrl, Term}});
bridge(Target, {send, Term}) ->
  Target ! {bridge, Term}.

%%%------------------------------------------------------------------------
%%% Internal functions
%%%------------------------------------------------------------------------

%% Taken from prim_inet.  We are merely copying some socket options from the
%% listening socket to the new client socket.
set_sockopt(LSock, CliSocket) ->
  true = inet_db:register_socket(CliSocket, inet_tcp),
  case prim_inet:getopts(LSock, [active, nodelay, keepalive, delay_send, priority, tos]) of
    {ok, Opts} ->
      case prim_inet:setopts(CliSocket, Opts) of
        ok    -> ok;
        Error -> gen_tcp:close(CliSocket), Error
      end;
    Error ->
      gen_tcp:close(CliSocket), Error
  end.

process_bin(Bin, #ifstate{fsm_pids = [], tail = Tail} = State) ->
  %% TODO: role_worker should be aware of the number of connected FSMs
  {noreply, State#ifstate{tail = list_to_binary([Tail, Bin])}};
process_bin(Bin, #ifstate{behaviour = B, fsm_pids = FSMs, cfg = Cfg, tail = Tail, mm = MM} = State) ->
  case B:to_term(Tail, Bin, Cfg) of
    [TermList, ErrorList, Raw, More, NewCfg] ->
      Terms = if byte_size(Raw) > 0 -> TermList ++ ErrorList ++ [{raw, Raw}];
                 true -> TermList ++ ErrorList
              end,
      lists:foreach(fun(Term) -> conditional_cast(FSMs, Cfg, {chan, MM, Term}) end, Terms),
      {noreply, State#ifstate{cfg = NewCfg, tail = More}};
    _ ->
      {noreply, State}
  end.

serial_send(nothing, _) -> ok;
serial_send(Port, <<Chunk:253/binary, Rest/binary>>) ->
    Port ! {self(), {command, <<?SER_SEND:8, Chunk/binary>>}},
    serial_send(Port, Rest);
serial_send(Port, Chunk) ->
    Port ! {self(), {command, <<?SER_SEND:8, Chunk/binary>>}}.
