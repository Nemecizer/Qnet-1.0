CC = cc
CFLAGS = -Wall -O2 -std=c99
LDFLAGS = -lm -Wl,-headerpad_max_install_names

all: bna_fm

bna_fm: bna_fm.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f bna_fm

.PHONY: all clean
