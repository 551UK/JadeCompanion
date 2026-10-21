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



## v0.6.7 stability reset

v0.6.7 is rebuilt from the last known-loading v0.6.5 source. The v0.6.6 global Airplane Mode method hook, custom full-screen backdrop, and extra presentation teardown code have all been removed.

The only changes over v0.6.5 are:
- native platter cleanup is delayed until after Apple's close animation;
- the stock expanded Airplane controller is asked to observe and refresh its real radio state when the platter opens.


## v0.6.8 dismissal fix

- Airplane Mode behaviour is unchanged from v0.6.7.
- Tapping outside the native Connectivity platter no longer calls `dismissPresentedContentAnimated:`.
- The outside-tap delegate now closes the expanded module through Apple's dedicated `dismissExpandedModuleAnimated:` path, with a re-entry guard to prevent duplicate close requests.
- The existing delayed cleanup remains in place so JadeCompanion does not detach the embedded stock module during Apple's close animation.


## v0.6.9 native dismissal redesign

- Airplane Mode behaviour is preserved from v0.6.7.
- The Apple Connectivity module/container is still used for the visible native panel.
- JadeCompanion no longer invokes Apple's private `_UIClickPresentationInteraction` for this embedded module, because stock Control Center normally supplies a `CCUIModuleCollectionViewController` owner that Jade does not have.
- The container is switched into its native expanded state directly.
- A tap outside the native content is handled in Jade's existing view hierarchy, collapses the native expanded state, fades it out, restores Jade, and removes the temporary controller without using any UIKit/private presentation-dismiss call.
