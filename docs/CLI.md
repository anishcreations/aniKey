# CLI reference — 0.1.0

```sh
anikey [--device ADDRESS] [--dry-run] [--delay-ms N] COMMAND
anikey --gui
anikey --help
anikey --version
```

Use `./build/anikey` when running from the repository. Options come before the command. The device address accepts colon-separated, hyphen-separated, or twelve contiguous hexadecimal digits. `--device` is required for input commands and `check`, except in dry-run mode.

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
