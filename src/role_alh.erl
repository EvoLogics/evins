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
-module(role_alh).
-behaviour(role_worker).

-include("fsm.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

-record(config, {filter,mode,waitsync,request,telegram,eol,ext_networking,pid}).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
    Cfg = #config{filter=at,mode=data,waitsync=no,request="",telegram="",eol="\n",ext_networking=no,pid=0},
    role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl(_,Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
    role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

-define(ERROR_WRONG, <<"WRONG FORMAT">>).
-define(EOL_SEND, <<"\n">>).
-define(EOL_RECV, <<"\r\n">>).


from_term(Term, Cfg) ->
    {Request, Wait, Telegram} = from_term_helper(Term, Cfg#config.pid, Cfg#config.filter),
    Bin = list_to_binary([Telegram]),
    [Bin, Cfg#config{waitsync=Wait,request=Request,telegram=Telegram}].

from_term_helper(Tuple,_,_) when  is_tuple(Tuple) ->
    case Tuple of
	{sync, "OK"} ->
	    {"SYNC", singleline, [<<"OK">>, ?EOL_RECV]};
	{sync, Answer}  when is_tuple(Answer) ->
	    {"SYNC", singleline, [nl_mac_hf:convert_to_binary(tuple_to_list(Answer)), ?EOL_RECV]};
	{sync, Answer}  when is_binary(Answer) ->
	    {"SYNC", singleline, [Answer, ?EOL_RECV]};
	{sync, Answer}  when is_list(Answer) ->
	    {"SYNC", singleline, [list_to_binary(Answer), ?EOL_RECV]};
	{async, Msg}    when is_tuple(Msg) ->
	    {"ASYNC", singleline, [nl_mac_hf:convert_to_binary(tuple_to_list(Msg)), ?EOL_RECV]};
	{error, Params} when is_list(Params) ->
	    {"ERROR", singleline, ["ERROR ",string:to_upper(Params), ?EOL_RECV]};
	_ ->
	    {"OTHER", singleline, [nl_mac_hf:convert_to_binary(tuple_to_list(Tuple)), ?EOL_SEND]}
    end.

split(L, Cfg) ->
    case re:run(L,"\r\n") of
	{match, [{_,_}]} ->
	    case re:run(L,"^(RECVIM,p|RECVIM,|RECVIMS,p|RECVIMS,)(.*)",[dotall,{capture,[1,2],binary}]) of
		{match, [<<"RECVIM,p">>,P]}  -> recvim_extract(L,P,pid);
		{match, [<<"RECVIM,">>,P]}   -> recvim_extract(L,P,nopid);
		{match, [<<"RECVIMS,p">>,P]} -> recvims_extract(L,P,pid);
		{match, [<<"RECVIMS,">>,P]}  -> recvims_extract(L,P,nopid);
		nomatch ->
		    case re:run(L,"^(DELIVEREDIM,|FAILEDIM,|OK|BUSY|ERROR)(.*?)[\r\n]+(.*)",[dotall,{capture,[1,2,3],binary}]) of
			{match, [<<"DELIVEREDIM,">>,P,L1]} -> [deliveredim_extract(P)	| split(L1,Cfg)];
			{match, [<<"FAILEDIM,">>,P,L1]}    -> [failedim_extract(P)	| split(L1,Cfg)];
			{match, [<<"OK">>,P,L1]} 	   -> [ok_extract(P)		| split(L1,Cfg)];
			{match, [<<"BUSY">>,P,L1]} 	   -> [busy_extract(P)		| split(L1,Cfg)];
			{match, [<<"ERROR">>,P,L1]} 	   -> [error_extract(P)		| split(L1,Cfg)];
			nomatch	->
			    case re:run(L,"(.*?)[\r\n]+(.*)",[dotall,{capture,[1,2],binary}]) of
				{match, [P,L1]} ->
				    [{ignore, P} | split(L1,Cfg) ]
			    end
		    end
	    end;
	nomatch ->
	    case re:run(L,"\n") of
		{match, [{_,_}]} ->
		    %% Temporary only instant messages can be used!
		    case re:run(L,"^(AT[*]SENDIM,p|AT[*]SENDIM,|AT[*]SENDIMS,p|AT[*]SENDIMS,)(.*)",[dotall,{capture,[1,2],binary}]) of
			{match, [<<"AT*SENDIM,p">>,P]}	-> sendim_extract(L,P,Cfg,pid);
			{match, [<<"AT*SENDIM,">>,P]}	-> sendim_extract(L,P,Cfg,nopid);
			{match, [<<"AT*SENDIMS,p">>,P]}	-> sendims_extract(L,P,Cfg,pid);
			{match, [<<"AT*SENDIMS,">>,P]}	-> sendims_extract(L,P,Cfg,nopid);
			nomatch ->
			    case re:run(L,"^(AT)(.*?)[\n]+(.*)",[dotall,{capture,[1,2,3],binary}]) of
				{match, [<<"AT">>,P,L1]} -> [{rcv_ul, {command, P} } | split(L1,Cfg)];
				nomatch ->
				    case re:run(L,"(.*?)[\n]+(.*)",[dotall,{capture,[1,2],binary}]) of
					{match, [P,L1]} -> [ {rcv_ul, {other, P}}| split(L1,Cfg)];
					nomatch 		-> [ {more, L} ]
				    end
			    end
		    end;
		nomatch -> [{more, L}]
	    end
    end.

sendim_extract(L, P, Cfg, IfPid) ->
    try
	[Params, BPid] =
	    if IfPid =:= nopid ->
		    {match, T} = re:run(P,"([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4],binary}]), [T, nopid];
	       true ->
		    {match, [PPid | T]} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5],binary}]), [T, PPid]
	    end,
	[BLen,BDst,BFlag,PayloadTail] = Params,
	PLLen = byte_size(PayloadTail),
	Len = binary_to_integer(BLen),
	IDst = binary_to_integer(BDst),
	OPLLen = PLLen - 1,
	if
	    Len  =< PLLen ->
		{match, [Payload, Tail1]} = re:run(PayloadTail, "^(.{" ++ integer_to_list(OPLLen) ++ "})\n(.*)",[dotall,{capture,[1,2],binary}]),
		TFlag = binary_to_atom(BFlag, utf8),
		Tuple =
		    if IfPid =:= nopid ->
			    {at, "*SENDIM", IDst, TFlag, Payload};
		       true ->
			    {at, {pid, binary_to_integer(BPid)}, "*SENDIM", IDst, TFlag, Payload}
		    end,
		if Len =/= OPLLen ->
			[{sync, "*SENDIM", {error, ?ERROR_WRONG}}];
		   true ->
			[{rcv_ul, Tuple } | split(Tail1,Cfg)] end;
	    true ->
		case re:run(PayloadTail,"\n") of
		    {match, [{_,_}]} -> [{sync, "*SENDIM", {error, ?ERROR_WRONG}}];
		    _ -> [{more, L}]
		end
	end
    catch error:_Reason -> [{sync, "*SENDIM", {error, ?ERROR_WRONG}}]
    end.

sendims_extract(L, P, Cfg, IfPid) ->
    try
	[Params, BPid] =
	    if IfPid =:= nopid -> {match, T} = re:run(P,"([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4],binary}]), [T, nopid];
	       true -> {match, [PPid | T]} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5],binary}]), [T, PPid]
	    end,
	[BLen,BDst,BTimeStamp,PayloadTail] = Params,
	PLLen = byte_size(PayloadTail),
	Len = binary_to_integer(BLen),
	IDst = binary_to_integer(BDst),
	OPLLen = PLLen - 1,
	if
	    Len  =< PLLen ->
		{match, [Payload, Tail1]} = re:run(PayloadTail, "^(.{" ++ integer_to_list(OPLLen) ++ "})\n(.*)",[dotall,{capture,[1,2],binary}]),
		TimeStamp = binary_to_integer(BTimeStamp),
		Tuple =
		    if IfPid =:= nopid -> {at, "*SENDIMS", IDst, TimeStamp, Payload};
		       true -> {at, {pid, binary_to_integer(BPid)}, "*SENDIMS", IDst, TimeStamp, Payload}
		    end,
		if Len =/= OPLLen -> [{sync, "*SENDIMS", {error, ?ERROR_WRONG}}]; true ->
			[{rcv_ul, Tuple } | split(Tail1,Cfg)] end;
	    true ->
		case re:run(PayloadTail,"\n") of
		    {match, [{_,_}]} -> [{sync, "*SENDIMS", {error, ?ERROR_WRONG}}];
		    _ -> [{more, L}]
		end
	end
    catch error:_Reason -> [{sync, "*SENDIMS", {error, ?ERROR_WRONG}}]
    end.

