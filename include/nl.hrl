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

-define(BITS_PKG_ID, 8).
-define(BITS_ADDRESS, 6).

-define(NEIGHBOURS, 	"n:(.*)").
-define(PATH_DATA, 	"p:(.*),d:(.*)").
-define(NEIGHBOUR_PATH, "n:(.*),p:(.*)").
-define(PATH_ADDIT,  	"p:(.*),a:(.*)").

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

-record(pr_conf,{brp=false, br_na=false, ack=false, ry_only=false, pf=false, prob=false, dbl=false, evo=false, lo=false, rm=false}).

-define(LIST_ALL_PARAMS, [brp,		% broadcast path on Dst, not follow path in unicast mode
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

-define(PROTOCOL_CONF, [
			{staticr,	[0, {ry_only},             	fsm_nl_flood]},	% Simple static routing
			{staticrack, 	[1, {ry_only, br_na, ack},  	fsm_nl_flood]},	% Simple static routing with acknowledgement
			{sncfloodr,  	[2, {ry_only},              	fsm_nl_flood]},	% Sequence number controlled flooding
			{sncfloodrack, 	[3, {ry_only, br_na, ack},  	fsm_nl_flood]},	% Sequence number controlled flooding with acknowledgement
			{dpfloodr,		[4, {ry_only, prob},    fsm_nl_flood]},	% Dynamic Probabilistic Flooding
			{dpfloodrack,	[5, {ry_only, prob, br_na, ack},fsm_nl_flood]},	% Dynamic Probabilistic Flooding with acknowledgement
			{icrpr,		[6, {ry_only, pf, br_na, ack},  fsm_nl_flood]},	% Information Carrying Routing Protocol
			{sncfloodpfr,	[7, {pf, brp, br_na},           fsm_nl_flood]},	% Pathfind and relay, based on sequence number controlled flooding
			{sncfloodpfrack,[7, {pf, brp, br_na, ack},      fsm_nl_flood]},	% Pathfind and relay, based on sequence number controlled flooding with acknowledgement
			{dblfloodpfr,	[7, {pf, dbl, br_na},       	fsm_nl_flood]},	% Double flooding path finder
			{dblfloodpfrack,[7, {pf, dbl, br_na, ack},  	fsm_nl_flood]},	% Double flooding path finder with acknowledgement
			{evoicrppfr,	[7, {pf, br_na, lo, evo},       fsm_nl_flood]},	% Evologics Information Carrying routing protocol
			{evoicrppfrack, [6, {pf, br_na, lo, evo, ack},  fsm_nl_flood]},	% Evologics Information Carrying routing protocol with acknowledgement
			{loarpr,	[7, {pf, br_na, lo, rm},	fsm_nl_flood]},	% Low overhead routing protocol
			{loarprack,	[7, {pf, br_na, lo, rm, ack},	fsm_nl_flood]}	% Low overhead routing protocol with acknowledgement
		       ]).

-define(PROTOCOL_DESCR, ["\n",
			 "staticr        - simple static routing, in config file f.e. {routing,{{7,1},2}}\n",
			 "staticrack     - simple static routing with acknowledgement, in config file f.e. {routing,{{7,1},2}}\n",
			 "sncfloodr      - sequence number controlled flooding\n",
			 "sncfloodrack   - sequence number controlled flooding with acknowledgement\n",
			 "sncfloodpfr    - pathfind and relay to destination\n",
			 "sncfloodpfrack - pathfind and relay to destination with acknowledgement\n",
			 "evoicrppfr     - Evologics ICRP pathfind and relay, path is chosend using Rssi and Integrity of Evo DMACE Header\n"
			 "evoicrppfrack  - Evologics ICRP pathfind and relay, path is chosend using Rssi and Integrity of Evo DMACE Header with acknowledgement\n"
			 "dblfloodpfr    - double flooding path finder, based on 3 waves, going through the network to find path\n"
			 "dblfloodpfrack - double flooding path finder, based on 3 waves, going through the network to find path with acknowledgement\n"
			 "dpfloodr       - dynamic probabilistic flooding\n"
			 "dpfloodrack    - dynamic probabilistic flooding with acknowledgement\n"
			 "icrpr          - information carrying routing protocol\n"
			 "loarp          - low overhead routing protocol\n"
			 "loarpack       - low overhead routing protocol with acknowledgement\n"
			]).

-define(STATE_DESCR,
	[{idle,	"Ready to proccess data\n"},
	 {swv,	"Sending data\n"},
	 {rwv,	"Receiving data\n"},
	 {wack,	"Waiting for acknowledgement\n"},
	 {sack,	"Sending acknowledgement\n"},
	 {wpath,"Waiting for path\n"},
	 {spath,"Sending for path\n"}]).

-define(PROTOCOL_SPEC(P),
	lists:foldr(fun(X,A) ->
			    case X of
				ry_only when P#pr_conf.ry_only 	  -> ["Type\t\t: Only relay\n"  | A];
				ack 	when P#pr_conf.ack 	  -> ["Ack\t\t: true\n"  | A];
				ack	when not P#pr_conf.ack 	  -> ["Ack\t\t: false\n" | A];
				br_na	when P#pr_conf.br_na 	  -> ["Broadcast\t: not available\n" | A];
				br_na 	when not P#pr_conf.br_na  -> ["Broadcast\t: available\n" | A];
				pf 	when P#pr_conf.pf	  -> ["Type\t\t: Path finder\n" | A];
				evo 	when P#pr_conf.evo	  -> ["Specifics\t: Evologics DMACE Rssi and Integrity\n" | A];
				dbl 	when P#pr_conf.dbl	  -> ["Specifics\t: 2 waves are used to find path, find two way links\n" | A];
				rm 	when P#pr_conf.rm	  -> ["Route maintenance\n" | A];
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
			      {255, 255}
			     ]).

-define(FLAGMAX, 5).

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
