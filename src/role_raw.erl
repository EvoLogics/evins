-module(role_raw).
-behaviour(role_worker).
-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2]).

-include("fsm.hrl").

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  Tout = proplists:get_value(timeout, MM#mm.params, 1000), %% millis
  Sz = proplists:get_value(size, MM#mm.params, 1024), %% bytes
  Cfg = #{timeout => Tout, size => Sz, rx_time => erlang:monotonic_time(millisecond)},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl(update_timer, #{timeout := Tout} = Cfg) ->
  timer:cancel(maps:get(timer, Cfg, nothing)),
  {ok, Ref} = timer:send_after(Tout, {ctrl, data_timeout}),
  Cfg#{timer => Ref};
ctrl(data_timeout, Cfg) ->
  self() ! {tcp, nothing, <<>>},
  Cfg;
ctrl(_,Cfg) -> Cfg.

since_rx(#{rx_time := RT}) ->
  erlang:monotonic_time(millisecond) - RT.

to_term(Tail, Chunk, #{size := Sz, timeout := Tout} = Cfg) ->
  L = list_to_binary([Tail,Chunk]),
  NCfg = case Chunk of
    <<>> -> Cfg;
    _ -> ctrl(update_timer, Cfg#{rx_time => erlang:monotonic_time(millisecond)})
  end,
  case {byte_size(L), since_rx(NCfg)} of
    {S,_} when S >= Sz ->
      <<H:Sz/binary,Rest/binary>> = L,
      [[{raw, H}], [], [], Rest, ctrl(data_timeout, NCfg)];
    {_,V} when V >= Tout ->
      io:format("V: ~p~n", [V]),
      [[{raw, L}], [], [], <<>>, NCfg];
    _ ->
      [[], [], [], L, NCfg]
  end.

from_term({string, S}, Cfg) -> [list_to_binary(S ++ "\n"), Cfg];
from_term({binary, B}, Cfg) -> [B, Cfg];
from_term({prompt}, Cfg)    -> [<<"> ">>, Cfg];
from_term(_, _)             -> {error, term_not_supported}.
