%% Copyright (c) 2017, Oleksiy Kebkal <lesha@evologics.de>
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
-module(role_nl_impl).
-behaviour(role_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

-record(config, {eol}).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  _ = {ok, busy, error, failed, delivered, send, recv, statistics}, %% atom vocabular
  _ = {?LIST_ALL_PROTOCOLS, polling},
  _ = {time, period},
  _ = {source, relay},
  _ = {sensitive, alarm, tolerant, broadcast},
  _ = {set, get, address, start, stop, protocolinfo, protocol, protocols, routing, neighbours, neighbour, state, states, paths, data, statistics, flush, polling, discovery, buffer, time},
  Cfg = #config{eol = "\r\n"},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl(_, Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

split(L, Cfg) ->
  case re:split(L,"\r?\n",[{parts,2}]) of
    [<<"?">>, Rest] ->
      [{nl, get, help} | split(Rest, Cfg)];
    [<<"NL,send,", _/binary>>, _] -> %% binary
      nl_send_extract(L, Cfg);
    [Answer, Rest] ->
      case re:run(Answer,"^NL,([^,]*),(.*)", [dotall, {capture, [1, 2], binary}]) of
        {match, [Subject, Params]} ->
          Reply = try nl_extract_subject(Subject, Params)
                  catch error:_ -> {nl, error, {parseError, Answer}}
                  end,
          [Reply | split(Rest, Cfg)];
        nomatch -> [{nl, error, {parseError, Answer}} | split(Rest, Cfg)]
      end;
    _ ->
      [{more, L}]
  end.

%% NL,send[,Type],[Datalen],Dst,Data
nl_send_extract(L, Cfg) ->
  try
    {match, [BType, BLen, BDst, Rest]} = re:run(L,"NL,send,([^0..9,]*?),?(\\d*),(\\d+),(.*)", [dotall, {capture, [1, 2, 3, 4], binary}]),
    PLLen = byte_size(Rest),

    Len = case BLen of
            <<>> ->
              [Bin, _] = re:split(Rest,"\r?\n",[{parts,2}]),
              byte_size(Bin);
            _ -> binary_to_integer(BLen)
          end,
    case re:run(Rest, "^(.{" ++ integer_to_list(Len) ++ "})\r?\n(.*)",[dotall,{capture,[1,2],binary}]) of
      {match, [Data, Tail]} ->
        Dst = binary_to_integer(BDst),
        Tuple =
          case BType of
            <<>> -> {nl, send, Dst, Data};
            _ -> {nl, send, binary_to_existing_atom(BType,utf8), Dst, Data}
          end,
        [Tuple | split(Tail, Cfg)];
      _ when Len + 1 =< PLLen ->
        %[{nl, error, {parseError, L}}];
        [{nl, send, error}];
      _ ->
        [{more, L}]
    end
  catch error: _Reason -> [{nl, error, {parseError, L}}]
  end.

%% NL,set,routing,[A1->A2],[A3->A4],..,default->Addr
nl_extract_subject(<<"set">>, <<"routing,", Params/binary>>) ->
  Map =
    lists:map(fun([<<"default">>,To]) ->
                  {default, binary_to_integer(To)};
                 ([From,To]) ->
                  {binary_to_integer(From), binary_to_integer(To)}
              end, [binary:split(V,<<"->">>) || V <- binary:split(Params,<<$,>>,[global])]),
  {nl,set,routing,Map};
%% NL,set,neighbours,A1,...,AN
%% NL,set,neighbours,A1:R1:I1:T1,...,AN:RN:IN:TN
nl_extract_subject(<<"set">>, <<"neighbours,", Params/binary>>) ->
  Lst = [binary:split(V, <<$:>>, [global]) || V <- binary:split(Params, <<$,>>, [global])],
  Neighbours =
    case lists:usort([length(Item) || Item <- Lst]) of
      [1] -> [binary_to_integer(Item) || [Item] <- Lst];
      [4] -> [list_to_tuple([binary_to_integer(I) || I <- Item]) || Item <- Lst]
    end,
  {nl, set, neighbours, Neighbours};
nl_extract_subject(<<"set">>, <<"debug,", Params/binary>>) ->
  Flag = case Params of
         <<"on">> -> on;
         <<"off">> -> off
       end,
  {nl,set,debug,Flag};

%% NL,set,polling,[Addr1,...,AddrN]
%% NL,set,polling,empty
nl_extract_subject(<<"set">>, <<"polling,empty">>) ->
  {nl, set, polling, []};
nl_extract_subject(<<"set">>, <<"polling,", Params/binary>>) ->
  Seq = [binary_to_integer(V) || V <- binary:split(Params,<<$,>>,[global])],
  {nl, set, polling, Seq};
%% NL,set,polling,start,[b|nb]
nl_extract_subject(<<"start">>, <<"polling,", Params/binary>>) ->
  Flag = case Params of
           <<"b">> -> b;
           <<"nb">> -> nb
         end,
  {nl,start,polling,Flag};
%% NL telegrams with atoms and positive integers as parameters
nl_extract_subject(Subject, Params) ->
  ParamLst =
    lists:map(fun(<<H:8,_/binary>> = Item) when H >= $0, H =< $9 -> binary_to_integer(Item);
                 (Item) -> binary_to_existing_atom(Item,utf8)
              end, [Subject | binary:split(Params,<<$,>>,[global])]),
  list_to_tuple([nl | ParamLst]).

from_term({nl, help, Bin}, Cfg) ->
  [Bin, Cfg];
%% NL,recv,Datalen,Src,Dst,Data
from_term({nl, recv, Src, Dst, Data}, Cfg) ->
  BLen = integer_to_binary(byte_size(Data)),
  [list_to_binary(["NL,recv,",BLen,$,,integer_to_binary(Src),$,,integer_to_binary(Dst),$,,Data,Cfg#config.eol]), Cfg];
%% NL,protocolinfo,Protocol,<EOL>Property1 : Value1<EOL>...PropertyN : ValueN<EOL><EOL>
from_term({nl,protocolinfo,Protocol,PropList}, Cfg) ->
  EOL = Cfg#config.eol,
  %% H = ["name : ",atom_to_list(Protocol),EOL],
  T = [[Key," : ",Value,EOL] || {Key,Value} <- PropList],
  [list_to_binary(["NL,protocolinfo,",atom_to_list(Protocol),$,,EOL,T,EOL]), Cfg];
%% NL,routing,[<A1>-><A2>],..,[default->Default]
from_term({nl, routing, []}, Cfg)  ->
  [list_to_binary(["NL,routing,","default->63",Cfg#config.eol]), Cfg];
from_term({nl, routing, Routing}, Cfg) when is_list(Routing) ->
  RoutingLst =
    lists:map(fun({default,To}) -> "default->" ++ integer_to_list(To);
                 ({From,To}) -> integer_to_list(From) ++ "->" ++ integer_to_list(To)
              end, Routing),
  [list_to_binary(["NL,routing,",lists:join(",",RoutingLst),Cfg#config.eol]), Cfg];
%% NL,neighbours,A1,...<AN>
from_term({nl, neighbours, []}, Cfg) ->
  [list_to_binary(["NL,neighbours,empty", Cfg#config.eol]), Cfg];
from_term({nl, neighbours, [H|_] = Neighbours}, Cfg) when is_number(H) ->
  NeighboursLst = [integer_to_list(A) || A <- Neighbours],
  [list_to_binary(["NL,neighbours,",lists:join(",",NeighboursLst),Cfg#config.eol]), Cfg];
%% NL,neighbours,A1:R1:I1:T1,...,AN:RN:IN:TN
from_term({nl, neighbours, Neighbours}, Cfg) when is_list(Neighbours) ->
  NeighboursLst =
    lists:map(fun(T) ->
                  lists:flatten(io_lib:format("~B:~B:~B:~B",tuple_to_list(T)))
              end, Neighbours),
  [list_to_binary(["NL,neighbours,",lists:join(",",NeighboursLst),Cfg#config.eol]), Cfg];
%% NL,state,State(Event)
from_term({nl, state, {State, Event}}, Cfg) ->
  [list_to_binary(["NL,state,",atom_to_list(State),$(,atom_to_list(Event),$),Cfg#config.eol]), Cfg];
%% NL,states,<EOL>State1(Event1)<EOL>...StateN(EventN)<EOL><EOL>
from_term({nl, states, []}, Cfg) ->
  EOL = Cfg#config.eol,
  [list_to_binary(["NL,states,empty",EOL]), Cfg];
from_term({nl, states, Transitions}, Cfg) ->
  EOL = Cfg#config.eol,
  TransitionsLst =
    lists:map(fun({State,Event}) ->
                  lists:flatten([atom_to_list(State),$(,atom_to_list(Event),$),EOL])
              end, Transitions),
  [list_to_binary(["NL,states,",EOL,lists:join(",",TransitionsLst),EOL]), Cfg];
%% NL,version,Major,Minor,Description
from_term({nl,version,Major,Minor,Description}, Cfg) ->
  EOL = Cfg#config.eol,
  [list_to_binary(["NL,version,",integer_to_list(Major),$,,integer_to_list(Minor),$,,Description,EOL]), Cfg];

from_term({nl,buffer,Report}, Cfg) when is_atom(Report) ->
  EOL = Cfg#config.eol,
  [list_to_binary(["NL,buffer,",atom_to_list(Report),EOL,EOL]), Cfg];

from_term({nl,statistics,Type,Report}, Cfg) when is_atom(Type), is_atom(Report) ->
  EOL = Cfg#config.eol,
  [list_to_binary(["NL,statistics,",atom_to_list(Type),$,,atom_to_list(Report),EOL,EOL]), Cfg];
%% NL,statistics,neighbours,<EOL> <relay or source> neighbours:<neighbours> count:<count> total:<total><EOL>...<EOL><EOL>
%% NL,statistics,neighbours,
%%  source neighbour:3 count:8 total:10
%%  source neighbour:2 count:4 total:10
from_term({nl,statistics,neighbours,Neighbours}, Cfg) ->
  EOL = Cfg#config.eol,
  NeighboursLst =
    lists:map(fun({Neighbour,Time,Count,Total}) ->
                  lists:flatten([io_lib:format("neighbour:~p last update:~B count:~B total:~B",[Neighbour,Time,Count,Total]),EOL])
              end, Neighbours),
  [list_to_binary(["NL,statistics,neighbours,",EOL,NeighboursLst,EOL]), Cfg];
%% NL,statistics,paths,<EOL> <relay or source> path:<path> duration:<duration> count:<count> total:<total><EOL>...<EOL><EOL>
%% NL,statistics,paths,
%%  source path:1,2,3 duration:10 count:1 total:2
%%  source path:1,2,4,3 duration:12 count:1 total:2
from_term({nl,statistics,paths,Paths}, Cfg) ->
  EOL = Cfg#config.eol,
  PathsLst =
    lists:map(fun({Role,Path,Duration,Count,Total}) ->
                  PathS = lists:flatten(lists:join(",",[integer_to_list(I) || I <- Path])),
                  lists:flatten([io_lib:format(" ~p path:~s duration:~.1.0f count:~B total:~B",[Role,PathS,Duration,Count,Total]),EOL])
              end, Paths),
  [list_to_binary(["NL,statistics,paths,",EOL,PathsLst,EOL]), Cfg];
%% NL,statistics,data,<EOL> <relay or source> data:<data hash> len:<length> duration:<duration> state:<state> total:<total> dst:<dst> hops:<hops><EOL>...<EOL><EOL>
%% NL,statistics,data,
%%  source data:0xabde len:4 duration:5.6 state:delivered total:1 dst:4 hops:1
%%  source data:0x1bdf len:4 duration:11.4 state:delivered total:1 dst:4 hops:2
%%  source data:0xabdf len:4 duration:9.9 state:delivered total:1 dst:4 hops:2
from_term({nl,statistics,data,Data}, Cfg) ->
  EOL = Cfg#config.eol,
  DataLst =
    lists:map(fun(Element) ->
              case Element of
                {Role,Hash,Len,Duration,State,Total,Dst,Hops} ->
                    lists:flatten([io_lib:format(" ~p data:0x~4.16.0b len:~B duration:~.1.0f state:~s total:~B dst:~B hops:~B",
                                                 [Role,Hash,Len,Duration,State,Total,Dst,Hops]),EOL]);
                {Role,Hash,Send_Time,Recv_Time,Src,Dst,TTL} ->
                    lists:flatten([io_lib:format(" ~p data:0x~4.16.0b send_time:~p recv_time:~p src:~B dst:~B last_ttl:~B",
                                                 [Role,Hash,Send_Time,Recv_Time,Src,Dst,TTL]),EOL])
              end
            end, Data),
  [list_to_binary(["NL,statistics,data,",EOL,DataLst,EOL]), Cfg];
%% NL,protocols,Protocol1,...,ProtocolN
from_term({nl,protocols,Protocols}, Cfg) ->
  [list_to_binary(["NL,protocols,",lists:join(",", [atom_to_binary(P,utf8) || P <- Protocols]),Cfg#config.eol]), Cfg];
%% NL,polling,Addr,...,AddrN
from_term({nl,polling,[]}, Cfg) ->
  [list_to_binary(["NL,polling,empty", Cfg#config.eol]), Cfg];
from_term({nl,polling,Sequence}, Cfg) when is_list(Sequence) ->
  [list_to_binary(["NL,polling,",lists:join(",", [integer_to_binary(P) || P <- Sequence]),Cfg#config.eol]), Cfg];
%% NL,time,monotonic,Time
from_term({nl,time,monotonic,Time}, Cfg) when is_integer(Time) ->
  [list_to_binary(["NL,time,monotonic,", integer_to_binary(Time),Cfg#config.eol]), Cfg];
from_term({nl, buffer, []}, Cfg) ->
  EOL = Cfg#config.eol,
  [list_to_binary(["NL,buffer,",atom_to_list(empty),EOL,EOL]), Cfg];
from_term({nl, buffer, Buffer}, Cfg) when is_list(Buffer) ->
  EOL = Cfg#config.eol,
  BufferLst = lists:map(fun({Payload, Dst, XMsgType}) ->
                  lists:flatten([io_lib:format("data:~p dst:~B type:~s",
                  [Payload, Dst, XMsgType]), EOL])
              end, Buffer),
  [list_to_binary(["NL,buffer,",EOL, BufferLst, EOL]), Cfg];

%% NL command with atoms or integers
from_term(Tuple, Cfg) ->
  try
    Lst =
      lists:map(fun(nl) -> <<"NL">>;
                   (I) when is_number(I) -> integer_to_binary(I);
                   (A) when is_atom(A) -> atom_to_binary(A,utf8)
                end, tuple_to_list(Tuple)),
    [list_to_binary([lists:join(",", Lst),Cfg#config.eol]), Cfg]
  catch error:_ -> {error, {formError, Tuple}}
  end.
