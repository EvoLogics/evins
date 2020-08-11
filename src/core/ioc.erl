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
-module(ioc).

-include("fsm.hrl").
-include_lib("kernel/include/logger.hrl").

-export([format/2, id/0, timestamp_string/0]).
-import(mix, [microseconds/0]).

-define(NONE,    "\e[0m").
-define(RED,     "\e[0;31m").
-define(LRED,    "\e[1;31m").
-define(GREEN,   "\e[0;32m").
-define(LGREEN,  "\e[1;32m").
-define(YELLOW,  "\e[0;33m").
-define(LYELLOW, "\e[1;33m").
-define(MAGENTA, "\e[0;35m").
-define(LMAGENTA,"\e[1;35m").
-define(LBLUE,   "\e[1;36m").
-define(CYAN,    "\e[0;36m").
-define(WHITE,   "\e[1;37m").

id() ->
  case [X || {registered_name,X} <- process_info(self())] of
    [Name] -> Name;
    _ -> nn %% no name
  end.

intfmt(W,V) ->
  lists:flatten(io_lib:format("~*.*.0s",[W,W,integer_to_list(V)])).

timestamp_string() ->
  {M, S, U} = os:timestamp(),
  lists:flatten(io_lib:format("~p.~s.~s", [M, intfmt(6,S), intfmt(6,U)])).

format(#{level := Level,
         msg := {report, #{format := Fmt, args := Args, id := ID}},
         meta := #{
           mfa := {Module, _, _},
           line := Line,
           time := Timestamp}}, Config) ->
  Msg = format_helper(Module, Line, ID, Timestamp, Fmt, Args, Level),
  case maps:get(single_line, Config) of
    true ->
      [re:replace(string:trim(Msg),",?\r?\n\s*",", ",
                  [{return,list},global,unicode]), "\n"];
    _false ->
      Msg
  end;
format(LogEvent, Config) ->
  logger_formatter:format(LogEvent, Config).

format_helper(Module, Line, #sm{id = ID}, Timestamp, Format, Data, Level) ->
  Message = lists:flatten(io_lib:format(Format,Data)),
  HS = fun(I,M,L) -> lists:flatten(io_lib:format("~p:~p:~p:", [M, L, I])) end,
  Fmt = "~48s ~s" ++ "~s" ++ "~s",
  Color = case Level of
            trace -> ?NONE;
            info -> ?LBLUE;
            warning -> ?LRED;
            error -> ?RED;
            _ -> ?NONE
          end,
  Params = [HS(ID, Module, Line), Color] ++ [Message] ++ [?NONE],
  lists:flatten(io_lib:format("~18B " ++ Fmt, [Timestamp | Params]));
format_helper(Module, Line, ID, Timestamp, Format, Data, Level) when is_atom(ID) ->
  format_helper(Module, Line, #sm{id = ID}, Timestamp, Format, Data, Level);
format_helper(Module, Line, _, Timestamp, Format, Data, Level) ->
  format_helper(Module, Line, #sm{id = ""}, Timestamp, Format, Data, Level).

