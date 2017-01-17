PROJECT = evins

DEPS = cowboy jsx parse_trans edown
dep_jsx = git https://github.com/talentdeficit/jsx 2.8.0
dep_cowboy = git https://github.com/extend/cowboy 1.0.4
dep_cowlib = git https://github.com/extend/cowlib 1.3.0
dep_ranch = git https://github.com/extend/ranch 1.2.1
dep_parse_trans = git https://github.com/uwiger/parse_trans
dep_edown = git https://github.com/uwiger/edown.git 0.8

CT_SUITES = share

rel:: deps ebin/$(PROJECT).app

ebin/$(PROJECT).app:: 
	@export V=$$(git describe --tags --dirty=-d) && \
	sed -e "s/tbd/$$V/" src/$(PROJECT).app.in > src/$(PROJECT).app.src

.PHONY: .FORCE

include erlang.mk


