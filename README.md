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


## v0.6.12 dismissal lifecycle fix

Keeps the working v0.6.11 native Connectivity platter, Airplane Mode behaviour and Apple's normal outside-tap dismissal path. It removes four manual beginAppearanceTransition:/endAppearanceTransition calls that JadeCompanion was incorrectly sending to the expanded container while Apple's click-presentation interaction was already driving that lifecycle. Stock CCUIModuleCollectionViewController changes sibling-module appearance instead of re-entering the expanded container's own appearance transition.


## v0.6.13 Jade dismissal crash fix

The SpringBoard crash log identifies Jade.dylib as the exception source during `CCUIContentModuleContainerViewController dismissModulePresentedContentAnimated:completion:`: Jade indexes element 0 of an empty mutable array. v0.6.13 therefore does not call `dismissPresentedContentAnimated:` or `dismissExpandedModuleAnimated:` for JadeCompanion's embedded Connectivity platter. Both feed through the crashing Jade hook.

Outside-tap dismissal now jumps directly to the same final UIKit operation that ControlCenterUI's `_closeExpandedModule:` eventually uses: `dismissViewControllerAnimated:completion:`. Jade is restored before the animation and the temporary embedded host is removed only in UIKit's completion block. Airplane Mode and platter presentation are unchanged.


## v0.6.14 expanded-state dismissal fix

v0.6.13 still left `CCUIContentModuleContainerViewController.isExpanded` set to YES when calling UIKit dismissal. ControlCenterUI's own `viewWillDisappear:` checks that flag and, when true, calls `_closeExpandedModule:`, which routes back through `dismissModulePresentedContentAnimated:completion:` and Jade's crashing hook.

v0.6.14 clears only the container's private expanded-state flag before calling `dismissViewControllerAnimated:completion:`. This prevents `viewWillDisappear:` from re-entering Jade's broken module-dismissal path. The native platter presentation, Airplane Mode behaviour, and outside-tap trigger are otherwise unchanged.
