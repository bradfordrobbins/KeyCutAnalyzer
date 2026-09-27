# KeyCutAnalyzer

KeyCutAnalyzer reads a Schlage SC1 key from a live side-profile camera image. It recovers rotation, scale, and translation, draws the blade-bottom datum, the shoulder, and each cut, and shows the 5-digit bitting code bow to tip.

The measurement math lives in the `KeyCutCore` Swift package (Foundation only). The iOS app, `KeyCutAnalyzer`, is a SwiftUI camera shell around that package. There is no Mac Catalyst target. Run it as an iPad app on a Mac with the Xcode destination **My Mac (Designed for iPad)** so the Mac camera is available. The iOS Simulator has no camera.

## SC1 assumptions

Schlage Classic SC1 uses the first five cut stations on the chart. The chart’s sixth station, 1.012 in, is stored and unused.

- Scale comes from the full uncut blade height, 0.343 in, measured from the straight bottom edge to the full-height blade just off the shoulder.
- The key is in side profile on a contrasting background. Bow left or right, bitting up or down, and camera distance are handled by the fit.
- Root depth is the minimum bottom-distance inside a window on the 0.031 in root flat at each spec station.
- Depth tolerance is +.002 in / −0. Spacing tolerance is ±.001 in. MACS is 7. Primus side bitting and pin-length tables are not implemented.
- Specs are stored in inches. The screen shows millimeters (`inches × 25.4`) to three decimal places.

## Open and run

1. Open `KeyCutAnalyzer.xcodeproj` in Xcode 27 (the iOS 27 SDK). No XcodeGen step.
2. Select the **KeyCutAnalyzer** scheme.
3. Select the run destination **My Mac (Designed for iPad)**.
4. Run. Allow the camera when asked. The usage string is “The camera measures the key.”
5. Hold an SC1 key in side profile against a contrasting background. The readout stays empty, with “Hold the key in profile”, until a key locks.

On iPad-width layouts the readout is a side panel. On a compact width it sits under the camera. The key-type control lists the catalog. Today that catalog is only Schlage SC1.

Live analysis uses Vision contour detection (`VNDetectContoursRequest`) at up to 1920 px on the long side, about 10 frames per second, so the preview stays smooth. Contours are the right tool for a root depth, which is an edge. On iOS 27, tap the key to isolate it with `GenerateIterativeSegmentationRequest` at the `.accurate` quality level (WWDC26 tap-to-segment). Double-tap clears that seed. The on-device segmentation model may download the first time. The camera overlay was not run on a device from the environment that produced this project.

## Tests

From the repository root:

```sh
swift test
```

That builds `KeyCutCore` and checks millimeter formatting, nearest-bite ties, depth tolerance, MACS, and synthetic SC1 keys (including 35241 and 08046) at an identity pose and after rotation, scale, translation, and flips.
