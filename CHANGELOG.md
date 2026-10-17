# Changelog

## Unreleased

Planned version: **0.1.0**.

### Added

- Native macOS Bluetooth keyboard and mouse input for paired Android devices.
- Keyboard forwarding, text entry, key buttons, and clipboard typing.
- Pointer movement, click-and-drag, two-finger vertical scrolling and sideways dragging, with adjustable pad size.
- Back, Home, and Recents controls.
- Command-line text and key input, dry-run output, and configurable key timing.

### Fixed

- Improved pointer movement and release behavior during dragging and scrolling.
- Prevented mouse input from using the consumer-control report associated with media keys on some paired devices.
- Kept the app responsive while Bluetooth connections and input writes are in progress.
