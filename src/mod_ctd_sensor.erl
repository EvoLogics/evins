-module(mod_ctd_sensor).
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
  Roles = fsm_worker:role_info(Role_IDs, [scli, nl, nl_impl]),
  [#sm{roles = Roles, module = fsm_ctd_nl, logger = Logger}].

parse_conf(ArgS, Share) ->
  FSet   = [F   || {read_frequency, F} <- ArgS],

  F        = set_params(FSet, 5), %ms
  ShareID = #sm{share = Share},
  share:put(ShareID, [{read_frequency, F}]),
  io:format("!!! Set read_frequency ~p~n", [F]).

set_params(Param, Default) ->
  case Param of
    []     -> Default;
    [Value]-> Value
  end.