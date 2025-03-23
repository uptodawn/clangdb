# SPDX-License-Identifier: GPL-2.0

PREFIX ?= /usr/local

install:
	install -Dm755 clangdb.sh $(PREFIX)/bin/clangdb
