# zbm —— decmpfs LZBitmap 解压工具
#
#   make           编译出 zbm
#   make clean     清理
#
# 只依赖 C 标准库，无第三方依赖。

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
PREFIX  ?= /usr/local

zbm: zbm.c libzbitmap.c libzbitmap.h
	$(CC) $(CFLAGS) -o $@ zbm.c libzbitmap.c

install: zbm
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 zbm $(DESTDIR)$(PREFIX)/bin/zbm

clean:
	rm -f zbm *.o

.PHONY: clean install
