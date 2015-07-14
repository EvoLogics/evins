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

-type ref() :: atom() | {atom(),atom()} | {global,any()} | {via,atom(),any()} | pid().

-define(Format(ID, Fmt, Color), ioc:format(?MODULE, ?LINE, ID, Fmt, Color)).
-define(Format(ID, Fmt, Data, Color), ioc:format(?MODULE, ?LINE, ID, Fmt, Data, Color)).
-define(Format(ID, Fmt, IODevice, Data, Color), ioc:format(?MODULE, ?LINE, ID, IODevice, Fmt, Data, Color)).

-record(mm,{role,role_id,status=false,params=[],iface}).
%% iface = {IP,Port,Type} | {Port, PortSettings}

-define(ANSWER_TIMEOUT, {s, 1}).

-define(IMSH_ANSWER_DELAY, 700000).
-define(IMSH_SECOND_ANSWER_DELAY, 600000).
-define(IMSH_DELAY, 1200000).

%% physical constants
-define(DBAR_PRO_METER,0.9804139432).
-define(PAIR,10.0).

-define(todo, mix:todo(?MODULE, ?LINE, ?ID)).

-define(ID, SM#sm.id).

-define(TRACE(ID,Fmt,Data), ?Format(ID, Fmt, Data, trace)).
-define(INFO(ID,Fmt,Data), ?Format(ID, Fmt, Data, info)).
-define(WARNING(ID,Fmt,Data), ?Format(ID, Fmt, Data, warning)).
-define(ERROR(ID,Fmt,Data), ?Format(ID, Fmt, Data, error)).

-record(sm,{
	  id,
	  table,
	  share,
	  dets_share,
	  roles,
	  module,
	  env = #{}, %% big state of the fsm
	  state = idle,
	  event = eps,
	  event_params = [],
	  stack = [],
	  final = [],
	  timeouts = []}).

-record(cbstate, {id,     %% cowboy id
		  fsm_id, %% fsm id
		  share   %% share ets table id
		 }). %% cowboy state
