# Woods Whisper

An iOS, iPadOS and watchOS app for voice capture. You record on an Apple Watch
or iPhone/iPad, the audio is transcribed on the device with NVIDIA Parakeet TDT
v3, and the text can be reshaped with a small on-device model (LFM2.5) using
reusable prompt presets. No internet is needed after the models are downloaded
once. Optionally, an online Claude model can do the rewrite step.

The Watch can send recordings directly to an iPad over WiFi or Bluetooth,
without a phone.

## Installation

There are no prebuilt releases. Build it with Xcode 15 or later on a Mac:

```sh
brew install xcodegen
xcodegen generate
open WoodsWhisper.xcodeproj
```

In Xcode, select the **WoodsWhisper** scheme, set your signing team on each
target, and run on a real device (the models need the Neural Engine, which the
Simulator doesn't have). Run `xcodegen generate` again after adding source files
to an app target.

## More detail

[README_DETAIL.md](README_DETAIL.md) covers every feature; see also `docs/`.
