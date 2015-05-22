PROJECT = evins
core = $(subst src/,,$(wildcard src/core/*.erl))
COMPILE_FIRST = $(core:.erl=)

DEPS = cowboy jsx
dep_cowboy = pkg://cowboy master
dep_jsx = pkg://jsx master

rel: 

ebin/$(PROJECT).app: src/$(PROJECT).app.src

src/$(PROJECT).app.src: .FORCE
	@export V=$$(git describe --tags --dirty=-d) && \
	sed -e "s/tbd/$$V/" src/$(PROJECT).app.in > src/$(PROJECT).app.src

.PHONY: .FORCE

include erlang.mk


