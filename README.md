# Cropmark

[简体中文](README.zh-CN.md) | **English**

A lightweight screenshot tool for macOS. Press `⌃⌘A`, drag a region, annotate it, and it lands on your clipboard — without ever leaving the keyboard. Lives in the menu bar, no Dock icon, no network.

## Features

- Global hotkey (`⌃⌘A` by default, changeable)
- Freezes every screen the instant you press it; hover to auto-detect a window — or a dialog, panel or card *inside* it — and click to take it
- Drag to select a region with a live pixel-size readout; release to get 8 resize handles, drag inside to move
- Annotation tools: rectangle / ellipse / arrow / pen / mosaic / text, 6 colors and 3 weights, `⌘Z` to undo
  - Hold Shift for a perfect square or circle; arrows snap to 45°
- `Enter` / double-click / "Done" → copy to clipboard. The clipboard carries both the image (PNG + TIFF) and a PNG file, so you can paste into chats and documents as an image, and into Finder, Slack, terminals, or Claude Code as a file
- `⌘S` / "Save" → the system save panel, defaulting to the Desktop, named `Screenshot 2026-09-07 14.30.12.png`
- `Esc` / right-click → cancel
- Optional "downscale to 1x" for Retina displays, set separately for copying and saving: pasted screenshots are no longer double-size in chats and documents, and the files are far smaller. The size label shows `@2x` / `@1x` for the current output
- The hotkey can be a bare `F1`–`F12` key
- Settings: hotkey, launch at login, capture sound, output scaling, whether the clipboard carries a file
- The interface follows your system language: Simplified Chinese and English
- Auto-update: checks GitHub once a day for a new version and offers a one-click upgrade. Can be turned off, and you can always check manually from the menu bar

## Install

1. Download the latest `Cropmark-x.y.z.dmg` from [Releases](https://github.com/phoxiao/cropmark/releases), open it, and drag Cropmark into Applications.
2. **First launch**: this build is not notarized by Apple, so double-clicking shows "cannot verify the developer". Go to **System Settings → Privacy & Security**, scroll to the bottom, click **Open Anyway**, and confirm once. You will not be asked again.
   You can also run this in a terminal instead:
   ```bash
   xattr -d com.apple.quarantine /Applications/Cropmark.app
   ```
3. **Screen Recording permission**: the first time you press the hotkey, macOS asks for authorization. Enable Cropmark under **System Settings → Privacy & Security → Screen Recording**. macOS will ask you to quit and reopen Cropmark; press the hotkey again afterwards.

If another app has also claimed `⌃⌘A` (it is the default screenshot shortcut in WeChat, QQ, and WeCom), both will fire and two capture overlays will appear at once. Some apps intercept the key at the system level, in which case Cropmark never receives it at all. Neither case can be detected or fixed from Cropmark's side — change the shortcut in the other app, or pick a different one in Cropmark's settings (`F1`–`F12` work on their own).

## Privacy

Cropmark collects nothing. Screenshots exist only on your clipboard or wherever you chose to save them; the Screen Recording permission is used solely to grab the screen at the moment you press the hotkey.

The only network request is the update check: once a day it fetches a version manifest (`docs/appcast.xml`) from GitHub. It downloads, never uploads. Cropmark asks whether to enable this on first launch, and you can turn it off in settings at any time.

When "also put a PNG file on the clipboard" is on (the default), each copy writes a PNG into `~/Library/Caches/Cropmark/Clipboard/`, keeping only the 20 most recent. Turn it off in settings if you would rather leave no files behind.

## Build from source

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make install      # generate project → compile → sign with your local dev certificate → copy to /Applications → launch
```

Other commands:

| Command | What it does |
|---------|--------------|
| `make build` | Compile the Debug build only |
| `make run` | Compile and launch from the build directory |
| `make test` | Unit tests and in-process functional tests |
| `make icon` | Regenerate the app icon. The artwork lives in `Cropmark/App/IconArtwork.swift`, shared with the menu bar icon |
| `make release` | Compile Release, sign (optionally notarize), package dmg / zip into `dist/` |
| `make clean` | Remove build products and the generated project |

Build products go to `~/Library/Caches/CropmarkBuild`.

On signing: `make install` and `make release` look for a local certificate automatically (Developer ID Application first, then Apple Development). Signing with a stable certificate is what keeps the Screen Recording permission from being invalidated on every rebuild. With only an ad-hoc signature you have to re-authorize each time; if you hit "the toggle is on but it keeps asking", run `tccutil reset ScreenCapture com.kivixiao.cropmark` and authorize again.

With a paid developer account, store your credentials once via `xcrun notarytool store-credentials <name>`, then run `NOTARY_PROFILE=<name> make release`. The script notarizes and staples automatically, so users no longer need the "Open Anyway" step.

## Releasing and auto-update

Updates go through [Sparkle](https://sparkle-project.org): the app reads `docs/appcast.xml`, which holds the latest version, download URL, and EdDSA signature. To release a new version:

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml` plus `CHANGELOG.md`, then commit
2. `make release`: build, sign, package into `dist/`, and generate `docs/appcast.xml` using the private key from your keychain
3. `git tag vX.Y.Z && git push origin vX.Y.Z`, then `gh release create vX.Y.Z dist/*.dmg dist/*.zip dist/SHA256SUMS.txt`
4. Commit and push `docs/appcast.xml` last. This must happen after the release assets are uploaded, or existing users will be sent to a 404

The signing key is generated once, via `<SPM cache>/artifacts/sparkle/Sparkle/bin/generate_keys`. The private key goes into your login keychain; put the printed public key into `SUPublicEDKey` in `project.yml`. To release from a different machine, export with `generate_keys -x <file>` and import with `generate_keys -f <file>`.

## Localization

Interface strings are keyed by their Chinese source text, with translations in `Cropmark/Resources/Localizable.xcstrings`. Code reads them through `L10n.t("中文")`, which falls back to displaying the key itself when no translation exists. Adding a language means adding a column to the String Catalog — no code changes.

Note that this README is translated by hand and is not part of that catalog. See [Documentation translations](#documentation-translations) below.

## Structure

```
Cropmark/App         menu bar, hotkey, settings window
Cropmark/Capture     ScreenCaptureKit capture, window detection, permissions
Cropmark/Session     one capture session: overlay window, selection state machine, toolbar
Cropmark/Annotation  annotation model and rendering (shared by preview and export)
Cropmark/Export      cropping and compositing, clipboard / save
CropmarkTests        unit tests and in-process functional tests
scripts/             icon generation, release packaging
```

## Documentation translations

GitHub renders exactly one `README.md` on a repository's home page and does not pick a translation based on the visitor's browser language. The language links at the top of each README are therefore manual — that is the standard workaround, not an oversight. English is the default here because most GitHub visitors read it.

`README.zh-CN.md` is where changes are written first (the author works in Chinese); this file is a hand translation. Update both in the same commit, or the two will drift apart.

## License

[MIT](LICENSE). Third-party dependencies are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
