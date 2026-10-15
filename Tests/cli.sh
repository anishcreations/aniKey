#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Anish Aryal

set -eu
binary=./build/anikey
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
test "$version" = '0.1.0'
printf 'aniKey %s\n' "$version" > "$tmp/expected"
"$binary" --version > "$tmp/version"
diff -u "$tmp/expected" "$tmp/version"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/aniKey.app/Contents/Info.plist)
test "$app_version" = "$version"
./build/aniKey.app/Contents/MacOS/anikey --version > "$tmp/app-version"
diff -u "$tmp/expected" "$tmp/app-version"
"$binary" --help > "$tmp/help"
/usr/bin/grep -q -- '--version' "$tmp/help"

for direction in left right up down; do
    case "$direction" in
        left) delta='FF 00' ;;
        right) delta='01 00' ;;
        up) delta='00 FF' ;;
        down) delta='00 01' ;;
    esac
    "$binary" --dry-run mouse-test "$direction" > "$tmp/probe" 2> "$tmp/diagnostic"
    printf '%s\n' "INTERRUPT A1 0A 00 $delta 00 00" > "$tmp/expected-probe"
    diff -u "$tmp/expected-probe" "$tmp/probe"
    /usr/bin/grep -q 'report=10 payload=5 wire=7' "$tmp/diagnostic"
    /usr/bin/grep -q 'channel=interrupt PSM=0x0013' "$tmp/diagnostic"
done
"$binary" --dry-run mouse-test left-click > "$tmp/probe" 2> "$tmp/diagnostic"
printf '%s\n' 'INTERRUPT A1 0A 01 00 00 00 00' 'INTERRUPT A1 0A 00 00 00 00 00' > "$tmp/expected-probe"
diff -u "$tmp/expected-probe" "$tmp/probe"

"$binary" --dry-run --delay-ms 0 text 'Hello' > "$tmp/text"
cat > "$tmp/expected" <<'EOF'
INTERRUPT A1 01 02 00 0B 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 08 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 0F 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 0F 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 12 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
EOF
diff -u "$tmp/expected" "$tmp/text"
for chord in enter tab backspace shift+tab F5; do
    case "$chord" in
        enter) modifier=00; usage=28 ;;
        tab) modifier=00; usage=2B ;;
        backspace) modifier=00; usage=2A ;;
        shift+tab) modifier=02; usage=2B ;;
        F5) modifier=00; usage=3E ;;
    esac
    "$binary" --dry-run --delay-ms 0 key "$chord" > "$tmp/key"
    printf '%s\n' "INTERRUPT A1 01 $modifier 00 $usage 00 00 00 00 00" 'INTERRUPT A1 01 00 00 00 00 00 00 00 00' > "$tmp/expected"
    diff -u "$tmp/expected" "$tmp/key"
done
for address in AA:BB:CC:DD:EE:FF aa-bb-cc-dd-ee-ff AABBCCDDEEFF; do
    "$binary" --device "$address" --dry-run --delay-ms 0 key enter > "$tmp/address"
    printf '%s\n' 'INTERRUPT A1 01 00 00 28 00 00 00 00 00' 'INTERRUPT A1 01 00 00 00 00 00 00 00 00' > "$tmp/expected"
    diff -u "$tmp/expected" "$tmp/address"
done
"$binary" --dry-run --delay-ms 2000 text '' > "$tmp/empty"
test ! -s "$tmp/empty"

"$binary" --dry-run --delay-ms 0 pin 1234 > "$tmp/pin"
cat > "$tmp/expected" <<'EOF'
INTERRUPT A1 01 00 00 1E 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 1F 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 20 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 21 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
INTERRUPT A1 01 00 00 28 00 00 00 00 00
INTERRUPT A1 01 00 00 00 00 00 00 00 00
EOF
diff -u "$tmp/expected" "$tmp/pin"
"$binary" --dry-run --delay-ms 0 key ctrl+a > "$tmp/chord"
printf '%s\n' 'INTERRUPT A1 01 01 00 04 00 00 00 00 00' 'INTERRUPT A1 01 00 00 00 00 00 00 00 00' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/chord"
"$binary" --dry-run check > "$tmp/check"
printf '%s\n' 'DRY RUN: check skipped; no Bluetooth accessed.' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/check"

bad() {
    set +e
    "$binary" "$@" > "$tmp/out" 2> "$tmp/error"
    result=$?
    set -e
    test "$result" -eq 2
    test ! -s "$tmp/out"
    test -s "$tmp/error"
}
bad --dry-run pin 12a4
bad --dry-run text 'abcé'
bad --dry-run mouse 20 0
bad --dry-run click left
bad --dry-run scroll 1
bad --dry-run nav home
bad --dry-run mouse 1junk 0
bad --dry-run key ctrl+unknown
bad --dry-run key F13
bad --dry-run mouse-test
bad --dry-run mouse-test volume
bad --dry-run mouse-test right extra
bad --dry-run key hyper+a
bad --dry-run text
bad --dry-run text Hello extra
bad --delay-ms 1.5 --dry-run key enter
bad --dry-run click extra
bad --delay-ms -1 --dry-run pin 1234
bad --delay-ms 2001 --dry-run pin 1234
bad --device not-an-address --dry-run pin 1234
bad --device AA:BB:CC:DD:EE:GG --dry-run key enter
bad --device
bad --gui --dry-run
bad --gui --device AA:BB:CC:DD:EE:FF
bad --dry-run pin
bad --dry-run list
bad --dry-run check extra
bad --dry-run nav
bad --dry-run nav volume
bad --dry-run nav home extra
bad --dry-run forget
bad --dry-run unpair
bad --dry-run pair
bad pin 1234
bad --wat
bad
printf '%s\n' 'PASS: CLI packet output and argument errors (no Bluetooth accessed)'
