# KeyCutAnalyzer

KeyCutAnalyzer reads a Schlage SC1 key from a live side-profile camera image and shows the 5-digit bitting code.

Hold the key so the camera sees the blade in profile: bow, shoulder, and the five cuts, on a background that contrasts with the key. Distance and rotation do not matter. The app recovers scale from the uncut blade, then measures each root.

## SC1 assumptions

- SC1 is a 5-cut key. The catalog still stores the sixth station at 1.012 in, and the reader does not use it.
- Scale comes from the uncut blade height, 0.343 in: the straight bottom edge and the full height just off the shoulder.
- The picture is a profile. Primus side bits and pin tables are not part of this reading.
- Root depth is the distance from the blade bottom to the flat of the cut. The displayed code runs bow to tip.
- A root outside +.002 in / −0 of the nearest bite is marked. Adjacent bites that differ by more than MACS 7 get a short warning.

The keyway list is data (`KeyCatalog` in the KeyCutCore package). SC1 is the only entry. Another keyway is another spec, not a new screen.

## Run it

Open `KeyCutAnalyzer.xcodeproj` in Xcode. No XcodeGen step.

The target is iPhone and iPad (`TARGETED_DEVICE_FAMILY` 1, 2), iOS 17 or later, including My Mac (Designed for iPad). Mac Catalyst is off.

For a live camera, run **My Mac (Designed for iPad)**. The first time, choose your development team in Signing & Capabilities so Xcode can sign the app. The iOS Simulator has no camera: the app will build and launch there, and it will show that no camera is available instead of inventing a bitting code.

On iPhone the camera is full screen and the readout sits along the bottom, in portrait and landscape. On iPad the readout sits beside the camera.

## Tests

KeyCutCore is a Foundation-only package. From `KeyCutCore`:

```bash
swift test
```
