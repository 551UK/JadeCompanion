# JadeCompanion

Companion tweak for **Jade 1.0.5** that adds Haptic Touch / long-press actions to Jade's connectivity buttons without modifying Jade itself.

Target: rootless iOS 15-17 (initial development/testing is focused on iOS 16 + Dopamine).

Initial behavior:
- Wi-Fi: hold for Apple's Wi-Fi detail menu.
- Bluetooth: hold for Apple's Bluetooth device menu.
- AirDrop: hold for Apple's AirDrop menu.
- Airplane Mode: hold for Apple's expanded connectivity panel.
- Cellular Data: hold for Apple's expanded connectivity panel.
- Normal taps remain handled by Jade exactly as before.

The tweak hooks Jade's real `JadeConnectivityModule` buttons (`wifiButton`, `bluetoothButton`, `airplaneModeButton`, `cellularButton`, and `airDropButton`) rather than using screen coordinates.

## Status

Early test build. The stock Control Center detail controllers are private Apple APIs, so device testing is required before calling the behavior final.

## Compatibility

- Jade 1.0.5
- Rootless jailbreaks such as Dopamine
- iOS 15.0-17.x (iOS 16 is the primary target)

Jade remains untouched. Removing JadeCompanion restores Jade's original behavior.
