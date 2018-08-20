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
-module(role_at_impl).
-behaviour(role_worker).
-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

-include("fsm.hrl").

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  EOL = case lists:keyfind(eol,1,MM#mm.params) of
          {eol,Other} -> Other;
          _ -> "\n"
        end,
  Cfg = #{filter => net, mode => command, eol => EOL, pid => 0},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl({pid, P}, Cfg) -> Cfg#{pid => P};
ctrl(_,Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

%% AT*SEND...
%% AT<CMD>
%% AT<PREFIX><CMD><value>
%% AT<key>$
split(L, Cfg) ->
  EOL = maps:get(eol, Cfg),
  try
    case re:split(L,EOL,[{parts,2}]) of
      [<<"AT*SEND,", _/binary>>, _]    -> at_send_extract(send,L, Cfg);
      [<<"AT*SENDIM,", _/binary>>, _]  -> at_send_extract(sendim, L, Cfg);
      [<<"AT*SENDIMS,", _/binary>>, _] -> at_send_extract(sendims, L, Cfg);
      [<<"AT*SENDPBM,", _/binary>>, _] -> at_send_extract(sendpbm, L, Cfg);
      [Answer, Rest] ->
        case re:run(Answer,"AT([?@&!]?[^0-9]*)(.*)", [dotall, {capture, [1, 2], list}]) of
          {match, [Cmd, Param]} -> [{at, Cmd, Param} | split(Rest, Cfg)];
          nomatch -> [{raw, list_to_binary([Answer,EOL])} | split(Rest, Cfg)]
        end;
      _ ->
        [{more, L}]
    end
  catch error:_ ->
      [{raw, L}]
  end.

%% AT*SEND,[p<pid>,]<len>,<dst>,<data>
at_send_extract(send, L, Cfg) ->
  RE = "AT\\*SEND(,p([0-9]*))?,(\\d+),(\\d+),(.*)",
  {match, [_, BPID, BLen, BDst, Rest]} = re:run(L,RE, [dotall, {capture, [1, 2, 3, 4, 5], binary}]),
  parse_send_payload(send, Rest, BLen, BPID, [BDst], L, Cfg);
%% AT*SENDPBM,[p<pid>,]<len>,<dst>,<data>
at_send_extract(sendpbm, L, Cfg) ->
  RE = "AT\\*SENDPBM(,p([0-9]*))?,(\\d+),(\\d+),(.*)",
  {match, [_, BPID, BLen, BDst, Rest]} = re:run(L,RE, [dotall, {capture, [1, 2, 3, 4, 5], binary}]),
  parse_send_payload(sendpbm, Rest, BLen, BPID, [BDst], L, Cfg);
%% AT*SENDIM,[p<pid>,]<len>,<dst>,<flag>,<data>
at_send_extract(sendim, L, Cfg) ->
  RE = "AT\\*SENDIM(,p([0-9]*))?,(\\d+),(\\d+),([^,]+),(.*)",
  {match, [_, BPID, BLen, BDst, BFlag, Rest]} = re:run(L,RE, [dotall, {capture, [1, 2, 3, 4, 5, 6], binary}]),
  parse_send_payload(sendim, Rest, BLen, BPID, [BDst, BFlag], L, Cfg);
%% AT*SENDIMS,[p<pid>,]<len>,<dst>,<ref_usec>,<data>
at_send_extract(sendims, L, Cfg) ->
  RE = "AT\\*SENDIMS(,p([0-9]*))?,(\\d+),(\\d+),(\\d*),(.*)",
  {match, [_, BPID, BLen, BDst, BUSEC, Rest]} = re:run(L,RE, [dotall, {capture, [1, 2, 3, 4, 5, 6], binary}]),
  parse_send_payload(sendims, Rest, BLen, BPID, [BDst, BUSEC], L, Cfg).

parse_send_payload(Type, Rest, BLen, BPID, Custom, L, Cfg) ->
  EOL = maps:get(eol, Cfg),
  PLLen = byte_size(Rest),
  Len = binary_to_integer(BLen),
  case re:run(Rest, "^(.{" ++ integer_to_list(Len) ++ "})" ++ EOL ++ "(.*)",[dotall,{capture,[1,2],binary}]) of
    {match, [Data, Tail]} ->
      PID = case BPID of
              <<>> -> maps:get(pid, Cfg);
              _ -> binary_to_integer(BPID)
            end,
      Dst = binary_to_integer(hd(Custom)),
      Tuple = 
        case Type of
          sendims ->
            USEC = case lists:nth(2,Custom) of
                     <<>> -> none;
                     BUSEC -> binary_to_integer(BUSEC)
                   end,
            {at,{pid,PID},"*SENDIMS",Dst,USEC,Data};
          sendim ->
            Flag = binary_to_atom(lists:nth(2,Custom), utf8),
            {at,{pid,PID},"*SENDIM",Dst,Flag,Data};          
          send ->
            {at,{pid,PID},"*SEND",Dst,Data};
          sendpbm ->
            {at,{pid,PID},"*SENDPBM",Dst,Data}
        end,
      [Tuple | split(Tail, Cfg)];
    _ when Len + 1 =< PLLen ->
      [{raw, L}];
    _ ->
      [{more, L}]
  end.  

from_term({sync,_, {Type,Reason}}, Cfg) ->
  SType = case Type of error -> "ERROR"; busy -> "BUSY" end,
  [list_to_binary([SType, " ", Reason, "\r\n"]), Cfg];

from_term({sync,_, {noise,Len,I1,I2,I3,Payload}}, Cfg) ->
  Data = io_lib:format("NOISE,~b,~b,~b,~b,",[Len,I1,I2,I3]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({sync, _, Sync}, Cfg) ->
  [list_to_binary([Sync,"\r\n"]), Cfg];

from_term({async, {recvpbm,Len,S,D,Dur,R,I,V,Payload}}, Cfg) ->
  Data = io_lib:format("RECVPBM,~b,~b,~b,~b,~b,~b,~.2.0f,",[Len,S,D,Dur,R,I,V]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({async, {pid, Pid}, {recvpbm,Len,S,D,Dur,R,I,V,Payload}}, Cfg) ->
  Data = io_lib:format("RECVPBM,p~b,~b,~b,~b,~b,~b,~b,~.2.0f,",[Pid,Len,S,D,Dur,R,I,V]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({async, {recvim,Len,S,D,Flag,Dur,R,I,V,Payload}}, Cfg) ->
  Data = io_lib:format("RECVIM,~b,~b,~b,~p,~b,~b,~b,~.2.0f,",[Len,S,D,Flag,Dur,R,I,V]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({async, {pid, Pid}, {recvim,Len,S,D,Flag,Dur,R,I,V,Payload}}, Cfg) ->
  Data = io_lib:format("RECVIM,p~b,~b,~b,~b,~p,~b,~b,~b,~.2.0f,",[Pid,Len,S,D,Flag,Dur,R,I,V]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({async, {Recv,Len,S,D,X,Dur,R,I,V,Payload}}, Cfg) ->
  SRecv = case Recv of recv -> "RECV"; recvims -> "RECVIMS" end,
  Data = io_lib:format("~s,~b,~b,~b,~b,~b,~b,~b,~.2.0f,", [SRecv,Len,S,D,X,Dur,R,I,V]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({async, {pid, Pid}, {Recv,Len,S,D,X,Dur,R,I,V,Payload}}, Cfg) ->
  SRecv = case Recv of recv -> "RECV"; recvims -> "RECVIMS" end,
  Data = io_lib:format("~s,p~b,~b,~b,~b,~b,~b,~b,~b,~.2.0f,", [SRecv,Pid,Len,S,D,X,Dur,R,I,V]),
  [list_to_binary([Data,Payload,"\r\n"]), Cfg];

from_term({async, Async}, Cfg) ->
  Data = 
    case Async of
      {recvstart} ->
        "RECVSTART";
      {recvend,Usec,Dur,R,I} ->
        io_lib:format("RECVEND,~b,~b,~b,~b",[Usec,Dur,R,I]);
      {recvfailed,V,R,I} ->
        io_lib:format("RECVFAILED,~.2.0f,~b,~b",[V,R,I]);
      {phyoff} ->
        "PHYOFF";
      {phyon} ->
        "PHYON";
      {sendstart,Addr,Type,Dur,Delay} ->
        io_lib:format("SENDSTART,~b,~s,~b,~b",[Addr,Type,Dur,Delay]);
      {sendend,Addr,Type,Usec,Dur} ->
        io_lib:format("SENDEND,~b,~s,~b,~b",[Addr,Type,Usec,Dur]);
      {usbllong,F1,F2,I1,F3,F4,F5,F6,F7,F8,F9,F10,F11,I2,I3,I4,F12} ->
        io_lib:format("USBLLONG,~.2.0f,~.2.0f,~b,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~b,~b,~b,~.2.0f",
                      [F1,F2,I1,F3,F4,F5,F6,F7,F8,F9,F10,F11,I2,I3,I4,F12]);
      {usblangles,F1,F2,I1,F3,F4,F5,F6,F7,F8,F9,I2,I3,F10} ->
        io_lib:format("USBLANGLES,~.2.0f,~.2.0f,~b,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~b,~b,~.2.0f",
                      [F1,F2,I1,F3,F4,F5,F6,F7,F8,F9,I2,I3,F10]);
      {usblphyd,F1,F2,I1,I2,I3,I4,I5,I6,I7,I8,I9,I10} ->
        io_lib:format("USBLPHYD,~.2.0f,~.2.0f,~b,~b,~b,~b,~b,~b,~b,~b,~b,~b",
                      [F1,F2,I1,I2,I3,I4,I5,I6,I7,I8,I9,I10]);
      {usblphyp,F1,F2,I1,I2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12,F13,F14,F15,F16,F17,F18,F19,F20} ->
        io_lib:format("USBLPHYP,~.2.0f,~.2.0f,~b,~b,~.2.0f,~.2.0f,~.2.0f,~.2.0f," ++
                        "~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f,~.2.0f",
                      [F1,F2,I1,I2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12,F13,F14,F15,F16,F17,F18,F19,F20]);
      {bitrate,Dir,Val} ->
        io_lib:format("BITRATE,~p,~b",[Dir,Val]);
      {raddr,Val} ->
        io_lib:format("RADDR,~b",[Val]);
      {delivered, Cnt, Dst} ->
        io_lib:format("DELIVERED,~b,~b",[Cnt,Dst]);
      {deliveredim, Dst} ->
        io_lib:format("DELIVEREDIM,~b",[Dst]);
      {failed, Cnt, Dst} ->
        io_lib:format("FAILED,~b,~b",[Cnt,Dst]);
      {failedim, Dst} ->
        io_lib:format("FAILEDIM,~b",[Dst]);
      {canceledim, Dst} ->
        io_lib:format("CANCELEDIM,~b",[Dst]);
      {canceledims, Dst} ->
        io_lib:format("CANCELEDIMS,~b",[Dst]);
      {canceledpbm, Dst} ->
        io_lib:format("CANCELEDPBM,~b",[Dst]);
      {expiredims, Dst} ->
        io_lib:format("EXPIREDIMS,~b",[Dst]);
      {srclevel,Val} ->
        io_lib:format("SRCLEVEL,~b",[Val]);
      {dropcnt,Val} ->
        io_lib:format("DROPCNT,~b",[Val]);
      {eclk,Mono,Clk,Steer,Event,GPS} ->
        io_lib:format("ECLK,~.6.0f,~b,~b,~p,~.6.0f",[Mono,Clk,Steer,Event,GPS]);
      {error, Reason} ->
        ["ERROR ", Reason];
      _Other ->
        io:format("Error: not handled data~p~n", [_Other]),
        ""
    end,
  [list_to_binary([Data,"\r\n"]), Cfg].
