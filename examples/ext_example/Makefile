PROJECT = ext_example
DEPS = evins
dep_evins = git https://github.com/okebkal/evins

C_SRC_TYPE = executable
CODE_LOADING_MODE = interactive

rel:: deps config/sys.config

config/sys.config:: config/sys.config.in
	sed -e "s,path,$$(pwd)," config/sys.config.in >| config/sys.config

include ../../erlang.mk


