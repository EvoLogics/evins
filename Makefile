PROJECT = evins

DEPS = cowboy jsx parse_trans edown
dep_jsx = git https://github.com/talentdeficit/jsx 2.8.0
dep_cowboy = git https://github.com/extend/cowboy 2.6.0
dep_cowlib = git https://github.com/extend/cowlib 2.6.0
dep_ranch = git https://github.com/extend/ranch 1.2.1
dep_parse_trans = git https://github.com/uwiger/parse_trans
dep_edown = git https://github.com/uwiger/edown.git 0.8

CT_SUITES = share

C_SRC_TYPE = executable
C_SRC_OUTPUT ?= $(CURDIR)/priv/evo_serial

CFLAGS ?= -std=gnu99 -O3 -finline-functions -Wall -Wmissing-prototypes
LDFLAGS ?= -lm

otp_release = $(shell erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), init:stop()')
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
