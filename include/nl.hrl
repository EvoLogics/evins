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


%--------------- MAIN MAC HEADER -----------------
% 	4b						3b			1b
%		NL_MAC_PID		Flag 		ADD
%---------------------------------------------

%--------------- MAIN NL HEADER -----------------
% 	6b								3b			6b			2b 			6b			6b			3b
%		NL_Protocol_PID		Flag 		PKGID 	TTL			SRC 		DST 		ADD
%---------------------------------------------
%--------------- PROTOCOL HEADER -----------------
%-------> data
%		3b				6b
%		TYPEMSG 	MAX_DATA_LEN
%-------> neighbours
% 	3b				6b 								LenNeighbours * 6b		REST till / 8
%		TYPEMSG 	LenNeighbours 		Neighbours 						ADD
%-------> path_data
% 	3b				6b						6b			LenPath * 6b   REST till / 8
%		TYPEMSG 	MAX_DATA_LEN	LenPath 	Path 					 ADD
%-------> neighbour_path
% 	3b				6b 								LenNeighbours * 6b		6b				LenPath * 6b 			REST till / 8
%		TYPEMSG 	LenNeighbours 		Neighbours 						LenPath 	Path 							ADD
%-------> path_addit
% 	3b				6b 				LenPath * 6b 	 	2b 				LenAdd * 8b 			REST till / 8
%		TYPEMSG 	LenPath 	Path 					 	LenAdd 		Addtional Info 		ADD
%---------------------------------------------

-define(NL_PID_MAX, 63).
-define(MAC_PID_MAX, 16).

-define(FLAG_MAX, 5).
-define(TYPE_MSG_MAX, 5).
-define(TTL, 3).
-define(PKG_ID_MAX, 63).
-define(ADDRESS_MAX, 63).
-define(MAX_LEN_PATH, 63).
-define(MAX_LEN_NEIGBOURS, 63).
-define(LEN_ADD, 3).
-define(ADD_INFO_MAX, 255).
-define(MAX_DATA_LEN, 64).

-define(MAX_IM_LEN, 50).

-define(LIST_ALL_PROTOCOLS, [staticr,
			     staticrack,
			     sncfloodr,
			     sncfloodrack,
			     dpfloodr,
			     dpfloodrack,
			     icrpr,
			     sncfloodpfr,
			     sncfloodpfrack,
			     dblfloodpfr,
			     dblfloodpfrack,
			     evoicrppfr,
			     evoicrppfrack,
			     loarpr,
			     loarprack]).

-record(pr_conf,{stat=false, brp=false, br_na=false, ack=false, ry_only=false, pf=false, prob=false, dbl=false, evo=false, lo=false, rm=false}).

-define(LIST_ALL_PARAMS, [
				stat,		% static routing
				brp,		% broadcast path on Dst, not follow path in unicast mode
			  br_na,	% broadcast not alowed
			  ack,		% with acknowledgement
			  ry_only, 	% relay only data without knowing path
			  pf,		% path finder
					% if ry_only and pf are use together, it means thay data will be relayed and on the way
					% the path will be established, this path on dst will be used for sending ack back
			  prob,		% probabilsitic flooding
			  dbl,		% double waves (two flooding waves)
			  evo,		% evologics special type, to add info like Rssi and Integrity
			  lo,		% low overhead
			  rm]).		% route maintenance


-define(PROTOCOL_NL_PID(P),
	case P of
		staticr					-> 0;
		staticrack			-> 1;
		sncfloodr 			-> 2;
		sncfloodrack 		-> 3;
		dpfloodr 				-> 4;
		dpfloodrack 		-> 5;
		icrpr 					-> 6;
		sncfloodpfr 		-> 7;
		sncfloodpfrack 	-> 8;
		dblfloodpfr 		-> 9;
		dblfloodpfrack 	-> 10;
		evoicrppfr 			-> 11;
		evoicrppfrack 	-> 12;
		loarpr 					-> 13;
		loarprack 			-> 14
	end).

