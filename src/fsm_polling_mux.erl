%% Copyright (c) 2015, Veronika Kebkal <veronika.kebkal@evologics.de>
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
-module(fsm_polling_mux).
-behaviour(fsm).

-include("fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1, handle_event/3, stop/1]).

-export([handle_polling/3, handle_process_CDT/3, handle_wait_VDT/3]).
-export([handle_idle/3, handle_alarm/3, handle_final/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {recv_CDT, process_CDT},

                 {recv_VDT, idle},
                 {recv_VDT_pbm, idle}
                 ]},

                {polling,
                 [{poll_next_addr, polling},
                 {send_CDT, wait_VDT},
                 {poll_start, polling},
                 {poll_stop, idle},
                 {retransmit_im, polling},

                 {recv_VDT, polling},
                 {recv_VDT_pbm, polling},

                 {error, idle}
                 ]},

                {wait_VDT,
                 [
                 {poll_start, polling},
                 {poll_stop, idle},

                 {recv_VDT_pbm, wait_VDT},
                 {recv_VDT, wait_VDT},

                 {poll_next_addr, polling},
                 {send_VDT, wait_VDT}
                 ]},

                {process_CDT,
                 [{recv_CDT, process_CDT},

                 {recv_VDT_pbm, process_CDT},
                 {recv_VDT, process_CDT},

                 {send_pbm, process_CDT},

                 {poll_start, polling},
                 {poll_stop, idle},

                 {wait_ok, process_CDT},
                 {send_VDT, idle}
                 ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

%%--------------------------------Handler functions-------------------------------
handle_event(MM, SM, Term) ->
  %?INFO(?ID, "HANDLE EVENT  ~p   ~p ~n", [MM, SM]),
  ?TRACE(?ID, "~p~n", [Term]),
  SeqPollAddrs = share:get(SM, polling_seq),
  Local_address = share:get(SM, local_address),

  case Local_address of
    2 ->
     io:format("!!!!!!!!!!!!! handle_event ~p: ~p ~p ~p~n", [Local_address, Term, SM#sm.event, SM#sm.state]);
    1 ->
      io:format("!!!!!!!!!!!!! handle_event ~p: ~p ~p ~p~n", [Local_address, Term, SM#sm.event, SM#sm.state]);
      _ -> nothing
  end,

  case Term of
    {timeout, answer_timeout} ->
      TupleResponse = {response, {error, <<"ANSWER TIMEOUT">>}},
      fsm:cast(SM, polling_mux, {send, TupleResponse}),
      SM;
    {timeout, {send_burst, SBurstTuple}} ->
      fsm:run_event(MM, SM#sm{event = send_pbm, event_params = SBurstTuple}, {});
    {timeout, {retransmit_im, STuple}} ->
      fsm:run_event(MM, SM#sm{event = retransmit_im}, {retransmit_im, STuple});
    {timeout, {retransmit_pbm, STuple}} ->
      fsm:run_event(MM, SM#sm{event = recv_CDT, event_params = STuple}, {});
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} ->
      ?INFO(?ID, "connected ~n", []),
      SM;

    {rcv_ul, STuple = {nl, send, _TransmitLen, _IDst, _MsgType, _Payload}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      add_to_CDT_queue(SM, STuple),
      SM;
    {rcv_ul, {nl, send, _TransmitLen, _IDst, _Payload}} ->
      % Is it neceessary to add the msg type???
      fsm:cast(SM, polling_mux, {send, {response, {nl, error}}}),
      SM;
    {rcv_ul, {set, polling_seq, LSeq}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      init_poll_index(SM),
      share:put(SM, polling_seq, LSeq),
      SM;
    {rcv_ul, {set, polling, start}} when (SeqPollAddrs =/= []) ->
      SM1 = fsm:clear_timeouts(SM),
      fsm:cast(SM1, polling_mux, {send, {response, {nl, ok}}}),
      fsm:run_event(MM, SM1#sm{event = poll_start}, {});
    {rcv_ul, {set, polling, start}} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, seq, empty}}}),
      SM;
    {rcv_ul, {set, polling, stop}} ->
      SM1 = fsm:clear_timeouts(SM),
      fsm:cast(SM, polling_mux, {send, {response, {nl, ok}}}),
      fsm:run_event(MM, SM1#sm{event = poll_stop}, {});

    {async, {pid, _Pid}, RTuple = {recv, _Len, _Src,_Dst , _,  _,  _,  _,  _, _Data}} ->
      %TODO: process_data
      fsm:run_event(MM, SM#sm{event = recv_VDT}, {recv_VDT, RTuple});
    {async, {pid, _Pid}, RTuple = {recvpbm, _Len, _Src, _Dst, _, _, _, _, _Data}} ->
      %TODO: process_data
      fsm:run_event(MM, SM#sm{event = recv_VDT_pbm}, {recv_VDT_pbm, RTuple});
    {async, {pid, Pid}, {recvim, Len, Src, Local_address, Flag, _, _, _,_, Data}} ->
      RecvTuple = {recv, {Pid, Len, Src, Local_address, Flag, Data}},
      fsm:run_event(MM, SM#sm{event = recv_CDT, event_params = RecvTuple}, {});
    {async, {pid, _Pid}, {recvim, _Len, _Src, _Dst, _Flag, _, _, _,_, _Data}} ->
      % TODO: ooverhearing
      SM;
      %fsm:run_event(MM, SM#sm{event = recv_CDT}, {recv, {Pid, Len, Src, Dst, Flag, Data}});

    {async, _PosTerm = {usbllong, _FCurrT, _FMeasT, _Src, _X, _Y, _Z,
                      _E, _N, _U, _Roll, _Pitch, _Yaw, _P, _Rssi, _I, _Acc}} ->

      %fsm:cast(SM, polling_nmea, {send, PosTerm}),
      SM;

    {async, _Tuple} ->
      %io:format("!!!!!!!!!!!!! async ~p~n", [Tuple]),
      SM;
    {sync, "*SEND", "OK"} ->
      SM1 = fsm:clear_timeout(SM, answer_timeout),
      SM2 = nl_mac_hf:clear_spec_timeout(SM1, send_burst),
      fsm:run_event(MM, SM2#sm{event = send_VDT}, {});
    {sync, _Req, _Answer} ->
      SM1 = fsm:clear_timeout(SM, answer_timeout),
      %io:format("!!!!!!!!!!!!! sync ~p ~p~n", [Req, Answer]),
      SM1;

    {nl, error} ->
      fsm:cast(SM, polling_mux, {send, {response, {nl, error}}});

    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p~n", [?MODULE, UUg]),
      SM
  end.

handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  case SM#sm.event of
    internal ->
      init_poll(SM);
    _ -> nothing
  end,
  SM#sm{event = eps}.

handle_polling(_MM, #sm{event = poll_next_addr} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),

  %TODO: PID ?
  STuple = create_CDT_msg(SM),

  %io:format("handle_polling ======================================>  ~p ~n", [STuple]),

  case Answer_timeout of
    true ->
      % !!! TODO: retry in some ms, check!
      fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {retransmit_im, STuple});
    false ->
      SM1 = fsm:send_at_command(SM, STuple),
      SM1#sm{event = send_CDT}
  end;
handle_polling(_MM, #sm{event = retransmit_im} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  SM#sm{event = poll_next_addr};
handle_polling(_MM, #sm{event = poll_start} = SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  init_poll_index(SM),
  SM#sm{event = poll_next_addr};
handle_polling(_MM, SM, Term) ->
  ?TRACE(?ID, "handle_polling ~120p~n", [Term]),
  SM#sm{event = eps}.


handle_wait_VDT(_MM, SM, Term = {recv_VDT_pbm,_}) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  % TODO: if pbm contains burst data flag, wait till recv_VDT
  % if not, directly to poll next address
  %or timeout, nothing was received
  io:format("!!!!!!! handle_wait_VDT ~120p~n", [Term]),
  SM#sm{event = eps};
handle_wait_VDT(_MM, SM, Term = {recv_VDT,_}) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  io:format("!!!!!!! handle_wait_VDT ~120p~n", [Term]),
  % TODO: rotate through the list of addrs
  poll_next_addr(SM),
  SM#sm{event = poll_next_addr};
handle_wait_VDT(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.


handle_process_CDT(_MM, #sm{event = send_pbm} = SM, _Term) ->
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  Event_params = SM#sm.event_params,
  % TODO: processed data!

  {recv, {Pid, _Len, Src, _Dst, _Flag, Data}} = Event_params,
  SBurstTuple = {at, {pid, Pid}, "*SEND", Src, Data},
  case Answer_timeout of
    true ->
      % !!! TODO: retry in some ms, check!
      fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {send_burst, Event_params});
    false ->
      SM1 = fsm:send_at_command(SM, SBurstTuple),
      SM2 = fsm:set_timeout(SM1#sm{event = wait_ok}, ?ANSWER_TIMEOUT, {send_burst, Event_params}),
      SM2
  end;
handle_process_CDT(_MM, #sm{event = recv_CDT} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  io:format("!!!!!!! handle_process_CDT ~120p~n", [Term]),
  % 1. check_MQ();
  % 2. add burst flag
  % 3. send PBM
  % 4. send Burst data
  Answer_timeout = fsm:check_timeout(SM, answer_timeout),
  Event_params = SM#sm.event_params,
  {recv, {Pid, _Len, Src, _Dst, _Flag, Data}} = Event_params,

  case Answer_timeout of
    true ->
      % !!! TODO: retry in some ms, check!
      fsm:set_timeout(SM#sm{event = eps}, ?ANSWER_TIMEOUT, {retransmit_pbm, Event_params} );
    false ->
      SPMTuple = {at, {pid, Pid}, "*SENDPBM", Src, Data},
      SM1 = fsm:send_at_command(SM, SPMTuple),
      SM1#sm{event = send_pbm, event_params = Event_params}
  end;
handle_process_CDT(_MM, SM, _Term) ->
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
  ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------------Helper functions------------------------
init_poll(SM)->
  share:put(SM, polling_seq, []),
  SM.

init_poll_index(SM) ->
  share:put(SM, current_polling_i, 1).

poll_next_addr(SM) ->
  LSeq = share:get(SM, polling_seq),
  Current_polling_i = share:get(SM, current_polling_i),
  Ind =
  if Current_polling_i >= length(LSeq) -> 1;
  true -> Current_polling_i + 1
  end,
  share:put(SM, current_polling_i, Ind),
  get_current_poll_addr(SM).

get_current_poll_addr(SM) ->
  LSeq = share:get(SM, polling_seq),
  Ind = share:get(SM, current_polling_i),
  lists:nth(Ind, LSeq).

create_CDT_msg(SM) ->
  % TODO: DATA? Fused Position + CDT ?
  % Burst fomt CDT? or dummy with POS?
  Current_polling_addr = get_current_poll_addr(SM),

  DS = queue_to_data(SM, dsensitive),
  DT = queue_to_data(SM, dtolerant),

  DataPos = <<"POS....">>,
  LenDataPos = byte_size(DataPos),
  DataCDT = list_to_binary([DS, DT]),

  % TODO: Set max pos len
  CBitsPosLen = nl_mac_hf:count_flag_bits(63),
  BLenPos = <<LenDataPos:CBitsPosLen>>,

  TmpData = <<BLenPos/bitstring, DataPos/binary, DataCDT/binary>>,

  Data_bin = is_binary(TmpData) =:= false or ( (bit_size(TmpData) rem 8) =/= 0),
  Data =
  if Data_bin =:= false ->
    Add = (8 - bit_size(TmpData) rem 8) rem 8,
    <<BLenPos/bitstring, 0:Add, DataPos/binary, DataCDT/binary>>;
  true ->
    TmpData
  end,

  LenData = byte_size(Data),

  if LenData < 64 ->
    {at, {pid, 0},"*SENDIM", Current_polling_addr, ack, Data};
  true ->
    {at, {pid, 0},"*SEND", Current_polling_addr, Data}
  end.

queue_to_data(SM, Name) ->
  Current_polling_addr = get_current_poll_addr(SM),
  Dst = binary_to_atom(integer_to_binary(Current_polling_addr), utf8),

  Qname = list_to_atom(atom_to_list(Name) ++ atom_to_list(Dst)),
  Q  = share:get(SM, Qname),
  case Q of
    nothing -> <<"">>;
    {[],[]} -> <<"">>;
    _ ->
      LData = queue:to_list(Q),
      F = fun(X) -> {_Time, _Type, _Len, Data} = X, Data end,
      list_to_binary(lists:join(<<"">>, [ F(X)  || X <- LData]))
  end.

add_to_CDT_queue(SM, STuple) ->
  % TODO: maybe we have to same messages to a file
  {nl, send, TransmitLen, IDst, MsgType, Payload} = STuple,
  ADst = binary_to_atom(integer_to_binary(IDst), utf8),
  Qname = list_to_atom(atom_to_list(MsgType) ++ atom_to_list(ADst)),

  QShare = share:get(SM, Qname),
  Q =
  if QShare == nothing ->
    queue:new();
  true ->
    QShare
  end,
  Item = {erlang:monotonic_time(micro_seconds), MsgType, TransmitLen, Payload},
  NQ =
  case MsgType of
    dtolerant ->
      queue:in(Item, Q);
    dsensitive ->
      %TODO: configurable parameter Max
      nl_mac_hf:queue_limited_push(Q, Item, 3)
  end,
  share:put(SM, Qname, NQ),
  ?TRACE(?ID, "add_to_CDT_queue ~p~n", [share:get(SM, Qname)]).
