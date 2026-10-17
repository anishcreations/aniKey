# Interface

aniKey is a compact native macOS app for sending keyboard and mouse input to a paired Android device.

- Choose a paired device, then connect or disconnect manually. The status area shows connection state and details.
- Type with the Mac keyboard, use the on-screen key controls, or send clipboard text.
- Move the phone pointer over the pad. Click to select; hold and drag to move while the mouse button remains down. A secondary click sends the secondary mouse button.
- Two-finger vertical movement sends mouse-wheel scrolling. Two-finger sideways movement sends a horizontal mouse drag. The Back, Home, and Recents buttons provide separate navigation actions.
- Adjust the pad with the size control or resize the window. The local marker shows the Mac pointer position; aniKey does not receive the phone's pointer coordinates.

Bluetooth input is released when the pad loses focus or the connection closes. Three-finger gestures are left to macOS.

The phone receives Bluetooth mouse and keyboard reports, not touchscreen contacts. Android apps decide how clicks and held-button drags behave. Touchscreen edge gestures, pinch-to-zoom, and other touch-only behavior are outside this input mode.
