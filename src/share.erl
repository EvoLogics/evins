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
-module(share).
-include("fsm.hrl").

-export([init/0, delete/1, get/2, get/3, get/4, put/2, put/3, put/4, clean/2]).
-export([update_with/3, update_with/4, update_with/5, match/2]).
         
init() ->
  ets:new(table, [ordered_set, public]).

delete(#sm{share = ID}) ->
  ets:delete(ID).

get(SM, Key) ->
  get(SM, nothing, Key, nothing).

get(SM, Category, Key) ->
  get(SM, Category, Key, nothing).

get(#sm{share = ID}, nothing, Key, Default) ->
  case ets:lookup(ID, Key) of
    [{_, Value}] -> Value;
    _ -> Default
  end;

get(#sm{share = ID}, Category, Key, Default) ->
  case ets:lookup(ID, {Category, Key}) of
    [{_, Value}] -> Value;
    _ -> Default
  end.

put(SM, Lst) when is_list(Lst) ->
  lists:foreach(fun({Key,Value}) -> put(SM, Key, Value) end, Lst), SM.

put(#sm{share = ID} = SM, Key, Value) ->
  ets:insert(ID, {Key, Value}), SM.

put(#sm{share = ID} = SM, Category, Key, Value) ->
  ets:insert(ID, {{Category, Key}, Value}), SM.

update_with(SM, Key, Fun) when is_function(Fun) ->
  put(SM, Key, Fun(get(SM, Key))), SM.

update_with(SM, Key, Fun, Init) when is_function(Fun) ->
  put(SM, Key, Fun(get(SM, nothing, Key, Init))), SM;

update_with(SM, Category, Key, Fun) when is_function(Fun) ->
  put(SM, Category, Key, Fun(get(SM, Category, Key))), SM.

update_with(SM, Category, Key, Fun, Init) when is_function(Fun) ->
  put(SM, Category, Key, Fun(get(SM, Category, Key, Init))), SM.

clean(SM, Category_and_Key) ->
  ets:match_delete(SM#sm.share, {{Category_and_Key, '_'}, '_'}),
  ets:match_delete(SM#sm.share, {Category_and_Key, '_'}),
  SM.

match(SM, Pattern) ->
  ets:match(SM#sm.share, Pattern).
