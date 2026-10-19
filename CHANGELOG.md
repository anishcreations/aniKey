# Changelog

## Unreleased

Planned version: **0.1.0**.

### Added

- Native macOS Bluetooth keyboard and mouse input for paired Android devices.
- Keyboard forwarding, text entry, key buttons, and clipboard typing.
- Pointer movement, click-and-drag, two-finger vertical scrolling and sideways dragging, with adjustable pad size.
- Back, Home, and Recents controls.
- Saved two-finger scroll speed with Extra slow, Gentle, Standard, and Fast options.
- On-pad mouse guide explaining clicks, scrolling, and app-dependent dragging.
- Command-line text and key input, dry-run output, and configurable key timing.

### Fixed

- Improved pointer movement and release behavior during dragging and scrolling.
- Send scroll steps immediately and keep recognized sideways gestures active when macOS cancels the raw touch stream.
- Prevented mouse input from using the consumer-control report associated with media keys on some paired devices.
- Kept the app responsive while Bluetooth connections and input writes are in progress.
