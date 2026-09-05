CC = gcc
CFLAGS = -Wall -O2
LDFLAGS = -lm -Wl,-headerpad_max_install_names

all: bna_sbd

bna_sbd: bna_sbd.c
	$(CC) $(CFLAGS) -o bna_sbd bna_sbd.c $(LDFLAGS)

clean:
	rm -f bna_sbd

.PHONY: all clean
