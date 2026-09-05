CC = gcc
CFLAGS = -Wall -O2 -std=c99 -pedantic
LDFLAGS = -lm -Wl,-headerpad_max_install_names

all: bna_rqna

bna_rqna: bna_rqna.c
	$(CC) $(CFLAGS) -o bna_rqna bna_rqna.c $(LDFLAGS)

test: bna_rqna
	./bna_rqna --selftest

clean:
	rm -f bna_rqna

.PHONY: all clean test
