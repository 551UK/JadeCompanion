# JadeCompanion

JadeCompanion fixes the broken hold / Haptic Touch behaviour on Jade's connectivity buttons on iOS 16.

Without this tweak, holding Wi-Fi, Bluetooth, AirDrop, Airplane Mode or Cellular Data can do nothing useful. After doing that, Jade can also get stuck so the next time you try to open it, the screen only blurs and the Jade interface does not slide up.

JadeCompanion fixes both problems.

## What it does

When you hold one of Jade's connectivity buttons, JadeCompanion opens the proper connectivity menu instead of letting Jade use the broken hold behaviour.

1. **Wi-Fi:** hold for Apple's Wi-Fi detail menu.
2. **Bluetooth:** hold for Apple's Bluetooth device menu.
3. **AirDrop:** hold for Apple's AirDrop menu.
4. **Airplane Mode:** hold for Apple's expanded connectivity panel.
5. **Cellular Data:** hold for Apple's expanded connectivity panel.
6. **Normal taps remain handled by Jade exactly as before.**

## What was broken

Jade already knew when you were holding one of the connectivity buttons. That is why you could still feel the haptic vibration.

The problem happened after the hold was detected.

Jade would start opening the connectivity menu and blur the background, but the actual connectivity menu would fail to appear on iOS 16.

That left Jade stuck halfway through opening the menu.

This caused two problems:

- Holding a connectivity button would not open anything useful.
- The next time you tried to open Jade, the screen could blur without the Jade interface appearing.

## How JadeCompanion fixes it

JadeCompanion catches the connectivity hold before Jade goes down the broken path.

Instead of letting Jade get stuck trying to open the menu, JadeCompanion opens Apple's real Control Center connectivity views directly.

In simple terms:

`Hold button -> JadeCompanion takes over -> proper connectivity menu opens`

Because Jade is no longer left stuck in its broken expanded state, the old **blur-only bug is fixed too**.

## Are the menus real?

Yes.

The Wi-Fi, Bluetooth and AirDrop menus use Apple's own Control Center views from iOS. They are not fake copies made by JadeCompanion.

That means things such as nearby Wi-Fi networks, Bluetooth devices and AirDrop options come from the same system used by Apple's Control Center.

## What JadeCompanion does not change

Normal taps still work through Jade exactly as before.

The tweak only takes over the broken hold behaviour for the connectivity buttons. Other Jade modules are left alone.

## Compatibility

- **iOS 16**
- **Rootless jailbreaks**, including Dopamine
- Jade installed

## Removing JadeCompanion

Jade itself is not permanently modified.

If you uninstall JadeCompanion and respring, Jade goes back to its original behaviour.
