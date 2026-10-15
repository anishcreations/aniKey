# Changelog

## Unreleased

Planned version: **0.1.0**.

### Added

- Two-finger vertical scrolling and sideways Back gestures anywhere in the cursor pad.
- Back, Home, and Recents controls, with three-finger gestures left to macOS.
- Adjustable pad size with a saved preference and resizable native window.
- Pad click-and-hold dragging, with button release on lift or cancellation.
- Native macOS Bluetooth keyboard interface for Android phones.
- Mac keyboard forwarding, basic key buttons, and clipboard text entry.
- Phone cursor control through hover movement, pad clicks, and secondary clicks.
- Independent relative mouse reports, coalesced movement, and focus-loss cleanup.
- Strict HID descriptor and channel validation with bounded mouse-only diagnostics.
- Device selection and manual connection controls.
- CLI text, key, and numeric entry commands.
- Configurable key timing and dry-run packet output.
- CLI help and version output, with a command reference.
- Classic Bluetooth HID transport using public macOS APIs.
- Standalone executable and app builds without an Xcode project.
- GNU GPL v3.0-or-later license.

### Fixed

- Start HID channels through asynchronous opening and explicit delegate registration, then wait for completion before enabling input.
- Use mouse report ID 10 with its five-byte layout, avoiding report ID 2 interpreted as media controls by existing paired hosts.
- Discard pending pad movement when input is unavailable, the pad loses focus, or the connection closes.
- Cancel pending scrolling on pad exit, resize, focus loss, or gesture cancellation; suppress momentum and prevent gestures from sending both scroll and navigation actions.
- Preserve mouse-button release when cancelling a drag behind a blocking Bluetooth write.
- Send Recents as an ordered Windows/Meta+Tab chord with separate modifier and key transitions.
