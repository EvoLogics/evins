%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%%
%% @author Oleksiy Kebkal lesha@evologics.de
-module(fsm_rb_format_supp).

%% user interface
-export([print/3]).

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

-define(GREGORIAN_UNIX_EPOCH, 62167219200).

esc(Color) ->
  case Color of
    none ->     ?NONE;
    red ->      ?RED;
    lred ->     ?LRED;
    green ->    ?GREEN;
    lgreen ->   ?LGREEN;
    yellow ->   ?YELLOW;
    lyellow ->  ?LYELLOW;
    magenta ->  ?MAGENTA;
    lmagenta -> ?LMAGENTA;
    lblue ->    ?LBLUE;
    cyan ->     ?CYAN;
    white ->    ?WHITE
  end.

intfmt(W,V) ->
  lists:flatten(io_lib:format("~*.*.0s",[W,W,integer_to_list(V)])).

%%-----------------------------------------------------------------
%% This module prints error reports. Called from rb.
%%-----------------------------------------------------------------

print(Date, Report, Device) ->
  Line = 79,
  %% Remove these comments when we can run rb in erl44!!!
                                                %    case catch sasl_report:write_report(Device, Report) of
                                                % true -> ok;
                                                % _ ->
  {Time, Rep} = Report,
  case Rep of
    {error_report, _GL, {Pid, crash_report, CrashReport}} ->
      Header = format_h(Line, "CRASH REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header} |
                                  format_c(CrashReport)]),
      true;
    {error_report, _GL, {Pid, supervisor_report, SupReport}} ->
      Header = format_h(Line, "SUPERVISOR REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header} |
                                  format_s(SupReport)]),
      true;
    {error_report, _GL, {Pid, _Type, Report1}} ->
      Header = format_h(Line, "ERROR REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header},
                                  {data, Report1}]),
      true;
    {info_report, _GL, {Pid, progress, SupProgress}} ->
      Header = format_h(Line, "PROGRESS REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header} |
                                  format_p(SupProgress)]);
    {info_report, _GL, {Pid, _Type, Report1}} ->
      Header = format_h(Line, "INFO REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header},
                                  {data, Report1}]),
      true;
    {warning_report, _GL, {Pid, _Type, Report1}} ->
      Header = format_h(Line, "WARNING REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header},
                                  {data, Report1}]),
      true;
    {error, _GL, {Pid, Format, Args}} ->
      Header = format_h(Line, "ERROR REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header}]),
      io:format(Device, Format, Args);
    {info_msg, _GL, {Pid, Format, Args}} ->
      Header = format_h(Line, "INFO REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header}]),
      io:format(Device, Format, Args);
    {warning_msg, _GL, {Pid, Format, Args}} ->
      Header = format_h(Line, "WARNING REPORT", Pid, Date),
      format_lib_supp:print_info(Device,
                                 Line,
                                 [{header, Header}]),
      io:format(Device, Format, Args);
    {fsm_progress, _GL, {Type, ID, Module, MLine, Timestamp, Message}} ->
      TS = fun({M,S,U}) -> lists:flatten(io_lib:format("~p.~s.~s", [M, intfmt(6,S), intfmt(6,U)])) end,
      HS = fun(I,M,L) -> lists:flatten(io_lib:format("~p:~p:~p:", [M, L, I])) end,
      Fmt = "~34s ~s" ++ "~s" ++ "~s",
      Color = case Type of
                info -> lblue;
                warning -> lred;
                error -> red;
                _ -> none
              end,
      Params = [HS(ID, Module, MLine), esc(Color)] ++ [Message] ++ [esc(none)],
      io:format(Device,"~18s " ++ Fmt, [TS(Timestamp) | Params]);
    {FSM, _GL, {ID, Message}} when FSM == fsm_event; FSM == fsm_core; FSM == fsm_cast; FSM == fsm_transition ->
      T = calendar:datetime_to_gregorian_seconds(erlang:localtime_to_universaltime(Time)) - ?GREGORIAN_UNIX_EPOCH,
      TS = lists:flatten(io_lib:format("~p.~s", [T div 1000000, intfmt(6,T rem 1000000)])),
      io:format(Device,"~11s ~20s ~20s ~140p~n", [TS, atom_to_list(FSM), atom_to_list(ID), Message]);
    {Type, _GL, TypeReport} ->
      io:format(Device, "~nInfo type <~w> ~s~n",
                [Type, Date]),
      io:format(Device, "~p~n", [TypeReport]);
    _ -> 
      io:format("~nPrinting info of unknown type... ~s~n",
                [Date]),
      io:format(Device, "~p", [Report])
                                                %     end
  end.

format_h(Line, Header, Pid, Date) ->
  NHeader = lists:flatten(io_lib:format("~s  ~w", [Header, Pid])), 
  DateLen = length(Date),
  HeaderLen = Line - DateLen,
  Format = lists:concat(["~-", HeaderLen, "s~", DateLen, "s"]),
  io_lib:format(Format, [NHeader, Date]).


%%-----------------------------------------------------------------
%% Crash report
%%-----------------------------------------------------------------
format_c([OwnReport, LinkReport]) ->
  [{items, {"Crashing process", OwnReport}},
   format_neighbours(LinkReport)].

format_neighbours([Data| Rest]) ->
  [{newline, 1},
   {items, {"Neighbour process", Data}} | 
   format_neighbours(Rest)];
format_neighbours([]) -> [].

%%-----------------------------------------------------------------
%% Supervisor report
%%-----------------------------------------------------------------
format_s(Data) ->
  SuperName = get_opt(supervisor, Data),
  ErrorContext = get_opt(errorContext, Data),
  Reason = get_opt(reason, Data),
  ChildInfo = get_opt(offender, Data),
  [{data, [{"Reporting supervisor", SuperName}]},
   {newline, 1},
   {items, {"Child process", 
            [{errorContext, ErrorContext}, 
             {reason, Reason} |
             lists:map(fun(CI) -> transform_mfa(CI) end, ChildInfo)]}}].

transform_mfa({mfa, Value}) -> {start_function, Value};
transform_mfa(X) -> X.

%%-----------------------------------------------------------------
%% Progress report
%%-----------------------------------------------------------------
format_p(Data) ->
  [{data, Data}].

get_opt(Key, List) ->
  case lists:keysearch(Key, 1, List) of
    {value, {_Key, Val}} -> Val;
    _  -> undefined
  end.
