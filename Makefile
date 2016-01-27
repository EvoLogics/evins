PROJECT = evins
core = $(subst src/,,$(wildcard src/core/*.erl))
COMPILE_FIRST = $(core:.erl=)

DEPS = cowboy jsx
dep_jsx = pkg://jsx 2.8.0
dep_cowboy = pkg://cowboy 1.0.4
dep_cowlib = pkg://cowlib 1.3.0
dep_ranch = pkg://ranch 1.2.1

rel: 

ebin/$(PROJECT).app: src/$(PROJECT).app.src

src/$(PROJECT).app.src: .FORCE
	@export V=$$(git describe --tags --dirty=-d) && \
	sed -e "s/tbd/$$V/" src/$(PROJECT).app.in > src/$(PROJECT).app.src

.PHONY: .FORCE

include erlang.mk


