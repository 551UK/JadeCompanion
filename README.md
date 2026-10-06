# JadeCompanion

JadeCompanion is a small companion tweak for **Jade 1.0.5**.

It fixes Jade's broken hold / Haptic Touch behaviour for the connectivity buttons on iOS 16. Instead of holding Wi-Fi, Bluetooth, AirDrop, Airplane Mode or Cellular Data and ending up with nothing opening — followed by Jade getting stuck on a blurred screen — JadeCompanion intercepts that broken path and opens the proper Control Center connectivity view.

## What this fixes

On Jade 1.0.5, the connectivity buttons already react to a hold. Even without JadeCompanion installed, you can hold Wi-Fi or Bluetooth and feel a haptic vibration.

So the original problem was **not** that Jade had no long-press support.

The problem was what happened **after** Jade detected the hold.

In simple terms, Jade was doing this:

1. You hold one of the connectivity buttons.
2. Jade detects the hold and gives you the haptic vibration.
3. Jade puts itself into its "expanded module" state and blurs the background.
4. Jade then asks Apple's Control Center to open the original Connectivity module.
5. On iOS 16, that final part does not successfully produce the Connectivity interface.
6. Jade is now left thinking an expanded module is open, even though nothing actually appeared.

That is why the old bug behaved the way it did.

You would hold Wi-Fi, Bluetooth, AirDrop, Airplane Mode or Cellular Data and nothing useful would appear. Then, after closing Jade and trying to swipe it open again, the screen would blur but the Jade interface itself would not slide back up.

The blur problem and the broken connectivity hold were therefore the **same underlying bug**.

## Why Focus, Screen Recording and other modules still worked

Jade can still expand modules such as **Focus** and **Screen Recording** because those are normal Apple Control Center modules that Jade can find and hand back to Apple's Control Center system.

The connectivity row is different.

Jade replaces Apple's normal connectivity area with its own custom class called **JadeConnectivityModule**. However, Jade's long-press code still tries to expand Apple's original module using the identifier:

`com.apple.control-center.ConnectivityModule`

On iOS 16 that lookup / presentation path does not work correctly after Jade has replaced the connectivity area.

Jade still switches itself into the blurred "expanded" state first, so when Apple's view fails to appear, Jade gets stuck halfway through the operation.

This appears to be an iOS 16 compatibility problem in Jade's old private-Control-Center integration rather than the developer simply forgetting to add long-press support. The support is there — the final expansion path is what is broken.

## How JadeCompanion fixes it

JadeCompanion does **not** try to force Jade's broken expansion method to work.

It uses Jade's own existing long-press recognizer to detect the hold, but for the connectivity module it stops Jade's original broken expansion code from running.

JadeCompanion then creates Apple's real Control Center Connectivity controller itself and displays the appropriate Apple view.

In simple terms, the original path was:

`Jade hold -> Jade enters expanded/blur state -> Apple Connectivity lookup fails -> Jade gets stuck`

JadeCompanion changes it to:

`Jade hold -> JadeCompanion intercepts it -> Apple's real Connectivity controller opens`

Because Jade never enters its broken connectivity expansion state, the old **blur-only bug is also fixed**.

## Hold behaviour

1. **Wi-Fi:** hold for Apple's Wi-Fi detail menu.
2. **Bluetooth:** hold for Apple's Bluetooth device menu.
3. **AirDrop:** hold for Apple's AirDrop menu.
4. **Airplane Mode:** hold for Apple's expanded connectivity panel.
5. **Cellular Data:** hold for Apple's expanded connectivity panel.
6. **Normal taps remain handled by Jade exactly as before.**

## Are these fake menus?

No.

JadeCompanion is not recreating a fake Wi-Fi or Bluetooth list.

The Wi-Fi, Bluetooth and AirDrop content comes from Apple's own private Control Center controllers inside iOS. JadeCompanion only provides a safe container for those Apple controllers because Jade's original method of asking Control Center to expand the Connectivity module is the part that is broken.

That is why the Wi-Fi view can show real nearby networks, the currently connected network, lock icons and signal strength just like Apple's Control Center.

## What JadeCompanion changes

JadeCompanion only takes over the broken long-press behaviour for **Jade's connectivity module**.

Normal taps are left alone, so tapping Wi-Fi, Bluetooth, Airplane Mode, Cellular Data or AirDrop continues to use Jade's normal toggle behaviour.

Jade's other modules, including modules whose hold behaviour was already working, are not replaced.

## Compatibility

- **Jade 1.0.5**
- **iOS 16** is the main tested target
- **Rootless jailbreaks**, including Dopamine
- arm64 / arm64e devices supported by the target jailbreak environment

The tweak uses private Apple Control Center APIs because Jade itself is built around those private interfaces. Apple can change these APIs between iOS versions, so behaviour on versions other than the tested iOS 16 setup may differ.

## Removing JadeCompanion

Jade itself is not modified on disk.

JadeCompanion works as a separate injected tweak. Removing JadeCompanion and respringing returns Jade to its original behaviour.

## Credits

JadeCompanion is a compatibility / companion fix for **Jade 1.0.5**. Jade remains the original tweak and UI; JadeCompanion only replaces the broken iOS 16 connectivity long-press expansion path.
