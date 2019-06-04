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
-module(fsm_inv_usbl_gen).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> [share:put(SM, heading, 0),
                   share:put(__, sound_velocity, 1500)](SM).
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(_MM, SM, Term) ->
    LAddr = share:get(SM, local_address),
    RAddr = env:get(SM, remote_address),
    Pid = env:get(SM, pid),

    case Term of
        {allowed} ->
            fsm:send_at_command(SM, {at, "?CA", ""});

        {sync, "?CA", SVelStr} ->
            SVel = list_to_integer(SVelStr),
            [share:put(__, sound_velocity, SVel),
             fsm:clear_timeout(__, answer_timeout),
             sendRequest(__, Pid, RAddr, nothing)](SM);

        {denied} ->
            fsm:clear_timeout(SM, ping_timeout);

        {timeout, Timeout} when Timeout =:= ping_timeout; Timeout =:= ping_delay ->
            Distance = share:get(SM, distance),
            [fsm:clear_timeout(__, Timeout),
             sendRequest(__, Pid, RAddr, Distance)](SM);

        {async, {pid, Pid}, {recvpbm, _, RAddr, LAddr, _, _, _, _, Payload}} ->
            io:format("IM: angles: ~p~n", [extractReply(Payload)]),
            SM;

        {async, {deliveredim, RAddr}} ->
            fsm:send_at_command(SM, {at, "?T", ""});

        {sync, "?T", PTimeStr} ->
            PTime = list_to_integer(PTimeStr),
            PingDelay = env:get(SM, ping_delay),
            SVel = share:get(SM, sound_velocity),
            Distance = PTime * SVel * 1.0e-6,
            io:format("IM: measured distance: ~.2f~n", [Distance]),
            [share:put(__, distance, Distance),
             fsm:clear_timeout(__, answer_timeout),
             fsm:clear_timeout(__, ping_timeout),
             fsm:set_timeout(__, {ms, PingDelay}, ping_delay)](SM);

        {async, {sendend, RAddr, "ims", STime, _}} ->
            share:put(SM, send_time, STime);

        {async, {pid, Pid}, {recvims, _, RAddr, LAddr, RTime, _, _, _, _, Payload}} ->
            io:format("IMS: angles: ~p~n", [extractReply(Payload)]),
            PingDelay = env:get(SM, ping_delay),
            Distance =
            case share:get(SM, send_time) of
                STime when is_integer(STime) ->
                    AnswerDelay = env:get(SM, answer_delay),
                    SVel = share:get(SM, sound_velocity),
                    PTime = (RTime - STime - AnswerDelay * 1000) / 2,
                    PTime * SVel * 1.0e-6;
                _ -> nothing
            end,
            case Distance of
                nothing -> nothing;
                _ -> io:format("IMS: measured distance: ~.2f~n", [Distance])
            end,
            [share:put(__, distance, Distance),
             fsm:clear_timeout(__, ping_timeout),
             fsm:set_timeout(__, {ms, PingDelay}, ping_timeout)](SM);

        {sync, _, _} ->
            fsm:clear_timeout(SM, answer_timeout);

        {nmea, {hdt, Heading}} ->
            share:put(SM, heading, Heading);

        _ -> SM
    end.

sendRequest(SM, Pid, RAddr, Distance) ->
    Heading = share:get(SM, heading),
    Payload = case Distance of
                  nothing -> <<"N">>;
                  _ ->
                      [D, H] = [round(X * 10) || X <- [Distance, Heading]],
                      <<"D", D:16/little-unsigned-integer,
                             H:12/little-unsigned-integer, 0:4>>
              end,
    AT =
    case env:get(SM, mode) of
        im  -> {at, {pid, Pid}, "*SENDIM", RAddr, ack, Payload};
        ims -> {at, {pid, Pid}, "*SENDIMS", RAddr, none, Payload}
    end,
    PingTimeout = env:get(SM, ping_timeout),
    [share:put(__, distance, nothing),
     fsm:send_at_command(__, AT),
     fsm:set_timeout(__, {ms, PingTimeout}, ping_timeout)](SM).

extractReply(Payload) ->
    case Payload of
        <<"L", Bearing:12/little-unsigned-integer,
               Elevation:12/little-unsigned-integer,
               Roll:12/little-unsigned-integer,
               Pitch:12/little-unsigned-integer,
               Yaw:12/little-unsigned-integer, _/bitstring>> ->
            lists:map(fun(A) -> A / 10 end, [Bearing, Elevation, Roll, Pitch, Yaw]);
        _ -> nothing
    end.
