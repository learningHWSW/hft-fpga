CC      = cc
CFLAGS  = -O2 -Wall -Wextra -std=c11

itch_parser: itch_parser.c itch5.h
	$(CC) $(CFLAGS) -o $@ itch_parser.c

itch_hist: itch_hist.c
	$(CC) $(CFLAGS) -o $@ itch_hist.c

test: itch_parser itch_hist
	python3 gen_itch.py test.itch
	./itch_parser test.itch AAPL
	./itch_hist test.itch > /dev/null

clean:
	rm -f itch_parser itch_hist test.itch test.mold

.PHONY: test clean