-define(PROTOCOL_MAC_PID(P),
	case P of
		mac_burst  -> 0;
    csma_alh   -> 1;
    cut_lohi   -> 2;
    aut_lohi   -> 3;
    dacap      -> 4
	end).

-define(PROTOCOL_CONF, [
			{staticr,	[{stat, ry_only}, fsm_nl_flood]},	% Simple static routing
			{staticrack, [{stat, ry_only, br_na, ack}, fsm_nl_flood]},	% Simple static routing with acknowledgement
			{sncfloodr, [{ry_only}, fsm_nl_flood]},	% Sequence number controlled flooding
			{sncfloodrack, [{ry_only, br_na, ack}, fsm_nl_flood]},	% Sequence number controlled flooding with acknowledgement
			{dpfloodr, [{ry_only, prob},    fsm_nl_flood]},	% Dynamic Probabilistic Flooding
			{dpfloodrack, [{ry_only, prob, br_na, ack},fsm_nl_flood]},	% Dynamic Probabilistic Flooding with acknowledgement
			{icrpr, [{ry_only, pf, br_na, ack},  fsm_nl_flood]},	% Information Carrying Routing Protocol
			{sncfloodpfr, [{pf, brp, br_na}, fsm_nl_flood]},	% Pathfind and relay, based on sequence number controlled flooding
			{sncfloodpfrack,[{pf, brp, br_na, ack}, fsm_nl_flood]},	% Pathfind and relay, based on sequence number controlled flooding with acknowledgement
			{dblfloodpfr, [{pf, dbl, br_na}, fsm_nl_flood]},	% Double flooding path finder
			{dblfloodpfrack,[{pf, dbl, br_na, ack}, fsm_nl_flood]},	% Double flooding path finder with acknowledgement
			{evoicrppfr, [{pf, br_na, lo, evo}, fsm_nl_flood]},	% Evologics Information Carrying routing protocol
			{evoicrppfrack, [{pf, br_na, lo, evo, ack}, fsm_nl_flood]},	% Evologics Information Carrying routing protocol with acknowledgement
			{loarpr, [{pf, br_na, lo, rm}, fsm_nl_flood]},	% Low overhead routing protocol
			{loarprack, [{pf, br_na, lo, rm, ack}, fsm_nl_flood]}	% Low overhead routing protocol with acknowledgement
		       ]).

-define(PROTOCOL_DESCR, ["\n",
			 "staticr        - simple static routing, in config file f.e. {routing,{{7,1},2}}\r\n",
			 "staticrack     - simple static routing with acknowledgement, in config file f.e. {routing,{{7,1},2}}\r\n",
			 "sncfloodr      - sequence number controlled flooding\r\n",
			 "sncfloodrack   - sequence number controlled flooding with acknowledgement\r\n",
			 "sncfloodpfr    - pathfind and relay to destination\r\n",
			 "sncfloodpfrack - pathfind and relay to destination with acknowledgement\r\n",
			 "evoicrppfr     - Evologics ICRP pathfind and relay, path is chosend using Rssi and Integrity of Evo DMACE Header\r\n"
			 "evoicrppfrack  - Evologics ICRP pathfind and relay, path is chosend using Rssi and Integrity of Evo DMACE Header with acknowledgement\r\n"
			 "dblfloodpfr    - double flooding path finder, based on 3 waves, going through the network to find path\r\n"
			 "dblfloodpfrack - double flooding path finder, based on 3 waves, going through the network to find path with acknowledgement\r\n"
			 "dpfloodr       - dynamic probabilistic flooding\r\n"
			 "dpfloodrack    - dynamic probabilistic flooding with acknowledgement\r\n"
			 "icrpr          - information carrying routing protocol\r\n"
			 "loarp          - low overhead routing protocol\r\n"
			 "loarpack       - low overhead routing protocol with acknowledgement\r\n"
			]).


