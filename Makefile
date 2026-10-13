# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Anish Aryal

CLANG := xcrun clang
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -O2 -mmacosx-version-min=13.0
FRAMEWORKS := -framework AppKit -framework IOBluetooth -framework CoreBluetooth
INFO := Resources/Info.plist
BINARY := build/anikey
APP := build/aniKey.app

.PHONY: all app run test test-ui clean
all: $(BINARY) app

$(BINARY): Sources/Anikey.m $(INFO)
	@mkdir -p build
	$(CLANG) $(CFLAGS) Sources/Anikey.m $(FRAMEWORKS) -Wl,-sectcreate,__TEXT,__info_plist,$(INFO) -o $@
	codesign --force --sign - $@

app: $(BINARY) $(INFO)
	@mkdir -p "$(APP)/Contents/MacOS"
	cp $(BINARY) "$(APP)/Contents/MacOS/anikey"
	cp $(INFO) "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"

run: app
	open -n "$(APP)"

build/protocol-tests: Tests/ProtocolTests.m Sources/Anikey.m
	@mkdir -p build
	$(CLANG) $(CFLAGS) -Wno-unused-function Tests/ProtocolTests.m $(FRAMEWORKS) -o $@

test: app build/protocol-tests
	./build/protocol-tests
	/bin/sh Tests/cli.sh

test-ui: build/protocol-tests
	./build/protocol-tests --ui-smoke "$(CURDIR)/build/ui-smoke.png"

clean:
	rm -rf build
