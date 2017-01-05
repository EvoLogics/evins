-module(role_ext_example).
-behaviour(role_worker).

-include_lib("evins/include/fsm.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2]).

stop(_) -> ok.

start(Role_ID, Mod_ID, #mm{iface = {port, Port, PortSettings}} = MM) ->
  %% here you can verify port settings according to your requirements and set defaults if needed
  %% PortSettings specification described in erlang:open_port/2 manual
  VerifiedSettings = [{packet, 1} | proplists:delete(packet, PortSettings)],
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM#mm{iface = {port, Port, VerifiedSettings}}).

ctrl(_,Cfg) -> Cfg.

to_term(_, Chunk, Cfg) ->
  %% Chunk is the packet, decoded according to protocol {packet,1}, already without the first byte
  %% containing the packet length
  TermList = [{encoded, Chunk}],
  [TermList, [], [], <<>>, Cfg].

from_term({encode, Bin}, Cfg) when is_binary(Bin) ->
  %% Bin will be sent to port according to PortSettings
  %% In the example we set {packet, 1}, so Bin size will be automatically added (in the first byte) 
  case size(Bin) of
    L when L < 256 ->
      [Bin, Cfg];
    _ ->
      {error, term_not_supported}
  end;
from_term(_Other, _Cfg) ->
  {error, term_not_supported}.
