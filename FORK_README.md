# CrossWire Fork — v1

This fork of [Crosswire](https://github.com/casitasoftware/crosswire-source) 1.1.17
makes Windows apps behave like Mac apps under Crosswire:

- **Dock icons** use the macOS rounded icon shape instead of hard squares.
  Console windows get a terminal icon instead of the generic "exec" document.
- **App identity** — each app runs from its own `.app` bundle, so the Dock,
  Command-Tab and Force Quit show *Among Us* instead of *wine*, and macOS
  lets you assign the app to a desktop (Dock icon ▸ Options ▸ Assign To).
- **Games open in their own Space** — full screen in a new Space next to your
  desktop; swipe with three fingers (or Control-arrow) to switch back. The
  behavior is configurable per app under **Advanced ▸ Open in its own Space**
  (Games only / Always / Never).
- **No more flicker** — on notched Macs the full-screen window now covers the
  whole display, matching the size borderless games request. Previously macOS
  and the game resized the window back and forth every frame and DXVK rebuilt
  its swap chain thousands of times.
- **DirectX 11 fixed inside the app** — Crosswire shipped only the Direct3D 9
  part of DXVK, so Direct3D 11 games fell back to Wine's broken builtin
  (`InitializeEngineGraphics failed`). The release bundles DXVK 1.10.3 async
  D3D10/11 DLLs and MoltenVK 1.4.2, installed for any app with graphics mode
  on. Per-program overrides (for example BepInEx's `winhttp`) are now merged
  per DLL instead of replacing the graphics overrides.
- **Red Stop button** — while an app is running (including a launcher whose
  process exited but left children behind), the Play button turns into a red
  Stop button that shuts down that app's bottle.
- **Settings** — one switch in Settings ▸ General turns all of this off.

## Files added by the fork

- `ShellIntegration/CrosswireShell.m`, `CrosswireShellUI.m` — injected helpers
  (icon styling, app name, own-Space full screen).
- `CrosswireKit/Sources/CrosswireKit/Wine/ShellIntegration.swift`,
  `AppIdentityBundle.swift`, `GraphicsPack.swift` — launch wiring, per-app
  bundles, graphics pack.
- `scripts/build-shell-integration.sh` — builds the two helper dylibs.
- `scripts/assemble-local-app.sh` — assembles a complete `Crosswire.app` from an
  Xcode build plus the engine and the bundled extras.
- `GraphicsPack/` — DXVK 1.10.3 D3D10/11 DLLs (x64/x32) and MoltenVK 1.4.2,
  with license notices in `GraphicsPack/README.txt`.

## Build

Requires Xcode and SwiftLint (the project's build script enforces it).

```sh
xcodebuild -project Crosswire.xcodeproj -scheme Crosswire -configuration Release \
  -derivedDataPath <dir> CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO build
scripts/assemble-local-app.sh \
  <dir>/Build/Products/Release/Crosswire.app \
  /Applications/Crosswire.app \
  ./GraphicsPack \
  ./Crosswire.app
```

The engine is taken from an existing Crosswire installation. The result is
ad-hoc signed like the official app.

## License

GPL-3.0 / LGPL-2.1 as upstream. Bundled third-party components: DXVK
(zlib/libpng license) and MoltenVK (Apache-2.0); notices in
`GraphicsPack/README.txt`.
