PROJECT = evins
core = $(subst src/,,$(wildcard src/core/*.erl))
COMPILE_FIRST = $(core:.erl=)

DEPS = cowboy jsx
dep_cowboy = pkg://cowboy 73f65d5a757dacf952887a32bc611be78773c33f
dep_cowlib = pkg://cowlib 0.6.2
dep_jsx = pkg://jsx v2.0.1
dep_ranch = pkg://ranch 0.10.0


rel: 

ebin/$(PROJECT).app: src/$(PROJECT).app.src

src/$(PROJECT).app.src: .FORCE
	@export V=$$(git describe --tags --dirty=-d) && \
	sed -e "s/tbd/$$V/" src/$(PROJECT).app.in > src/$(PROJECT).app.src

.PHONY: .FORCE

include erlang.mk


