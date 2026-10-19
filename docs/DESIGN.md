# Interface

aniKey is a compact native macOS app for sending keyboard and mouse input to a paired Android device.

- Choose a paired device, then connect or disconnect manually. The status area shows connection state and details.
- Type with the Mac keyboard, use the on-screen key controls, or send clipboard text.
- Move the phone pointer over the pad. Click to select; hold and drag to move while the mouse button remains down. A secondary click sends the secondary mouse button.
- Two-finger vertical movement sends mouse-wheel scrolling. Two-finger sideways movement sends a horizontal mouse drag. The Back, Home, and Recents buttons provide separate navigation actions.
- The pad's visible guide explains pointing, clicking, scrolling, and mouse dragging. Dragging may select text or items rather than swipe pages; a tooltip and accessibility help provide the full guide.
- Adjust the pad with the size control or resize the window. The local marker shows the Mac pointer position; aniKey does not receive the phone's pointer coordinates.
- Choose Extra slow, Gentle, Standard, or Fast two-finger scrolling from the footer. The choice is saved; Extra slow is the default. This setting leaves pointer movement, held-click dragging, and physical mouse-wheel detents unchanged.

Bluetooth input is released when the pad loses focus or the connection closes. Three-finger gestures are left to macOS.

The phone receives Bluetooth mouse and keyboard reports, not touchscreen contacts. Android apps decide how clicks and held-button drags behave. Touchscreen edge gestures, pinch-to-zoom, and other touch-only behavior are outside this input mode.
