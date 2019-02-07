CC      ?= gcc
STRIP   ?= strip
CFLAGS  = -std=gnu99 -Iinclude -W -Wall -Werror -pedantic \
		  -fdata-sections -ffunction-sections \
		  -D__USE_MINGW_ANSI_STDIO=1

LDFLAGS = -lm -Wl,--gc-sections

PSOURCES := $(wildcard src/*.c)
POBJS := $(patsubst %.c,%.o,$(PSOURCES))
PDEPS := $(patsubst %.o,%.dep,$(POBJS))

PROGS := $(patsubst src/%.c,../priv/%,$(PSOURCES))

LSOURCES := $(wildcard lib/*.c)
LOBJS := $(patsubst %.c,%.o,$(LSOURCES))
LDEPS := $(patsubst %.o,%.dep,$(LOBJS))

.PHONY: all clean
all: $(PROGS)

clean:
	@echo "    CLEAN"
	@-rm -f $(PROGS) $(POBJS) $(PDEPS) $(LOBJS) $(LDEPS)

../priv/%: src/%.o $(LOBJS)
	@echo "    LD  " $@
	@$(CC) $< $(LOBJS) $(LDFLAGS) -o $@
	@$(STRIP) $@

.PRECIOUS: %.o
%.o: %.c
	@echo "    CC  " $<
	@$(CC) $(CFLAGS) -MMD -MP -MF $(patsubst %.c,%.dep,$<) -c $< -o $@

-include $(wildcard src/*.dep) $(wildcard lib/*.dep)
