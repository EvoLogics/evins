PROJECT = evins

DEPS = parse_trans edown
dep_edown = git https://github.com/uwiger/edown.git 0.8
dep_parse_trans = git https://github.com/uwiger/parse_trans 3.3.0

CT_SUITES = share

otp_release = $(shell erl +A0 -noinput -boot start_clean -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt()')
otp_20plus = $(shell test $(otp_release) -ge 20; echo $$?)

ifeq ($(otp_20plus),0)
	ERLC_OPTS += -Dfloor_bif=1
	TEST_ERLC_OPTS += -Dfloor_bif=1
endif

include $(if $(ERLANG_MK_FILENAME),$(ERLANG_MK_FILENAME),erlang.mk)

APP_VERSION = $(shell cat $(RELX_OUTPUT_DIR)/$(RELX_REL_NAME)/version)
AR_NAME = $(RELX_OUTPUT_DIR)/$(RELX_REL_NAME)/$(RELX_REL_NAME)-$(APP_VERSION).tar.gz
EVINS_DIR ?= /opt/evins

$(shell m4 src/evins.app.src.m4 > src/evins.app.src)

.PHONY: install

clean-deps:: clean
	@for a in $$(ls $(DEPS_DIR)); do \
	  make clean -C $(DEPS_DIR)/$$a; \
	done;

install:: all
	@mkdir -p $(EVINS_DIR)
	@tar -xzf $(AR_NAME) -C $(EVINS_DIR)
