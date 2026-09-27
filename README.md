# KeyCutAnalyzer

KeyCutAnalyzer measures a Schlage SC1 key from a side-profile photo. You place the shoulder on a crosshair, drag a line along the blade bottom, and set five markers on the cut roots. The app reports a 5-digit bitting code, bow to tip.

The measurement math lives in the `KeyCutCore` Swift package (Foundation only). The iOS app, `KeyCutAnalyzer`, is a SwiftUI camera shell around that package. There is no Mac Catalyst target. Run it as an iPad app on a Mac with the Xcode destination **My Mac (Designed for iPad)** so the Mac camera is available. The iOS Simulator has no camera.

## Current limitation

The current design has trouble matching physical measurements. Spacing and depth share one scale, taken from the distance between marker 1 and marker 5 (0.6248 in). On a real key the chart depths do not land on the cut roots: the blade height in the picture is shorter than that horizontal scale when the lens is not square to the side of the key.

## SC1 assumptions

Schlage Classic SC1 uses the first five cut stations on the chart. The chart’s sixth station, 1.012 in, is stored and unused.

- Scale for both spacing and root depth is the span from cut 1 to cut 5, 0.6248 in. The shoulder crosshair is the station origin.
- The key is in side profile, shoulder on the left, blade to the right, bites up. You move the photo under the marks.
- Root depth is the perpendicular distance from the blade-bottom line to the marker crosshair.
- Depth tolerance is ±0.002 in. A miss within ±0.005 in is a caution. Beyond that is out of tolerance. Spacing tolerance is ±.001 in. MACS is 7. Primus side bitting and pin-length tables are not implemented.
- Specs and the readout are in inches, to three decimal places.

## Open and run

1. Open `KeyCutAnalyzer.xcodeproj` in Xcode 27 (the iOS 27 SDK). No XcodeGen step.
2. Select the **KeyCutAnalyzer** scheme.
3. Select the run destination. For a physical iPhone that is in Developer Mode, choose that iPhone. Otherwise choose **My Mac (Designed for iPad)**.
4. Run. iOS asks to use the camera. The usage string is “The camera measures the key.” Tap Allow. The rear wide camera starts. If you previously denied access, tap **Enable Camera** in the app, turn Camera on for KeyCutAnalyzer, and return to the app.
5. Capture a still or open a photo. Place the bottom of the shoulder on the crosshair, drag the blade line along the bottom of the blade, put each crosshair on a cut root, and tap Adjust.

The iOS Simulator has no camera. A phone in Developer Mode does: unlock it, trust the computer, and leave Developer Mode on under Settings → Privacy & Security.

On iPad-width layouts the readout is a side panel. On a compact width it sits under the camera. Today the catalog is only Schlage SC1. The app is landscape only.

## Tests

From the repository root:

```sh
swift test
```

That builds `KeyCutCore` and checks unit formatting, nearest-bite ties, depth tolerance, MACS, manual marker spacing and depth, and synthetic SC1 keys (including 35241 and 08046) at an identity pose and after rotation, scale, translation, and flips.
