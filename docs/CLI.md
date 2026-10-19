# CLI reference — 0.1.0

```sh
anikey [--device ADDRESS] [--dry-run] [--delay-ms N] COMMAND
anikey --gui
anikey --help
anikey --version
```

Use `./build/anikey` when running from the repository. Options come before the command. The device address accepts colon-separated, hyphen-separated, or twelve contiguous hexadecimal digits. `--device` is required for input commands and `check`, except in dry-run mode.

The native window provides keyboard input, an adjustable pointer pad with click/hold/drag input, two-finger vertical scrolling and sideways mouse dragging, and Back/Home/Recents buttons. The footer offers saved Extra slow, Gentle, Standard, and Fast two-finger scroll speeds. Three-finger gestures are left to macOS. These pad controls are GUI features; CLI commands remain listed below.

## Commands

| Command | Behavior |
| --- | --- |
| `list` | Print paired device addresses and names |
| `text 'Hello'` | Enter US-layout ASCII text |
| `key ctrl+a` | Press and release a key or chord |
| `pin 1234` | Enter digits, then Enter |
| `check` | Open and close HID channels without typing |

Supported chord modifiers are `ctrl`/`control`, `shift`, `alt`/`option`, and `gui`/`cmd`/`meta`. Examples: `shift+tab`, `alt+left`, and `ctrl+shift+a`. CLI `cmd` sends the HID GUI modifier; the window's Mac Command-to-Ctrl mapping applies only to physical keyboard forwarding.

Named keys include `enter`, `esc`/`escape`, `backspace`, `tab`, `space`, `capslock`, `insert`, `home`, `end`, `pageup`, `pagedown`, `delete`, `left`, `right`, `up`, `down`, `numlock`, `plus`, and `F1`–`F12`. Keyboard `home` is a cursor-navigation key. Use `plus` to name the plus key in a chord.

`--delay-ms N` sets the delay while a key is held and after it is released. The default is 50 ms; valid values are integers from 0 to 2000. `--dry-run` prints HIDP packets without Bluetooth access and is available for `text`, `key`, `pin`, and `check`. `list` uses Bluetooth and does not accept dry-run.

`--gui` opens the native window and accepts `--delay-ms`; choose the device in the window. `--help` and `--version` do not access Bluetooth. Each CLI input command opens a session, sends its input once, and closes the session.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Connection or input failure |
| `2` | Invalid arguments |

Errors are printed to standard error. Unsupported text is rejected before any characters are sent.

## Mouse diagnostics

`mouse-test ACTION` performs one explicit diagnostic operation. Valid actions are `left`, `right`, `up`, `down`, `left-click`, and `right-click`. A direction sends one button-free HID mouse report with a one-unit relative delta. A click sends a press and release pair. Each invocation then closes its session; it never enables continuous mouse control.

Inspect packets without touching Bluetooth:

```sh
./build/anikey --dry-run mouse-test right
```

A real-device test uses `--device ADDRESS` instead of `--dry-run` and sends actual phone input. Run a single direction first while watching the phone. Stop testing if it changes system controls rather than moving a visible cursor. Click tests are intended only after directional mouse recognition works.

Mouse diagnostics go to standard error and include report ID, payload/wire sizes, HIDP header, protocol mode, channel PSM, button bits, and relative deltas. They do not include keyboard input. Local descriptor and channel checks do not establish how Android interpreted the service.
