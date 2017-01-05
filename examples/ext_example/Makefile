PROJECT = ext_example
DEPS = evins

C_SRC_TYPE = executable
CODE_LOADING_MODE = interactive

rel:: config/sys.config

config/sys.config:: config/sys.config.in
	sed -e "s,path,$$(pwd)," config/sys.config.in >| config/sys.config

include ../../erlang.mk


