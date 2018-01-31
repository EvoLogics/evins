PROJECT = evins

DEPS = cowboy jsx parse_trans edown
dep_jsx = git https://github.com/talentdeficit/jsx 2.8.0
dep_cowboy = git https://github.com/extend/cowboy 1.0.4
dep_cowlib = git https://github.com/extend/cowlib 1.3.0
dep_ranch = git https://github.com/extend/ranch 1.2.1
dep_parse_trans = git https://github.com/uwiger/parse_trans
dep_edown = git https://github.com/uwiger/edown.git 0.8

CT_SUITES = share

C_SRC_TYPE = executable
C_SRC_OUTPUT ?= $(CURDIR)/priv/evo_serial

CFLAGS ?= -std=gnu99 -O3 -finline-functions -Wall -Wmissing-prototypes
LDFLAGS ?= -lm

include erlang.mk

APP_VERSION = $(shell cat $(RELX_OUTPUT_DIR)/$(RELX_REL_NAME)/version)
AR_NAME = $(RELX_OUTPUT_DIR)/$(RELX_REL_NAME)/$(RELX_REL_NAME)-$(APP_VERSION).tar.gz
EVINS_DIR ?= /opt/evins

.PHONY: install

install:: all
	@mkdir -p $(EVINS_DIR)
	@tar -xzf $(AR_NAME) -C $(EVINS_DIR)