bin_to_num(Bin) ->
    N = binary_to_list(Bin),
    case string:to_float(N) of
	{error,no_float} -> list_to_integer(N);
	{F,_Rest} -> F
    end.


recvim_extract(L,P,IfPid) ->
    try
	[BPid, Params] =
	    if IfPid =:= nopid ->
		    {match, T} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",
					[dotall,{capture,[1,2,3,4,5,6,7,8,9],binary}]), [nopid, T];
	       true ->
		    {match, [H| T]} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",
					     [dotall,{capture,[1,2,3,4,5,6,7,8,9,10],binary}]), [H, T]
	    end,
	[BLen,BSrc,BDst,BFlag,BDuration,BRssi,BIntegrity,BVelocity,PayloadTail] = Params,
	Len = binary_to_integer(BLen),
	PLLen = byte_size(PayloadTail),
	TFlag = binary_to_atom(BFlag, utf8),
	if
	    Len + 2 =< PLLen ->
		{match, [Payload, Tail1]} = re:run(PayloadTail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]),
		if IfPid =:= nopid ->
			[{async, {recvim, Len, bin_to_num(BSrc),bin_to_num(BDst),TFlag,
				  bin_to_num(BDuration),bin_to_num(BRssi),bin_to_num(BIntegrity),bin_to_num(BVelocity),Payload}}];
		   true ->
			[{async, {pid, binary_to_integer(BPid)},
			  {recvim, Len, bin_to_num(BSrc),bin_to_num(BDst),TFlag,
			   bin_to_num(BDuration),bin_to_num(BRssi),bin_to_num(BIntegrity),bin_to_num(BVelocity),Payload}}]
		end;
	    true -> [{more, L}]
	end
    catch error:_Reason -> [{sync, "*RECVIM", {error, ?ERROR_WRONG}}]
    end.

