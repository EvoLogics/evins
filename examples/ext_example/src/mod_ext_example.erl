-module(mod_ext_example).
-behaviour(fsm_worker).

-include_lib("evins/include/fsm.hrl").

-export([start/4, register_fsms/4]).

start(Mod_ID, Role_IDs, Sup_ID, {M, F, A}) -> 
    fsm_worker:start(?MODULE, Mod_ID, Role_IDs, Sup_ID, {M, F, A}).

register_fsms(_Mod_ID, Role_IDs, _Share, _ArgS) ->
    Roles = fsm_worker:role_info(Role_IDs, [ext_example, scli]),
    [#sm{roles = Roles, module = fsm_ext_example}].
