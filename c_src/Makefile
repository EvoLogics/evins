CC      ?= gcc
STRIP   ?= strip
CFLAGS  += -std=gnu99 -Iinclude -W -Wall -Werror -pedantic \
		  -D__USE_MINGW_ANSI_STDIO=1 -O2

LDFLAGS = -lm

# improve stripping performance (breaks debug info, reduces binary size)
CFLAGS += -fdata-sections -ffunction-sections
LDFLAGS += -Wl,--gc-sections

# debug info (don't forget to comment stripping out)
#CFLAGS += -g -DLOGGER -O0 -fsanitize=address
#LDFLAGS += -fsanitize=address

PSOURCES := $(wildcard src/*.c)
POBJS := $(patsubst %.c,%.o,$(PSOURCES))
PDEPS := $(patsubst %.o,%.dep,$(POBJS))

PROGS := $(patsubst src/%.c,../priv/%$(BIN_SFX),$(PSOURCES))

LSOURCES := $(wildcard lib/*.c)
LOBJS := $(patsubst %.c,%.o,$(LSOURCES))
LDEPS := $(patsubst %.o,%.dep,$(LOBJS))

.PHONY: all clean
all: $(PROGS)

clean:
	@echo "    CLEAN"
	@-rm -f $(PROGS) $(POBJS) $(PDEPS) $(LOBJS) $(LDEPS)

../priv/%$(BIN_SFX): src/%.o $(LOBJS)
	@echo "    LD  " $@
	@$(CC) $< $(LOBJS) $(LDFLAGS) -o $@
	@$(STRIP) $@

.PRECIOUS: %.o
%.o: %.c
	@echo "    CC  " $<
	@$(CC) $(CFLAGS) -MMD -MP -MF $(patsubst %.c,%.dep,$<) -c $< -o $@

-include $(wildcard src/*.dep) $(wildcard lib/*.dep)
