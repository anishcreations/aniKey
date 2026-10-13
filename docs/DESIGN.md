# Interface

aniKey uses a compact AppKit window with native controls, system typography, and adaptive colors.

- The top row contains the device picker, Refresh, and Connect/Disconnect.
- Status shows the connection state. Details displays protocol information or a connection error.
- The typing area forwards the Mac keyboard while focused. Command acts as Ctrl; Command–Shift–Escape returns focus to the Mac.
- Enter, Tab, Backspace, Escape, and Type clipboard provide button-based input.

Key-button clicks are sent in order. Bluetooth operations run on a background thread so the window remains responsive during connection setup and input. Cancel is available while connecting.
