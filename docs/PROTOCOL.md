# Bluetooth keyboard and mouse protocol

aniKey uses public IOBluetooth APIs and an existing Bluetooth pairing. A transient Classic HID SDP service (`0x1124`) supplies the report descriptor in attribute `0x0206`; the phone retrieves it through SDP. The service identifies a keyboard and mouse (`HIDDeviceSubclass 0xC0`).

The transport authenticates the connection and opens L2CAP control PSM `0x0011` and interrupt PSM `0x0013`. Channels open asynchronously. Explicit public delegate registration starts the current macOS bridge; input waits for successful open-completion callbacks on both channels. Input packets contain `A1 01`, followed by an eight-byte keyboard report: modifiers, reserved byte, and six key usages. A neutral report releases every key. Bluetooth boot mode keeps the keyboard report ID and eight-byte payload.

Report ID 1 also accepts a one-byte keyboard LED output report. HIDP handling includes GET/SET_PROTOCOL, GET_REPORT, LED SET_REPORT/DATA, suspend/resume, and malformed-request handshakes. Consumer-control reports are not advertised.

Mouse report ID 10 uses `A1 0A`, followed by five bytes: two button bits, signed relative X/Y, and neutral Z/wheel bytes. Report ID 2 is deliberately unused in report mode because previously paired hosts may associate it with consumer controls. The descriptor advertises the same five-byte layout. In negotiated boot mode, the mouse uses `A1 02` and the three-byte buttons/X/Y payload required by Bluetooth HID boot protocol.

Pad movement always sends zero button bits. Clicks send a press and neutral release. Z and wheel stay zero; no consumer-control reports are emitted. GET_REPORT retains button state with zero movement so relative motion cannot replay.

Keyboard input supports modifiers and up to six held usages. Text commands map US-layout ASCII to key presses and releases. Unsupported characters are rejected before the first key; transmission failures stop the action without retrying it.

Disconnect detaches delegates, releases held keys when possible, and closes owned channels. Stop also removes aniKey's local SDP service.

Specification: [Bluetooth Human Interface Device Profile](https://www.bluetooth.com/specifications/specs/human-interface-device-profile1-1-2ed2/).

Android's standard mouse classification provides an on-screen cursor: [input device configuration](https://source.android.com/docs/core/interaction/input/input-device-configuration-files).

Local SDP validation requires the exact descriptor and control/interrupt PSMs 0x0011/0x0013. Remapped or malformed endpoints are rejected. Opened channels must match the requested PSM and submission, delegate registration, open callbacks, and writes must succeed. Zero legacy channel IDs alone are not a failure: modern macOS can omit them even when the underlying channel opens. No mouse report is automatically sent at connection startup. These checks verify local state, not the descriptor Android cached or recognized.
