# Interface

aniKey uses a compact AppKit window with native controls, system typography, and adaptive colors.

- The top row contains the device picker, Refresh, and Connect/Disconnect.
- Status shows the connection state. Details displays protocol information or a connection error.
- The typing area forwards the Mac keyboard while focused. Command acts as Ctrl; Command–Shift–Escape returns focus to the Mac.
- Enter, Tab, Backspace, Escape, and Type clipboard provide button-based input.
- A compact cursor pad shows a local marker. Hover moves the phone pointer. Press sends primary-button down immediately; sliding keeps it held; release sends any final movement and button up. A short press/release taps. Secondary clicks are handled on the pad without separate mouse buttons.
- Two-finger vertical gestures scroll. Horizontal swipes in either direction send one Back action on release, anywhere in the pad. Axis locking keeps one gesture from both scrolling and navigating; small or ambiguous diagonal swipes do not navigate.
- Sequences with three or more fingers are ignored, including their remaining two-finger scroll tails, to leave macOS system gestures alone.
- Back, Home, and Recents buttons provide system navigation. The Pad size slider changes the area and saves the setting; the window is also resizable.

Key-button clicks are sent in order. Bluetooth operations run on a background thread so the window remains responsive during connection setup and input. Cancel is available while connecting.

Pointer motion and vertical wheel input are accumulated at up to 60 updates per second, with one write in flight. Fractional points are retained; pending movement and scrolling are bounded and discarded on pad exit, resize, cancellation, focus loss, or disconnection. A held mouse button is released during cancellation, even when a press is already inside a blocking write. Scroll momentum is ignored. Starting two-finger scrolling also ends an active drag. The local marker does not report Android cursor position.

Android receives mouse input rather than touchscreen contacts. Apps decide how to handle a held-button drag; Home and Back remain explicit navigation actions.