-define(HELP, ["\r\n",
			 "=========================================== HELP ===========================================\r\n",
			 "?\t\t\t\t\t\t- List of all commands\r\n",
			 "\r\n\r\n\r\n",
			 "===================================== Send and receive ======================================\r\n",
			 "NL,send,[<Datalen>],<Dst>,<Data>\t\t- send data, <Datalen> - optional\r\n",
			 "NL,recv,<Datalen>,<Src>,<Dst>,<Data>\t\t- recv data\r\n",
			 "\r\n\r\n\r\n",
			 "===================================== Immediate response =====================================\r\n",
			 "NL,ok\t\t\t\t\t\t- message was accepted and will be transmitted\r\n",
			 "NL,error\t\t\t\t\t- message was not accepted and will be dropped\r\n",
			 "NL,busy\t\t\t\t\t\t- NL is busy, message will be dropped\r\n",
			 "\r\n\r\n\r\n",
			 "==================================== Data delivery reports ====================================\r\n",
			 "NL,failed,<Src>,<Dst>\t\t\t\t- Message was not delivered to destination node\r\n",
			 "NL,delivered,<Src>,<Dst>\t\t\t- Message was successfully delivered to destination node\r\n",
			 "\r\n\r\n\r\n",
			 "==================================== Set commands =====================================\r\n",
			 "NL,set,address,<Addr>\t\t\t\t- set local address\r\n",
 			 "NL,set,protocol,<Protocol_Name>\t\t\t- set current routing protocol\r\n",
 			 "NL,set,routing,[<LA1>-><LA2>],[<LA3>-><LA4>],...,[<Default LA>]\t- set routing only for static routing\r\n",
			 "\r\n\r\n\r\n",
			 "==================================== Information commands =====================================\r\n",
			 "NL,get,address\t\t\t\t\t- get local address\r\n",
			 "NL,get,protocols\t\t\t\t- Get description of all protocols\r\n",
			 "NL,get,protocol\t\t\t\t\t- Get current routing protocol\r\n",
			 "NL,get,protocol,<Protocol_name>\t\t\t- Get description of specific protocol\r\n",
			 "NL,get,neighbours\t\t\t\t- Get current  neighbours\r\n",
			 "NL,get,routing\t\t\t\t\t- Get current routing table\r\n",
			 "NL,get,state\t\t\t\t\t- Get current  state of protocol (sm)\r\n",
			 "NL,get,states\t\t\t\t\t- Get last 50  states of protocol (sm)\r\n",
			 "\r\n\r\n\r\n",
			 "======================== Statistics commands for protocols of all types ========================\r\n",
			 "NL,get,stats,neighbours\t\t\t\t- Get statistics of all neighbours from start of program till the current time\r\n
			 \t\t\tAnswer:
			 \t\t\t<Role : relay or source><Neighbours><Duration find path><Count found this path><Total count try findpath>\r\n"
			 "\r\n",
			 "================== Statistics commands only for protocols of path finding type ==================\r\n",
			 "NL,get,stats,paths\t\t\t\t- Get statistics of all paths from start of program till the current time\r\n
			 \t\t\tAnswer:
			 \t\t\t<Role : relay or source><Path><Duration find path><Count found this path><Total count try findpath>\r\n"
			 "\r\n",
			 "========================= Statistics commands only for protocols with ack ========================\r\n",
			 "NL,get,stats,data\t\t\t\t- Get statistics of all messages were sent from start of program till the current time\r\n
			 \t\t\tAnswer:
			 \t\t\t<Role : relay or source><Data><Length><Duration find path and transmit data><State: delivered or failed><Total count try findpath>"
			 "\r\n\r\n\r\n",
			 "========================= Clear commands ========================\n",
			 "NL,delete,neighbour,<Addr>\t\t\t\t-remove a neighbour from the current neighbour list and updates the routing table\r\n",
			 "NL,clear,stats,data\t\t\t\t-clear the data statistics\r\n"
			 "\r\n\r\n\r\n",
			 "========================= Reset commands ========================\r\n",
			 "NL,reset,state\t\t\t\t\t-revert fsm state to idle state\r\n"
			]).

