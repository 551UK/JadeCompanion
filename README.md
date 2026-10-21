# JadeCompanion

JadeCompanion fixes the broken hold / Haptic Touch behaviour on Jade's connectivity buttons on iOS 16.

Without this tweak, holding Wi-Fi, Bluetooth, AirDrop, Airplane Mode or Cellular Data do nothing.... Also after attempting that action without my tweak, Jade can also get stuck so the next time you try to open it, the screen only blurs and the Jade interface does not slide up.

JadeCompanion fixes both problems.

## What it does

When you hold one of Jade's connectivity buttons, JadeCompanion opens the proper connectivity menu instead of letting Jade use the broken hold behaviour.

1. **Wi-Fi:** hold for Apple's native expanded Connectivity platter.
2. **Bluetooth:** hold for the same native expanded Connectivity platter.
3. **AirDrop:** keeps its existing dedicated AirDrop menu path.
4. **Airplane Mode:** hold for Apple's native expanded Connectivity platter.
5. **Cellular Data:** hold for Apple's native expanded Connectivity platter.
6. **Normal taps remain handled by Jade exactly as before.**
7. **A hold only opens the menu:** it does not turn the button on or off, including when you release your finger.

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

Instead of drawing its own replacement window, JadeCompanion now uses Apple's own `CCUIContentModuleContainerViewController` Haptic Touch presentation path for Wi-Fi, Bluetooth, Airplane Mode and Cellular Data. While that native platter is open, Jade's card is temporarily hidden so the two interfaces cannot overlap; Jade is restored before the native close animation.

In simple terms:

`Hold button -> JadeCompanion takes over -> proper connectivity menu opens`

Because Jade is no longer left stuck in its broken expanded state, the old **blur-only bug is fixed too**.


## Quick checks

- Tap Wi-Fi or Bluetooth briefly: it should toggle once, as it did before.
- Hold Wi-Fi, Bluetooth, AirDrop, Airplane Mode or Cellular Data: the correct menu should open without changing its toggle state.
- Release after a hold: nothing should turn off or back on.
- Close the menu, then try another short tap: Jade's normal toggling should still work.


## v0.6.6 behaviour

- The native Connectivity platter now has an opaque dark surface and a dedicated dark backdrop, so Jade cannot show through it.
- Tapping outside the platter dismisses it through the stock Control Center close path; cleanup waits until Apple's transition is idle to avoid the Safe Mode crash.
- Airplane Mode refreshes its real radio state before and after a tap so it can switch both on and off from the native platter.
