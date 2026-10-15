# Interface

aniKey uses a compact AppKit window with native controls, system typography, and adaptive colors.

- The top row contains the device picker, Refresh, and Connect/Disconnect.
- Status shows the connection state. Details displays protocol information or a connection error.
- The typing area forwards the Mac keyboard while focused. Command acts as Ctrl; Command–Shift–Escape returns focus to the Mac.
- Enter, Tab, Backspace, Escape, and Type clipboard provide button-based input.
- A cursor pad below the keyboard shows a visible marker on hover. Mouse movement produces relative motion; pressing the pad performs a left click without holding a drag. Pad exit and focus loss stop control.
- Left/right click buttons become available after the HID connection completes. Hover never presses a remote button. Pad clicks use a press/release pair after pending movement; scroll events are ignored.

Key-button clicks are sent in order. Bluetooth operations run on a background thread so the window remains responsive during connection setup and input. Cancel is available while connecting.

Pointer motion is accumulated at up to 60 updates per second, with one motion write in flight. Fractional points are retained; pending movement is bounded and discarded when control ends. The local marker does not report Android cursor position.
