# Changelog

## 1.0.0-rc.4

Released 2026-11-04.

### Bug fixes

First install no longer fails with "the selected install location is unavailable" when the default directory does not exist yet ([#2](https://github.com/FengYinYH/IdentityV-Launcher/issues/2)).

Auxiliary status code `304` from the download core is no longer treated as an unknown error that aborts the download ([#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3)).

## 1.0.0-rc.3

2026-10-09

### Changes

The feedback contact email is now `FengYinYH@icloud.com`, and the public repository is unified as [FengYinYH/IdentityV-Launcher](https://github.com/FengYinYH/IdentityV-Launcher).

## 1.0.0-rc.2

2026-10-05

### New features

Multilingual support following the system language: Simplified Chinese, Traditional Chinese and English.

Audio input and output follow the system default device and switch with it, instead of staying bound to the device present at launch.

### Changes

Mainland and global first installs, verification and repair now share the same NetEase download core.

IDV-Login support updated to 6.3.2 stable; the launcher manages updates and disables the component's own updater and remote hotfixes.

Default game directories are unified to ASCII `IdentityV/CN` and `IdentityV/Global`; old default directories migrate automatically after the game exits.

The hang reminder stays enabled together with the launcher; the menu toggle is removed.

The game window's menu bar name is now the game name and follows the selected language.

### Bug fixes

Fixed some emoji not displaying correctly.

## 1.0.0-rc.1

2026-09-23 public release. The first release candidate with the launcher, first-party installation, runtime download and game launch. The public package defaults to `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`; the emoji2 fix in the repository was only a local maintenance candidate at that time and was not part of that default runtime.

Known issues (confirmed after release): some combined emoji render as boxes in chat; in-game voice messages recorded with the built-in microphone crackle about every three seconds on playback. See [known issues](docs/knownIssues.md) for diagnosis and follow-up.

Planned features (not part of RC1):

- UI redesign
- Metal FX upscaling and frame interpolation
- Audio device following the system setting
- Multiple game instances (future plan, low priority)
