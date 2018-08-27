%% Copyright (c) 2018, Veronika Kebkal <veronika.kebkal@evologics.de>
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
-module(fsm_nl_traffic).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-import(lists, [filter/2, foldl/3, map/2, member/2]).

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  {H, M, Ms} = erlang:timestamp(),
  rand:seed(exsplus, {H, M, Ms + (H  + M)}),
  SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

-define(TO_MM, fun(#mm{role_id = ID}, {_,Role_ID,_,_,_}, _) -> ID == Role_ID end).

handle_event(MM, SM, Term) ->
  case Term of
    {allowed} ->
      SM;
    {denied} ->
      SM;
    {connected} when MM#mm.role == nl ->
      fsm:cast(SM, MM, [], {send, {nl, get, address}}, ?TO_MM);
    {connected} -> SM;
    {timeout, {transmit, {Address, _Dst} }} ->
      {Start, Time} = share:get(SM, traffic_time),
      Time_Left = (erlang:monotonic_time(milli_seconds) - Start) / 1000 / 60,
      if Time_Left > Time ->
        [clear_spec_timeout(__, transmit),
         fsm:cast(__, nl_impl, {send, {nl, traffic, ok}}),
         create_traffic_bin(__),
         clear_tx(__)
        ](SM);
      true ->
        set_send_timeout(SM, Address)
      end;
    {nl, address, Address} ->
      ?INFO(?ID, "Address:~p   ~p~n", [Address, MM]),
      add_to_lists(SM, Address, configured_addresses),
      Addresses = share:get(SM, configured_addresses),
      ?INFO(?ID, "Configured Addresses:~p~n", [Addresses]),
      [share:put(__, {pid, Address}, MM),
       fsm:cast(__, MM, [], {send, {nl, set, debug, on}}, ?TO_MM)
      ](SM);
    {nl, error, {parseError, Bin}} ->
      case Bin of
        <<"NL,sendstart,", Address/binary>> -> tx_handler(SM, Address);
        _ -> SM
      end;
    {nl, error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {nl, traffic, start, Minutes} ->
      Start = erlang:monotonic_time(milli_seconds),
      [share:put(__, statistics_queue, queue:new()),
       share:put(__, traffic_time, {Start, Minutes}),
       set_send_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, traffic, ok}})
      ](SM);
    {nl, traffic, start} ->
      Start = erlang:monotonic_time(milli_seconds),
      Minutes = share:get(SM, traffic_time_max),
      [share:put(__, statistics_queue, queue:new()),
       share:put(__, traffic_time, {Start, Minutes}),
       set_send_timeouts(__),
       fsm:cast(__, nl_impl, {send, {nl, traffic, ok}})
      ](SM);
    {nl, traffic, stop} ->
      [clear_spec_timeout(__, transmit),
       fsm:cast(__, nl_impl, {send, {nl, traffic, ok}}),
       create_traffic_bin(__),
       clear_tx(__)
      ](SM);
    {nl, traffic, clear} ->
      [share:put(__, statistics_queue, queue:new()),
       fsm:cast(__, nl_impl, {send, {nl, traffic, ok}})
      ](SM);
    {nl, set, generator, Address} ->
      add_to_lists(SM, Address, generators),
      Generators = share:get(SM, generators),
      ?INFO(?ID, "Generators:~p~n", [Generators]),
      fsm:cast(SM, nl_impl, {send, {nl, generator, ok}});
    {nl, delete, generator, Address} ->
      delete_form_lists(SM, Address, generators),
      Generators = share:get(SM, generators),
      ?INFO(?ID, "Generators:~p~n", [Generators]),
      fsm:cast(SM, nl_impl, {send, {nl, generator, ok}});
    {nl, set, destination, Address} ->
      add_to_lists(SM, Address, destinations),
      Destinations = share:get(SM, destinations),
      ?INFO(?ID, "Destinations:~p~n", [Destinations]),
      fsm:cast(SM, nl_impl, {send, {nl, destination, ok}});
    {nl, delete, destination, Address} ->
      delete_form_lists(SM, Address, destinations),
      Destinations = share:get(SM, destinations),
      ?INFO(?ID, "Destinations:~p~n", [Destinations]),
      fsm:cast(SM, nl_impl, {send, {nl, destination, ok}});
    {nl, recv, Src, Dst, Payload} ->
      Time = erlang:monotonic_time(milli_seconds) - share:get(SM, start_time),
      [_, _, _, Parsed_Payload] = extract_payload_nl_flag(Payload),
      [add_to_statistics(__, received, Time, Payload),
       fsm:cast(__, nl_impl, {send, {nl, recv, Src, Dst, Parsed_Payload}})
      ](SM);
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

