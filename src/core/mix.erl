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
-module(mix).
-export([microseconds/0, milliseconds/0, seconds/0, binary_to_number/1, todo/3]).

-include("fsm.hrl").

-spec todo(any(), any(), any()) -> no_return(). 
todo(Module, Line, ID) ->
    ioc:format(Module, Line, ID, "TODO~n", [], red),
    exit({todo,Module,Line,ID}).

milliseconds() ->
    microseconds() div 1000.

seconds() ->
    {Mega,S,_} = os:timestamp(),
    Mega*1000000 + S.
    
microseconds() ->
    {Mega,S,Micro} = os:timestamp(),
    (Mega*1000000 + S)*1000000 + Micro.

%% accept any number representation
%% 10   10. 10.1 10.0e-1 .01 .01e-1 00.000
binary_to_number(V) when is_binary(V) ->
    case re:split(V,"\\.") of
	[]       -> error(baderg);
	[A]      -> float(binary_to_integer(A));
	[A,<<>>] -> float(binary_to_integer(A));
	[<<>>,B] -> binary_to_float(<<"0.",B/binary>>);
	[_,_]    -> binary_to_float(V);
	_        -> error(badarg)
    end;
binary_to_number(_) -> erlang:error(badarg).


