PROJECT = riusbl
DEPS = evins
dep_evins = git https://github.com/hamer/evins

otp_release = $(shell erl +A0 -noinput -boot start_clean -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt()')
otp_20plus = $(shell test $(otp_release) -ge 20; echo $$?)

ifeq ($(otp_20plus),0)
	ERLC_OPTS += -Dfloor_bif=1
	TEST_ERLC_OPTS += -Dfloor_bif=1
endif

include ../../erlang.mk