set_send_timeouts(SM) ->
  Generators = share:get(SM, generators),
  set_send_timeouts_helper(SM, Generators).

set_send_timeout(SM, Address) ->
  set_send_timeouts_helper(SM, [Address]).

set_send_timeouts_helper(SM, []) ->
  SM;
set_send_timeouts_helper(SM, [Address | Tail]) ->
  Destinations = lists:delete(Address, share:get(SM, destinations)),
  Num_Destinations = length(Destinations),
  {Start, End} = share:get(SM, transmit_tmo),
  Rand_Tmo = rand_float(Start, End),
  Rand = rand_int(0, Num_Destinations),
  Rand_Destination = lists:nth(Rand, Destinations),
  PidMM = share:get(SM, {pid, Address}),
  Time = erlang:monotonic_time(milli_seconds) - share:get(SM, start_time),
  Payload = create_payload_data(SM, Address, Rand_Destination, Time),
  NL = {nl, send, Rand_Destination, Payload},

  [fsm:cast(__, PidMM, [], {send, NL}, ?TO_MM),
   add_to_statistics(__, transmit, Time, Payload),
   fsm:set_timeout(__, {ms, Rand_Tmo}, {transmit, {Address, Rand_Destination} }),
   set_send_timeouts_helper(__, Tail)
  ](SM).

tx_handler(SM, Address) when is_binary(Address) ->
  tx_handler(SM, binary_to_integer(Address));
tx_handler(SM, Address) ->
  case share:get(SM, {tx, Address}) of
    nothing -> share:put(SM, {tx, Address}, 0);
    Count -> share:put(SM, {tx, Address}, Count + 1)
  end.

clear_tx(SM) ->
  Adresses = share:get(SM, configured_addresses),
  clear_tx(SM, Adresses).
clear_tx(SM, []) ->
  SM;
clear_tx(SM, [H | T]) ->
   [share:clean(__, {tx, H}),
    clear_tx(__, T)
   ](SM).

create_traffic_bin(SM) ->
  Generators = share:get(SM, generators),
  [create_traffic_bin_helper(__, Generators),
   share:put(__, stats_list, [])
  ](SM).

create_traffic_bin_helper(SM, []) ->
  Bin = stats_to_bin(SM),
  fsm:cast(SM, nl_impl, {send, {nl, help, Bin}});
create_traffic_bin_helper(SM, [Generator | Tail]) ->
  Destinations = share:get(SM, destinations),
  [create_traffic_bin_helper(__, Generator, Destinations),
   create_traffic_bin_helper(__, Tail)
  ](SM).

create_traffic_bin_helper(SM, _Generator, []) ->
  SM;
create_traffic_bin_helper(SM, Generator, [Destination | Tail]) ->
  Qname = statistics_queue,
  Q = share:get(SM, Qname),
  [create_traffic_bin_helper(__, Q, Generator, Destination, 0, 0),
   create_traffic_bin_helper(__, Generator, Tail)
  ](SM).

create_traffic_bin_helper(SM, nothing, Generator, Destination, CSend, CRecv) ->
  Tuple = {Generator, Destination, CRecv, CSend},
  Stats_List = share:get(SM, stats_list),
  case Stats_List of
    nothing -> share:put(SM, stats_list, [Tuple]);
    _ -> share:put(SM, stats_list, [Tuple | Stats_List])
  end;
create_traffic_bin_helper(SM, {[],[]}, Generator, Destination, CSend, CRecv) ->
  Tuple = {Generator, Destination, CRecv, CSend},
  Stats_List = share:get(SM, stats_list),
  case Stats_List of
    nothing -> share:put(SM, stats_list, [Tuple]);
    _ -> share:put(SM, stats_list, [Tuple | Stats_List])
  end;
