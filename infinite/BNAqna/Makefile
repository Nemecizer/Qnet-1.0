CC = gcc
CFLAGS = -Wall -O2 -std=c99 -pedantic
LDFLAGS = -lm -Wl,-headerpad_max_install_names

all: bna_qna

bna_qna: bna_qna.c
	$(CC) $(CFLAGS) -o bna_qna bna_qna.c $(LDFLAGS)

clean:
	rm -f bna_qna

.PHONY: all clean
