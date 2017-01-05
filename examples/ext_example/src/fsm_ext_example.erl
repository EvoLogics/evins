-module(fsm_ext_example).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).

-define(TRANS, []).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> eps.
stop(_SM)      -> ok.

handle_event(_MM, SM, Term) ->
  case Term of
    {connected} ->
      fsm:cast(SM, scli, {send, {prompt}});
    {encoded, B} ->
      %% B - data from port
      fsm:cast(SM, scli, {send, {string, B}}),
      fsm:cast(SM, scli, {send, {prompt}});
    B when is_binary(B) ->
      %% B - data from scli
      fsm:cast(SM, ext_example, {send, {encode, B}});
    _ ->
      SM
  end.
