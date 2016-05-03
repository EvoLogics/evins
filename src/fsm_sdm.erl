%% Copyright (c) 2016, Oleksiy Kebkal <lesha@evologics.de>
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
-module(fsm_sdm).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  evins:rb(start),
  evins:logon(),
  SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(_MM, SM, Term) ->
  case Term of
    {sdmcli, {stop}} ->
      fsm:cast(SM, sdm, {send, {sdm, {stop}}});
    
    {sdmcli, {Cmd, FName}} when Cmd == tx; Cmd == ref->
      case file:read_file(FName) of
        {ok, Bin} ->
          CBin = convert_to_bin(Bin),
          ?INFO(?ID, "CBin size: ~p~n", [size(CBin)]),
          fsm:cast(SM, sdm, {send, {sdm, {Cmd, CBin}}});
        {error, Reason} ->
          ?ERROR(?ID, "Cannot open file ~p: ~p~n", [FName, Reason]),
          SM
      end;
    
    {sdmcli, {rx, Len, FName}} ->
      fsm:cast(env:put(SM, fname, FName), sdm,
               {send, {sdm, {rx, Len}}});
    
    {sdmcli, Cfg} ->
      fsm:cast(SM,sdm, {send, {sdm, Cfg}}); 

    {sdm, {stop}} ->
      fsm:cast(SM, sdmcli, {send, {sdmcli, {stop}}});

    {sdm, {rx, RX}} ->
      case env:get(SM, [fname, rest]) of
        [nothing, _] ->
          ?ERROR(?ID, "File not define to store rx~n", []),
          SM;
        [FName, Last] ->
          Rest =
            case RX of
              start ->
                file:write_file(FName, ""),
                <<>>;
              _ ->
                case filelib:file_size(FName) of
                  0 -> fsm:cast(SM, sdmcli, {send, {sdmcli, {rx}}});
                  _ -> nothing
                end,
                {R,S} = convert_from_bin(list_to_binary([Last,RX])),
                file:write_file(FName, S, [append]),
                R
            end,
          env:put(SM, rest, Rest)
      end;
    
    {sdm,{busy, Cmd}} ->
      fsm:cast(SM, sdmcli, {send, {sdmcli, {busy, Cmd}}});
    
    {sdm,{report,Cmd,Len}} ->
      fsm:cast(SM, sdmcli, {send, {sdmcli, {report, Cmd, Len}}});
    
    _ ->
      ?INFO(?ID, "Unhandled event: ~150p~n", [Term]),
      SM
  end.

convert_from_bin(B) ->
  S = size(B),
  X = S rem 2,
  {binary:part(B,{S,-X}),
   lists:flatten(convert_from_bin_helper(binary:part(B,{0,S-X}),""))}.

convert_from_bin_helper(<<>>, Acc) ->
  Acc;
convert_from_bin_helper(<<X:16/signed-little-integer,Rest/binary>>, Acc) ->
  [integer_to_list(X), "\n" | convert_from_bin_helper(Rest,Acc)].

convert_to_bin(L) ->
  list_to_binary(
    lists:map(
      fun(<<>>) -> <<>>;
         (BItem) -> <<(binary_to_integer(BItem)):16/signed-little-integer>>
      end, re:split(L,"\n"))).