create_traffic_bin_helper(SM, Q, Generator, Destination, CSend, CRecv) ->
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {Time_Send, Time_Recv, Generator, Destination, _PkgID, _P} when Time_Send =/= empty,
                                                                    Time_Recv =/= empty ->
      create_traffic_bin_helper(SM, Q_Tail, Generator, Destination, CSend + 1, CRecv + 1);
    {Time_Send, empty, Generator, Destination, _PkgID, _P} when Time_Send =/= empty ->
      create_traffic_bin_helper(SM, Q_Tail, Generator, Destination, CSend + 1, CRecv);
    _ ->
      create_traffic_bin_helper(SM, Q_Tail, Generator, Destination, CSend, CRecv)
  end.

stats_to_bin(SM) ->
  Stats_List = share:get(SM, stats_list),
  ?INFO(?ID, ">>>>>> BIN TO DISPLAY ~p~n", [Stats_List]),

  EOL = "\r\n",

  share:put(SM, total_recv, 0),
  share:put(SM, total_tx, 0),

  Lst =
  lists:map(fun(Element) ->
              {Src,Dst,CRecv,CSend} = Element,
              share:put(SM, total_recv, share:get(SM, total_recv) + CRecv),
              lists:flatten([io_lib:format("src:~B dst:~B total:~B / ~B",
                                          [Src,Dst,CRecv,CSend]),EOL])
            end, Stats_List),

  Addresses = share:get(SM, configured_addresses),
  Tx =
  lists:map(fun(Address) ->
              Count = share:get(SM, {tx, Address}),
              if Count =/= nothing ->
                share:put(SM, total_tx, share:get(SM, total_tx) + Count),
                lists:flatten([io_lib:format("TX on src : ~B total: ~B",
                                          [Address, Count]),EOL]);
              true ->
                lists:flatten([io_lib:format("TX on src : ~B total: ~B",
                                          [Address, 0]),EOL])
              end
            end, Addresses),

  Total_recv = share:get(SM, total_recv),
  Total_tx = share:get(SM, total_tx),

  Total_handler =
  fun() when Total_tx == 0; Total_recv == 0 -> 0.00;
     () -> Total_tx / Total_recv
  end,

  Total = lists:flatten([io_lib:format("        Total recv:~B / tx:~B -> Energy:~.2f",
                        [Total_recv, Total_tx, Total_handler()]),EOL]),

  list_to_binary([Lst, EOL, Tx, EOL, Total, EOL]).

add_to_statistics(SM, Type, Time, Payload) ->
  Qname = statistics_queue,
  Q = share:get(SM, Qname),
  NQ = if Q == nothing -> queue:new(); true -> Q end,
  [Src, Dst, PkgID, Parsed_Payload] = extract_payload_nl_flag(Payload),
  Tuple = {Src, Dst, PkgID, Parsed_Payload},
  ?INFO(?ID, ">>>>>> add_to_statistics ~p ~p ~p ~p ~p ~p~n", [Type, Time, Src, Dst, PkgID, Parsed_Payload]),
  add_to_statistics_helper(SM, NQ, queue:new(), not_inside, Type, Time, Tuple).

add_to_statistics_helper(SM, {[],[]}, NQ, not_inside, received, Time, Tuple) ->
  {Src, Dst, PkgID, Parsed_Payload} = Tuple,
  NTuple = {empty, Time, Src, Dst, PkgID, Parsed_Payload},
  share:put(SM, statistics_queue, queue:in(NTuple, NQ));
add_to_statistics_helper(SM, {[],[]}, NQ, not_inside, transmit, Time, Tuple) ->
  {Src, Dst, PkgID, Parsed_Payload} = Tuple,
  NTuple = {Time, empty, Src, Dst, PkgID, Parsed_Payload},
  share:put(SM, statistics_queue, queue:in(NTuple, NQ));
add_to_statistics_helper(SM, {[],[]}, NQ, _Inside, _Type, _Time, _Tuple) ->
  share:put(SM, statistics_queue, NQ);
add_to_statistics_helper(SM, Q, NQ, Inside, Type, Time, Tuple) ->
  {Src, Dst, PkgID, Parsed_Payload} = Tuple,
  { {value, Q_Tuple}, Q_Tail} = queue:out(Q),
  case Q_Tuple of
    {empty, Time_Recv, Src, Dst, PkgID, Parsed_Payload} when Type == transmit ->
      NTuple = {Time, Time_Recv, Src, Dst, PkgID, Parsed_Payload},
      add_to_statistics_helper(SM, Q_Tail, queue:in(NTuple, NQ), inside, Type, Time, Tuple);
    {Time_Send, empty, Src, Dst, PkgID, Parsed_Payload} when Type == received ->
      NTuple = {Time_Send, Time, Src, Dst, PkgID, Parsed_Payload},
      add_to_statistics_helper(SM, Q_Tail, queue:in(NTuple, NQ), inside, Type, Time, Tuple);
    _ ->
      add_to_statistics_helper(SM, Q_Tail, queue:in(Q_Tuple, NQ), Inside, Type, Time, Tuple)
  end.

