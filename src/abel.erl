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
-module(abel).
-export([diff/2,diff/3,diff32/2,diff16/2,diff8/2,add/3,add32/2,add16/2,add8/2,gt/2,mod/2,div_mod/2,inc/1,dec/1,eq/2,timestamp_sub/2]).

%% Returns the positive remainder of the division of X by Y, in [0;Y[. 
%% In Erlang, -5 rem 3 is -2, whereas this function will return 1,  
%% since -5 =-2 * 3 + 1.
mod(X,Y) when X > 0 -> X rem Y;
mod(X,Y) when X < 0 -> Y + X rem Y;
mod(0,_Y) -> 0.

div_mod(X,Y) when X >= 0 -> {X div Y, X rem Y};
div_mod(X,Y) -> {-1 + (X div Y), Y + X rem Y}.

%% T1 - T2
timestamp_sub({MgS1,S1,McS1}, {MgS2, S2, McS2}) ->
  {DS, McS} = div_mod(McS1 - McS2, 1000000),
  {DMgS, S} = div_mod(S1 - S2 + DS, 1000000),
  MgS = MgS1 - MgS2 + DMgS,
  {MgS, S, McS}.

inc({V,P}) -> {mod(V+1,P),P}.
dec({V,P}) -> {mod(V-1,P),P}.

%% cyclic number {Value,Period}
diff({V1,P},{V2,P}) ->
  D1 = mod(V1 - V2, P),
  D2 = mod(V2 - V1, P),
  case D1 > D2 of
    true -> -D2;
    _ -> D1
  end.

diff(V1,V2,P) -> diff({V1,P},{V2,P}).

diff32(V1,V2) -> diff(V1,V2,16#100000000).
diff16(V1,V2) -> diff(V1,V2,16#10000).
diff8(V1,V2) -> diff(V1,V2,16#100).

add(V1,V2,P) -> mod(V1 + V2, P).

add32(V1,V2) -> add(V1,V2,16#100000000).
add16(V1,V2) -> add(V1,V2,16#10000).
add8(V1,V2) -> add(V1,V2,16#100).

%% greater then
gt({_, P} = N1, {_, P} = N2) -> diff(N1, N2) > 0.

%% equal
eq({V1, P}, {V2, P}) when is_number(V1), is_number(V2), is_number(P) -> V1 =:= V2.


