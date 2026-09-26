# Desktop Pet for macOS

An unofficial macOS port of [desktopPet](https://github.com/Adrianotiger/desktopPet) by Adriano Petrucci
(the eSheep revival). The animation engine is translated from the original C# code to Swift; the macOS
integration (windows, Dock and window detection, menu bar, pet downloads) is new.
Swift + AppKit, no Xcode project needed.

It reads the **same `animations.xml` pet files** as the Windows version, so every pet
made for desktopPet (and the online editor) works here unchanged.

This project is not affiliated with or endorsed by the desktopPet project. All credit for the original
application, the pet format and the pets goes to Adriano Petrucci and the pet authors listed in the
upstream [`Pets/pets.json`](https://github.com/Adrianotiger/desktopPet/blob/master/Pets/pets.json).

## Build & run

Requires macOS 12+ and Xcode command line tools (`xcode-select --install`).
`build-app.sh` also generates the app icon from the upstream esheep64 pet icon with
`Resources/make-icon.py`, which needs Pillow (`pip3 install pillow`) and an internet connection;
without them the app is built without an icon.

```bash
swift run                      # debug build, runs immediately
./build-app.sh                 # release build -> DesktopPet.app
open DesktopPet.app
```

You can also start it with a pet file: `swift run DesktopPet /path/to/animations.xml`.

The app lives in the **menu bar** (no Dock icon). From there you can add more pets,
switch between the pets from the upstream pet list, open any `animations.xml`, change the pixel size,
toggle sounds, and quit. Right-click a pet for a debug menu (jump to any animation / spawn).
Drag a pet with the mouse and fling it to toss it.

## What is ported

| Windows original | macOS port |
|---|---|
| `Animations.cs` / `Xml.cs` data model & XML loading | `PetModel.swift`, `PetXML.swift` |
| `DataTable.Compute` expressions (`screenW`, `areaH`, `random`, `randS`, `imageW`, `Convert(...)`, ...) | `Expression.swift` (tested against all 26 pets in the upstream repo) |
| `FormPet.cs` state machine: spawns, sequences, repeat/repeatfrom, start→end interpolation, border / gravity / taskbar (Dock) detection, flip, children, kill, sync, drag & toss physics | `PetWindow.swift` |
| `EnumWindows` / `GetWindowRect` walking on other apps' windows | `CGWindowListCopyWindowInfo` in `DesktopGeometry.swift` |
| Layered transparent WinForms window | Borderless clear `NSWindow` at `.floating` level, `CALayer` sprite with nearest-neighbour scaling |
| Tray icon + context menu | `NSStatusItem` menu |
| Pet download from `pets.json` | `PetCatalog.swift` |
| NAudio MP3 sounds | `AVAudioPlayer` |
| Settings (scale, multiscreen, sound, last pet) | `UserDefaults` |

Not ported: the pet editor, the Windows-Store/UWP project, auto-update, and the
"cut the sprite while leaving the screen" trick (unnecessary on macOS).

## Notes

* Walking on windows uses window bounds only, so it works without any extra permission.
  Window *titles* are only visible with Screen Recording permission; they aren't needed.
* Coordinates inside the engine are Quartz-style (origin top-left), matching the original
  code; conversion to AppKit's bottom-left space happens in `DesktopGeometry`.
* **No pets are included in this repository.** Like the Windows version, the app reads the pet list
  (`Pets/pets.json`) from the upstream repository and downloads a pet's `animations.xml` the first time
  you pick it (`PetCatalog.swift`). Downloads are cached in `~/Library/Application Support/DesktopPet/Pets/`,
  so pets keep working offline; a pet is downloaded again when its `lastupdate` in the list changes.
  The first launch needs an internet connection. *Pet → Refresh pet list* checks for new pets.
* Any other `animations.xml` can be opened via *Pet → Open animations.xml…*.

## License

Pending — see upstream. The original [desktopPet](https://github.com/Adrianotiger/desktopPet) repository
has no license file yet; its author has commented on reuse in
[issue #138](https://github.com/Adrianotiger/desktopPet/issues/138). This section will be updated once
upstream has a license.
