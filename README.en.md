[简体中文](README.md) · [繁體中文](README.zh-Hant.md) · [English](README.en.md)

# Identity V Launcher · 第五人格启动器

Identity V Launcher is an unofficial project that lets Apple Silicon Macs run the PC cross-platform edition of Identity V. It does not require Crossover or NetEase's game launcher. You can even play with a trackpad.

## Features

Download, verify, launch, repair, and uninstall both the Mainland China and Global versions.

The launcher supports Simplified Chinese, Traditional Chinese, and English, and follows the system language by default.

In-game key mapping is supported. Command maps to Windows Alt; F1–F9 on MacBook keyboards behave like the corresponding Windows keys, while F10–F12 retain their volume controls. These mappings do not affect keyboard behavior outside the game.

The launcher continuously monitors for possible hangs while it is running. Closing the main window does not stop monitoring; it stops when you quit the launcher. If a problem is detected, you can restart the game with one click or switch to the launcher window and restart it there.

Native-resolution rendering and macOS Game Mode in full screen are supported.

## Download and installation

1. Open the downloaded disk image and drag “第五人格启动器.app” into Applications.
2. Open the launcher, select Mainland China or Global, and choose Download Game. The launcher handles the download and installation.
3. Choose Launch Game.

To upgrade from RC1, quit the game before replacing the launcher. The old default game folder is renamed automatically, so you do not need to download the game again. For IDV Login, choose Update in the launcher; your accounts and settings are preserved.

## IDV Login

IDV Login is an optional component. You can download, repair, and play without installing it; use the game's official login flow instead.

The launcher currently supports the official version `6.3.2` and manages component updates.

## Notes

The first installation or launch may request macOS permissions. If administrator authorization is needed, macOS will show its own prompt. The launcher does not collect or upload your password.

Use Control+C and Control+V to copy and paste in the game, rather than Command+C and Command+V.

Game audio follows the current macOS default input and output devices, and this has been confirmed in a local candidate test. Switching time and different device combinations have not been measured, so seamless switching is not guaranteed. Voice-message bubble sounds remain a separate known issue. Choose devices in macOS System Settings → Sound.

A mouse polling rate above 1 kHz may cause severe stuttering. Function-row mapping on external keyboards may also be unreliable.

The project targets macOS 15 and later; the current candidate has only been tested on a real Mac running macOS 27. Some components have a technical minimum OS version of macOS 14, but that does not mean the complete product is verified or supported on macOS 14.

We make no guarantees about stability, performance, or avoiding bans. The author is not responsible for your rank points, deduction points, win rate, or dithering, so be especially careful in ranked matches. If that costs you, ask the author to host a custom match and make it up to you with the Spiral Whip.

## Feedback and development

The launcher can create a sanitized diagnostic bundle locally and hand it to your email app. You can review it and send it yourself; the launcher does not upload it in the background.

For maintenance, start with the [developer guide](docs/developerGuide.md). The [project map](projectMap.md) lists directories and script responsibilities, and [engineering decisions](docs/engineeringDecisions.md) explains the reasoning behind the design. Candidate details are in the [localization notes](docs/launcherLocalization.md), [shared game download flow](docs/downloadCoreUnification.md), [IDV Login source and policy](docs/idvLoginSourceAudit.md), and [audio device-following limits](docs/audioDefaultDeviceFollowing.md).

Original code is licensed under [GPL-3.0-or-later](LICENSE). The game and third-party components follow their own licenses; see [third-party notices](notices/README.md).

## Acknowledgements

Some Wine 11 work is based on an implementation by novak037.

IDV Login is developed by Keygen.
