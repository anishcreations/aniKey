# Bluetooth keyboard and mouse protocol

aniKey uses public IOBluetooth APIs and an existing Bluetooth pairing. A transient Classic HID SDP service (`0x1124`) supplies the report descriptor in attribute `0x0206`; the phone retrieves it through SDP. The service identifies a keyboard and mouse (`HIDDeviceSubclass 0xC0`).

The transport authenticates the connection and opens L2CAP control PSM `0x0011` and interrupt PSM `0x0013`. Channels open asynchronously. Explicit public delegate registration starts the current macOS bridge; input waits for successful open-completion callbacks on both channels. Input packets contain `A1 01`, followed by an eight-byte keyboard report: modifiers, reserved byte, and six key usages. A neutral report releases every key. Bluetooth boot mode keeps the keyboard report ID and eight-byte payload.

Report ID 1 also accepts a one-byte keyboard LED output report. HIDP handling includes GET/SET_PROTOCOL, GET_REPORT, LED SET_REPORT/DATA, suspend/resume, and malformed-request handshakes. A limited consumer-control collection exposes only the navigation usages documented below.

Consumer report ID 2 is restricted to Android navigation: bit 0 is AC Back (`0x0224`) and bit 2 is AC Home (`0x0223`). Other bits, including volume and brightness controls, are always zero. In boot protocol, report ID 2 is reserved for the boot mouse, so navigation reports are blocked.

Mouse report ID 10 uses `A1 0A`, followed by five bytes: two button bits, signed relative X/Y, neutral Z, and signed vertical wheel. Scrolling uses the existing wheel field without changing the mouse descriptor or report length. Previously paired hosts may associate report ID 2 with consumer controls, which is why the mouse uses ID 10 in report mode. In negotiated boot mode, the mouse uses `A1 02` and the three-byte buttons/X/Y payload; wheel reports are rejected rather than silently truncated.

Hover movement and scrolling send zero button bits. Pad press sends button bit 0 immediately, followed by relative movement reports with that bit held. Release sends final held movement, then a neutral report. Secondary pad clicks send bit 1 as a press/release pair. Z always stays zero. GET_REPORT retains button state with zero movement and wheel so relative input cannot replay. Wheel accumulation is capped at 32 steps, with at most eight per packet.

Cancellation invalidates queued motion but preserves a button release on the transport worker. A press already inside `writeSync` may finish after cancellation; its following release checks the actual sent button state and clears it. Queued presses that have not started are discarded. Saved Bluetooth pairing is unaffected.

Recents uses a staged Windows/Meta+Tab keyboard chord: neutral, GUI modifier down, GUI+Tab down, Tab up while GUI remains down, then GUI up. The modifier leads Tab by 35 ms; Tab is held for 50 ms, followed by a 20 ms delay before modifier release. This follows Android's [Meta+Tab system shortcut](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android15-release/services/core/java/com/android/server/policy/PhoneWindowManager.java), also documented in [Samsung's keyboard shortcuts](https://www.samsung.com/us/support/answer/ANS10003477/). It adds no consumer usage, emits no media controls, and never retries with an alternative shortcut. Firmware determines how the shortcut is handled; these are not touchscreen contact reports.

Keyboard input supports modifiers and up to six held usages. Text commands map US-layout ASCII to key presses and releases. Unsupported characters are rejected before the first key; transmission failures stop the action without retrying it.

Disconnect detaches delegates, releases held keys and navigation usages when possible, and closes owned channels. Stop also removes aniKey's local SDP service.

Specification: [Bluetooth Human Interface Device Profile](https://www.bluetooth.com/specifications/specs/human-interface-device-profile1-1-2ed2/).

Android's standard mouse classification provides an on-screen cursor: [input device configuration](https://source.android.com/docs/core/interaction/input/input-device-configuration-files).

Local SDP validation requires the exact descriptor and control/interrupt PSMs 0x0011/0x0013. Remapped or malformed endpoints are rejected. Opened channels must match the requested PSM and submission, delegate registration, open callbacks, and writes must succeed. Zero legacy channel IDs alone are not a failure: modern macOS can omit them even when the underlying channel opens. No mouse report is automatically sent at connection startup. These checks verify local state, not the descriptor Android cached or recognized.
