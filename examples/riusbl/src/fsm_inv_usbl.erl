%% Copyright (c) 2016, Veronika Kebkal <veronika.kebkal@evologics.de>
%% Copyright (c) 2018, Oleksandr Novychenko <novychenko@evologics.de>
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
-module(fsm_inv_usbl).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(_MM, SM, Term) ->
    LAddr = share:get(SM, local_address),
    Pid = env:get(SM, pid),

    case Term of
        {async,  {pid, Pid}, {recvim, _, RAddr, LAddr, ack, _, _, _, _, Payload}} ->
            showRequest(Payload),
            share:put(SM, req, {im, RAddr});

        {async, {pid, Pid}, {recvims, _, RAddr, LAddr, RTime, _, _, _, _, Payload}} ->
            showRequest(Payload),
            Delay = env:get(SM, answer_delay),
            share:put(SM, req, {ims, RAddr, RTime + Delay * 1000});

        {async, {usblangles, _, _, RAddr, _, _, _, _, _, _, _, _, _, -1.0}} ->
            case share:get(SM, req) of
                {ims, Pid, RAddr, STime} ->
                    fsm:send_at_command(SM, {at, {pid, Pid}, "*SENDIMS", RAddr, STime, <<"N">>});

                _ -> SM
            end,
            share:put(SM, req, nothing);

        {async, {usblangles, _, _, RAddr, Bearing, Elevation, _, _, Roll, Pitch, Yaw, _, _, _}} ->
            Msg = createReply([Bearing, Elevation, Roll, Pitch, Yaw]),
            SM1 =
            case share:get(SM, req) of
                {ims, RAddr, STime} ->
                    fsm:send_at_command(SM, {at, {pid, Pid}, "*SENDIMS", RAddr, STime, Msg});

                {im, RAddr} ->
                    fsm:send_at_command(SM, {at, {pid, Pid}, "*SENDPBM", RAddr, Msg});

                _ -> SM
            end,
            share:put(SM1, req, nothing);

        {sync, _, _} ->
            fsm:clear_timeout(SM, answer_timeout);

        _ -> SM
    end.

-ifndef(floor_bif).
floor(X) when X < 0 ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T - 1
    end;
floor(X) ->
    trunc(X).
-endif.

smod(X, M)  -> X - floor(X / M + 0.5) * M.
%wrap_pi(A) -> smod(A, -2*math:pi()).
wrap_2pi(A) -> smod(A - math:pi(), 2*math:pi()) + math:pi().

createReply(Angles) ->
    [Bearing, Elevation, Roll, Pitch, Yaw] = lists:map(fun(A) -> trunc(wrap_2pi(A) * 1800 / math:pi()) end, Angles),
    BinMsg = <<Bearing:12/little-unsigned-integer,
               Elevation:12/little-unsigned-integer,
               Roll:12/little-unsigned-integer,
               Pitch:12/little-unsigned-integer,
               Yaw:12/little-unsigned-integer>>,
    Padding = (8 - (bit_size(BinMsg) rem 8)) rem 8,
    <<"L", BinMsg/bitstring, 0:Padding>>.

showRequest(Payload) ->
    case Payload of
        <<"D", Distance:16/little-unsigned-integer,
          Heading:12/little-unsigned-integer, _/bitstring>> ->
            %io:format("Distance: ~.2f, Heading: ~.2f~n", [Distance / 10, Heading / 10]),
            {Distance / 10, Heading / 10};

        <<"D", Distance:16/little-unsigned-integer, _/binary>> ->
            %io:format("Distance: ~.2f~n", [Distance / 10]),
            {Distance / 10, nothing};

        _ -> {nothing, nothing}
    end.