recvims_extract(L,P,IfPid) ->
    try
	[BPid, Params] =
	    if IfPid =:= nopid ->
		    {match, T} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",
					[dotall,{capture,[1,2,3,4,5,6,7,8,9],binary}]), [nopid, T];
	       true ->
		    {match, [H| T]} = re:run(P,"([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",
					     [dotall,{capture,[1,2,3,4,5,6,7,8,9,10],binary}]), [H, T]
	    end,
	[BLen,BSrc,BDst,BTimeStamp,BDuration,BRssi,BIntegrity,BVelocity,PayloadTail] = Params,
	Len = binary_to_integer(BLen),
	PLLen = byte_size(PayloadTail),
	TimeStamp = binary_to_integer(BTimeStamp),
	if
	    Len + 2 =< PLLen ->
		{match, [Payload, Tail1]} = re:run(PayloadTail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]),
		if IfPid =:= nopid ->
			[{async, {recvims, Len, bin_to_num(BSrc),bin_to_num(BDst),TimeStamp,
				  bin_to_num(BDuration),bin_to_num(BRssi),bin_to_num(BIntegrity),bin_to_num(BVelocity),Payload}}];
		   true ->
			[{async, {pid, binary_to_integer(BPid)}, 
			  {recvims, Len,bin_to_num(BSrc),bin_to_num(BDst),TimeStamp,
			   bin_to_num(BDuration),bin_to_num(BRssi),bin_to_num(BIntegrity),bin_to_num(BVelocity),Payload}}]
		end;
	    true -> [{more, L}]
	end
    catch error:_Reason -> [{sync, "*RECVIMS", {error, ?ERROR_WRONG}}]
    end.

deliveredim_extract(P)->
    try
	{match, [BDst]} = re:run(P,"([^,]*)",[dotall,{capture,[1],binary}]),
	{async, {deliveredim, BDst}}
    catch error:_Reason -> {sync, "*SENDIM", {error, ?ERROR_WRONG}}
    end.

failedim_extract(P)->
    try
	{match, [BDst]} = re:run(P,"([^,]*)",[dotall,{capture,[1],binary}]),
	{async, {failedim, BDst}}
    catch error:_Reason -> {sync, "*SENDIM", {error, ?ERROR_WRONG}}
    end.

ok_extract(_P)->
    try
	{sync, {ok}}
    catch error:_Reason -> {sync, "*SENDIM", {error, ?ERROR_WRONG}}
    end.

busy_extract(P)->
    try
	{match, [Msg]} = re:run(P,"([^,]*)",[dotall,{capture,[1],binary}]),
	{sync, {busy, Msg}}
    catch error:_Reason -> {sync, "*SENDIM", {error, ?ERROR_WRONG}}
    end.

error_extract(P)->
    try
	{match, [Msg]} = re:run(P,"([^,]*)",[dotall,{capture,[1],binary}]),
	{sync, {error, Msg}}
    catch error:_Reason -> {sync, "*SENDIM", {error, ?ERROR_WRONG}}
    end.