add_to_lists(SM, Address, Name) ->
  L = share:get(SM, Name),
  case L of
    nothing -> share:put(SM, Name, [Address]);
    [] -> share:put(SM, Name, [Address]);
    _ -> case lists:member(Address, L) of
          true  -> SM;
          false -> share:put(SM, Name, [Address | L])
         end
  end.

delete_form_lists(SM, Address, Name) ->
   L = share:get(SM, Name),
  case L of
    nothing -> share:put(SM, Name, []);
    [] -> share:put(SM, Name, []);
    _ ->  share:put(SM, Name, lists:delete(Address, L))
  end.

rand_float(Start, End) ->
  (Start + rand:uniform() * (End - Start)) * 1000.
rand_int(Start, Start) ->
  Start;
rand_int(Start, End) ->
  Start + rand:uniform(End - Start).

count_flag_bits (F) ->
  count_flag_bits_helper(F, 0).

count_flag_bits_helper(0, 0) -> 1;
count_flag_bits_helper(0, C) -> C;
count_flag_bits_helper(F, C) ->
  Rem = F rem 2,
  D =
  if Rem =:= 0 ->
    F / 2;
    true -> F / 2 - 0.5
  end,
  count_flag_bits_helper(round(D), C + 1).

increase_pkgid(SM) ->
  Max_pkg_id = ?PKG_ID_MAX,
  PkgID = case share:get(SM, packet_id) of
            nothing -> 0;
            Prev_id when Prev_id >= Max_pkg_id -> 0;
            (Prev_id) -> Prev_id + 1
          end,

  ?TRACE(?ID, "Increase Pkg, Current Pkg id ~p~n", [PkgID]),
  share:put(SM, packet_id, PkgID),
  PkgID.

create_payload_data(SM, Src, Dst, Time) ->
  PkgID = increase_pkgid(SM),
  CBitsAddr = count_flag_bits(?ADDRESS_MAX),
  CPkgID = count_flag_bits(?PKG_ID_MAX),
  BSrc = <<Src:CBitsAddr>>,
  BDst = <<Dst:CBitsAddr>>,
  BPkgID = <<PkgID:CPkgID>>,
  Data = list_to_binary([integer_to_binary(Src), "->", integer_to_binary(Dst), ":" ,integer_to_binary(Time)]),
  TmpData = <<BSrc/bitstring, BDst/bitstring, BPkgID/bitstring, Data/binary>>,
  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<BSrc/bitstring, BDst/bitstring, BPkgID/bitstring, 0:Add, Data/binary>>;
  true ->
    TmpData
  end.

extract_payload_nl_flag(Payload) ->
  % 6 bits NL_Protocol_PID
  % 3 bits Flag
  % 6 bits PkgID
  % 2 bits TTL
  % 6 bits SRC
  % 6 bits DST
  % rest bits reserved for later (+ 3)
  CBitsAddr = count_flag_bits(?ADDRESS_MAX),
  CPkgID = count_flag_bits(?PKG_ID_MAX),

  Data_bin = (bit_size(Payload) rem 8) =/= 0,
  <<BSrc:CBitsAddr, BDst:CBitsAddr, BPkgID:CPkgID, Rest/bitstring>> = Payload,
  if Data_bin =:= false ->
    Add = bit_size(Rest) rem 8,
    <<_:Add, Data/binary>> = Rest,
    [BSrc, BDst, BPkgID, Data];
  true ->
    [BSrc, BDst, BPkgID, Rest]
  end.

clear_spec_timeout(SM, Spec) ->
  TRefList = filter(
               fun({E, TRef}) ->
                   case E of
                     {Spec, _} -> timer:cancel(TRef), false;
                     _  -> true
                   end
               end, SM#sm.timeouts),
  SM#sm{timeouts = TRefList}.
