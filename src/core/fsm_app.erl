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
-module(fsm_app).
-behaviour(application).

-export([start/2, stop/1]).

setup_logger(console) ->
  logger:set_handler_config(default, formatter, {ioc, #{single_line => true}});
setup_logger(file) ->
  logger:add_handler(evins, logger_disk_log_h,
                     #{formatter => {ioc, #{single_line => true}},
                       config => #{file => maybe_config(logger_dir,"/opt/evins/log") ++ "/evins",
                                   max_no_files => maybe_config(logger_maxfiles, 5),
                                   max_no_bytes => maybe_config(logger_maxbytes, 4194304)}
                      });
setup_logger(_) ->
  nothing.

start(_Type, _Args) ->
  Sinks = maybe_config(logger_output, []),
  case lists:member(console, Sinks) of
    true -> nothing;
    _ -> logger:remove_handler(default)
  end,
  [setup_logger(Sink) || Sink <- Sinks],
  User_config = maybe_config(user_config),
  Fabric_config = maybe_config(fabric_config),
  fsm_supervisor:start_link([Fabric_config, User_config]).

maybe_config(Name) ->
  case application:get_env(evins, Name) of
    {ok, Path} -> Path;
    _ -> nothing
  end.

maybe_config(Name, Default) ->
  case application:get_env(evins, Name) of
    {ok, Path} -> Path;
    _ -> Default
  end.

stop(_State) ->
  ok.

