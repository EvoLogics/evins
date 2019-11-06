divert(-1)
define(`version', esyscmd(`V=$(git describe --abbrev=0) && echo -n $V'))
divert(0)dnl
{application,evins,
             [{description,"EvoLogics intelligent Networking Software framework"},
              {vsn,"version"},
              {id,"git"},
              {modules,[]},
              {registered,[]},
              {applications,[kernel,stdlib,sasl,cowboy,ssh]},
              {mod,{fsm_app,["etc/fsm.conf"]}},
              {start_phases,[]}]}.