-define(STATE_DESCR,
	[{idle,	"Ready to proccess data\r\n"},
	 {swv,	"Sending data\r\n"},
	 {rwv,	"Receiving data\r\n"},
	 {wack,	"Waiting for acknowledgement\r\n"},
	 {sack,	"Sending acknowledgement\r\n"},
	 {wpath,"Waiting for path\r\n"},
	 {spath,"Sending for path\r\n"}]).

-define(PROTOCOL_SPEC(P),
	lists:foldr(fun(X,A) ->
			    case X of
				stat when P#pr_conf.stat 	  -> ["Type\t\t: Static Routing\r\n"  | A];
				ry_only when P#pr_conf.ry_only 	  -> ["Type\t\t: Only relay\r\n"  | A];
				ack 	when P#pr_conf.ack 	  -> ["Ack\t\t: true\r\n"  | A];
				ack	when not P#pr_conf.ack 	  -> ["Ack\t\t: false\r\n" | A];
				br_na	when P#pr_conf.br_na 	  -> ["Broadcast\t: not available\r\n" | A];
				br_na 	when not P#pr_conf.br_na  -> ["Broadcast\t: available\r\n" | A];
				pf 	when P#pr_conf.pf	  -> ["Type\t\t: Path finder\r\n" | A];
				evo 	when P#pr_conf.evo	  -> ["Specifics\t: Evologics DMACE Rssi and Integrity\r\n" | A];
				dbl 	when P#pr_conf.dbl	  -> ["Specifics\t: 2 waves are used to find path, find two way links\r\n" | A];
				rm 	when P#pr_conf.rm	  -> ["Route maintenance\r\n" | A];
				_ 				  -> A
			    end end, [], ?LIST_ALL_PARAMS)).

%% ------------------------------------- Addressing ----------------------------
-define(TABLE_LADDR_MACADDR, [
			      {1, 1},
			      {2, 2},
			      {3, 3},
			      {4, 4},
			      {5, 5},
			      {6, 6},
			      {7, 7},
			      {8, 8},
			      {9, 9},
			      {255, ?ADDRESS_MAX},
			      {?ADDRESS_MAX, 255}
			     ]).

-define(FLAG2NUM(F),
	case F of
	    %% NL and MAC flags
	    data 	-> 0;
	    %% MAC flags
	    tone 	-> 1;
	    rts 	-> 2;
	    cts 	-> 3;
	    warn 	-> 4;
	    %% NL flags
	    ack 	-> 1;
	    neighbours  -> 2;
	    path 	-> 3;
	    path_addit 	-> 4;
	    % data type, sending only to the neighbours, info: data reached dst
	    dst_reached -> 5
	end).

-define(NUM2FLAG(N, Layer),
	case N of
	    %% NL and MAC flags
	    0 			 -> data;
	    %% MAC flags
	    1 when Layer =:= mac -> tone;
	    2 when Layer =:= mac -> rts;
	    3 when Layer =:= mac -> cts;
	    4 when Layer =:= mac -> warn;
	    %% NL flags
	    1 when Layer =:= nl  -> ack;
	    2 when Layer =:= nl  -> neighbours;
	    3 when Layer =:= nl  -> path;
	    4 when Layer =:= nl  -> path_addit;
	    5			 -> dst_reached
	end).

-define(NUM2TYPEMSG(N),
	case N of
	    %% NL layer
	    0 			 -> neighbours; % n:(.*)
	    1 			 -> path_data;  % p:(.*),d:(.*)
	    2 			 -> neighbours_path; % n:(.*),p:(.*)
	    3 			 -> path_addit; % p:(.*),a:(.*)
	    4 			 -> data
	end).

-define(TYPEMSG2NUM(N),
	case N of
	    %% NL layer
	    neighbours 	-> 0;
	    path_data 	-> 1;
	    neighbours_path -> 2;
	    path_addit -> 3;
	    data -> 4
	end).
