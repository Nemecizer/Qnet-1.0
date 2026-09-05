# fBNAsim Makefile - Finite-Buffer Network Simulator
#
# Usage:
#   make                Build with OpenMP support (default)
#   make OPENMP=0       Build without OpenMP
#   make clean          Remove build artifacts

CC = cc
CFLAGS = -Wall -Wextra -O2 -std=c99
# -headerpad_max_install_names reserves space in the Mach-O header for
# install_name_tool to add LC_RPATH entries when packaging into a .app
# bundle (see build_app.sh). Harmless at runtime.
LDFLAGS = -lm -Wl,-headerpad_max_install_names

# OpenMP support (Apple Clang + Homebrew libomp) — enabled by default
OPENMP ?= 1
ifeq ($(OPENMP),1)
OMP_PREFIX = $(shell brew --prefix libomp 2>/dev/null || echo /opt/homebrew/opt/libomp)
CFLAGS  += -Xpreprocessor -fopenmp -I$(OMP_PREFIX)/include
LDFLAGS += -L$(OMP_PREFIX)/lib -lomp
endif

TARGET = fBNAsim

SRCS = main.c parser.c rng.c distributions.c event_queue.c simulator.c stats.c
OBJS = $(SRCS:.c=.o)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $(TARGET) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Dependencies
main.o: main.c parser.h simulator.h stats.h
parser.o: parser.c parser.h distributions.h rng.h
rng.o: rng.c rng.h
distributions.o: distributions.c distributions.h rng.h
event_queue.o: event_queue.c event_queue.h
simulator.o: simulator.c simulator.h parser.h rng.h distributions.h event_queue.h stats.h
stats.o: stats.c stats.h parser.h

clean:
	rm -f $(OBJS) $(TARGET)
