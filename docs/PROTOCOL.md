# Bluetooth keyboard protocol

aniKey uses public IOBluetooth APIs and an existing Bluetooth pairing. A transient Classic HID SDP service (`0x1124`) supplies the report descriptor in attribute `0x0206`; the phone retrieves it through SDP. The service identifies a keyboard (`HIDDeviceSubclass 0x40`).

The transport authenticates the connection and opens L2CAP control PSM `0x0011` and interrupt PSM `0x0013`. Input packets contain `A1 01`, followed by an eight-byte keyboard report: modifiers, reserved byte, and six key usages. A neutral report releases every key. Bluetooth boot mode keeps the keyboard report ID and eight-byte payload.

Report ID 1 also accepts a one-byte keyboard LED output report. HIDP handling includes GET/SET_PROTOCOL, GET_REPORT, LED SET_REPORT/DATA, suspend/resume, and malformed-request handshakes. No mouse or consumer-control reports are advertised or sent.

Keyboard input supports modifiers and up to six held usages. Text commands map US-layout ASCII to key presses and releases. Unsupported characters are rejected before the first key; transmission failures stop the action without retrying it.

Disconnect detaches delegates, releases held keys when possible, and closes owned channels. Stop also removes aniKey's local SDP service.

Specification: [Bluetooth Human Interface Device Profile](https://www.bluetooth.com/specifications/specs/human-interface-device-profile1-1-2ed2/).
