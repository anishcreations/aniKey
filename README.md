# aniKey

**A native Bluetooth keyboard and mouse for macOS.** Type on an Android phone and control its pointer over Classic Bluetooth HID, with a compact desktop interface and keyboard command-line tools.

Version **0.1.0 (unreleased)** · macOS 13+ · GPL-3.0-or-later

## Features

- Mac keyboard input: letters, numbers, punctuation, modifiers, arrows, and function keys.
- Enter, Tab, Backspace, and Escape buttons.
- Clipboard text entry.
- Phone cursor movement with a hover pad and left/right clicks.
- Device picker and Connect, Cancel, and Disconnect controls.
- CLI text and key commands with configurable timing and dry-run output.

No phone companion app or third-party runtime is needed. Text and clipboard entry use US-layout ASCII. Android is the current target.

## Build

Requires macOS 13 or later and Apple's Command Line Tools.

```sh
make
open build/aniKey.app
```

The build produces `build/aniKey.app` and `build/anikey`.

## Use

1. Pair your Android phone with your Mac through Bluetooth settings.
2. Open aniKey, select the phone, and click **Connect**.
3. After **Input connected** appears, click the typing area and use your Mac keyboard.

Allow Bluetooth access on macOS when prompted. Input goes to the phone's active field or screen. **Type clipboard** enters plain text from the Mac clipboard. **⌘⇧Esc** returns keyboard focus to the Mac; **⌘** acts as **Ctrl** during keyboard forwarding.

## Phone cursor

While connected, move over the pad to move the phone pointer. Click the pad for a left click, or use **Left click** and **Right click**. Leaving the pad or switching away stops movement. The local marker shows your Mac input, not the phone pointer's exact position.

Scrolling and dragging items on the phone are not included.

## Command line

Find the phone's address with `list`, then replace `AA:BB:CC:DD:EE:FF` below:

```sh
./build/anikey list
./build/anikey --version
./build/anikey --device AA:BB:CC:DD:EE:FF text 'Hello'
./build/anikey --device AA:BB:CC:DD:EE:FF key ctrl+a
./build/anikey --device AA:BB:CC:DD:EE:FF key enter
./build/anikey --dry-run key tab
./build/anikey --gui
```

| Command or option | Purpose |
| --- | --- |
| `list` | List paired devices and addresses |
| `text 'TEXT'` | Type ASCII text |
| `key CHORD` | Send a key or chord, such as `shift+tab`, `backspace`, or `F5` |
| `pin DIGITS` | Type digits followed by Enter |
| `check` | Check the HID connection without keypresses |
| `--delay-ms N` | Key timing, 0–2000 ms; default 50 ms |
| `--dry-run` | Print packets without Bluetooth access |
| `--help` | Show commands and usage |
| `--version` | Print the application version |

Options precede the command. Each input command opens a session, sends the requested input, and closes the session.

## Single-file compilation

```sh
mkdir -p build
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  -mmacosx-version-min=13.0 Sources/Anikey.m \
  -framework AppKit -framework IOBluetooth -framework CoreBluetooth \
  -Wl,-sectcreate,__TEXT,__info_plist,Resources/Info.plist \
  -o build/anikey
codesign --force --sign - build/anikey
```

aniKey uses AppKit and public IOBluetooth APIs. The embedded plist supplies Bluetooth permission descriptions. CoreBluetooth handles permission and power state; keyboard input uses Classic Bluetooth HID.

[CLI reference](docs/CLI.md) · [Changelog](CHANGELOG.md) · [Protocol](docs/PROTOCOL.md) · [Interface](docs/DESIGN.md)

## License

Copyright © 2026 Anish Aryal. Licensed under the [GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`).
