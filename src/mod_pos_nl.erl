-module(mod_pos_nl).
-behaviour(fsm_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) ->
  fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(_Mod_ID, Role_IDs, Share, ArgS) ->
  parse_conf(ArgS, Share),
  Logger = case lists:keyfind(logger, 1, ArgS) of
               {logger,L} -> L; _ -> nothing
             end,
  Roles = fsm_worker:role_info(Role_IDs, [nmea, nl, nl_impl]),
  [#sm{roles = Roles, module = fsm_pos_nl, logger = Logger}].

parse_conf(ArgS, Share) ->
  RASet   = [A   || {remote_address, A} <- ArgS],
  RA = set_params(RASet, 7), %ms
  ShareID = #sm{share = Share},
  share:put(ShareID, [{remote_address, RA}]),
  io:format("!!! Set remote address ~p~n", [RA]).

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.