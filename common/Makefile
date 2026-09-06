# The shared C headers have their own tests, because three solver engines now
# depend on them and a defect in one would show up as three unrelated parity
# failures. Header-only libraries have no natural home for a test; this is it.

CC = gcc
# -ffp-contract=off for the same reason the engines use it: bnet_fsum's
# exactness claim is about individual operations, and a fused multiply-add
# would quietly change what the tests are checking.
CFLAGS = -Wall -Wextra -O2 -std=c99 -pedantic -ffp-contract=off
LDFLAGS = -lm

.PHONY: all test clean

all: test

test: tests/test_json tests/test_pyrandom tests/test_fsum
	./tests/test_json
	./tests/test_pyrandom
	./tests/test_fsum

tests/test_json: tests/test_json.c bnet_json.h
	$(CC) $(CFLAGS) -o $@ tests/test_json.c $(LDFLAGS)

tests/test_pyrandom: tests/test_pyrandom.c bnet_pyrandom.h
	$(CC) $(CFLAGS) -o $@ tests/test_pyrandom.c $(LDFLAGS)

tests/test_fsum: tests/test_fsum.c bnet_fsum.h
	$(CC) $(CFLAGS) -o $@ tests/test_fsum.c $(LDFLAGS)

clean:
	rm -f tests/test_json tests/test_pyrandom tests/test_fsum
