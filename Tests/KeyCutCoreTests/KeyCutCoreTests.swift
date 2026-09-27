import XCTest
@testable import KeyCutCore

final class KeyCutCoreTests: XCTestCase {
    private let spec = KeyCatalog.sc1

    func testMillimeterConversionAndFormatting() {
        let stations = [0.231, 0.3872, 0.5434, 0.6996, 0.8558]
        let stationText = ["5.867", "9.835", "13.802", "17.770", "21.737"]
        for (inches, text) in zip(stations, stationText) {
            XCTAssertEqual(Units.formatMillimeters(Units.millimeters(fromInches: inches)), text)
        }

        let depths = [0.335, 0.320, 0.305, 0.290, 0.275, 0.260, 0.245, 0.230, 0.215, 0.200]
        let depthText = ["8.509", "8.128", "7.747", "7.366", "6.985", "6.604", "6.223", "5.842", "5.461", "5.080"]
        for (inches, text) in zip(depths, depthText) {
            XCTAssertEqual(Units.formatMillimeters(Units.millimeters(fromInches: inches)), text)
            XCTAssertEqual(spec.rootDepthsInches[depths.firstIndex(of: inches)!], inches)
        }

        XCTAssertEqual(spec.stationsInches[5], 1.012, accuracy: 1e-9)
        XCTAssertEqual(spec.cutCount, 5)
        XCTAssertEqual(spec.usedStationsInches.count, 5)
        XCTAssertEqual(Units.formatSignedMillimeters(0.004), "+0.004")
        XCTAssertEqual(Units.formatSignedMillimeters(-0.012), "-0.012")
    }

    func testNearestBiteTieAndTolerance() {
        let halfway = (spec.rootDepthsInches[0] + spec.rootDepthsInches[1]) / 2
        let tie = BittingMath.nearestBite(rootDepthInches: halfway, spec: spec)
        XCTAssertEqual(tie.bite, 0)
        XCTAssertLessThan(tie.deviationMillimeters, 0)

        let exact = BittingMath.nearestBite(rootDepthInches: 0.290, spec: spec)
        XCTAssertEqual(exact.bite, 3)
        XCTAssertEqual(exact.deviationInches, 0, accuracy: 1e-12)
        XCTAssertFalse(exact.outsideTolerance)

        let shallowButLegal = BittingMath.nearestBite(rootDepthInches: 0.335 + 0.002, spec: spec)
        XCTAssertEqual(shallowButLegal.bite, 0)
        XCTAssertFalse(shallowButLegal.outsideTolerance)

        let tooShallow = BittingMath.nearestBite(rootDepthInches: 0.335 + 0.003, spec: spec)
        XCTAssertEqual(tooShallow.bite, 0)
        XCTAssertGreaterThan(tooShallow.deviationMillimeters, 0)
        XCTAssertTrue(tooShallow.outsideTolerance)

        let deepButLegal = BittingMath.nearestBite(rootDepthInches: 0.335 - 0.002, spec: spec)
        XCTAssertEqual(deepButLegal.bite, 0)
        XCTAssertLessThan(deepButLegal.deviationInches, 0)
        XCTAssertFalse(deepButLegal.outsideTolerance)

        let tooDeep = BittingMath.nearestBite(rootDepthInches: 0.335 - 0.003, spec: spec)
        XCTAssertEqual(tooDeep.bite, 0)
        XCTAssertLessThan(tooDeep.deviationInches, 0)
        XCTAssertTrue(tooDeep.outsideTolerance)
        XCTAssertEqual(BittingMath.depthBand(deviationInches: -0.001, spec: spec), .nominal)
        XCTAssertEqual(BittingMath.depthBand(deviationInches: 0.002, spec: spec), .nominal)
        XCTAssertEqual(BittingMath.depthBand(deviationInches: -0.005, spec: spec), .caution)
        XCTAssertEqual(BittingMath.depthBand(deviationInches: 0.006, spec: spec), .fail)

        let between = BittingMath.nearestBite(rootDepthInches: 0.260 - 0.004, spec: spec)
        XCTAssertEqual(between.bite, 5)
        XCTAssertEqual(
            Units.formatSignedMillimeters(between.deviationMillimeters),
            Units.formatSignedMillimeters(Units.millimeters(fromInches: -0.004))
        )
    }

    func testMACS() {
        XCTAssertTrue(BittingMath.macsViolations(bites: [3, 5, 2, 4, 1], spec: spec).isEmpty)
        XCTAssertTrue(BittingMath.macsViolations(bites: [0, 7], spec: spec).isEmpty)

        let violations = BittingMath.macsViolations(bites: [0, 8, 0], spec: spec)
        XCTAssertEqual(violations.count, 2)
        XCTAssertEqual(violations[0].difference, 8)
        XCTAssertEqual(violations[0].leftCut, 1)
        XCTAssertEqual(violations[1].rightCut, 3)
        let warning = BittingMath.macsWarning(violations: violations, spec: spec)
        XCTAssertEqual(warning, "MACS 7: adjacent cuts differ by more than 7")

        let one = BittingMath.macsViolations(bites: [1, 9], spec: spec)
        XCTAssertEqual(BittingMath.macsWarning(violations: one, spec: spec), "MACS 7: cuts 1 and 2 differ by 8")
    }

    func testIdentityPoseRecovers35241() throws {
        let reading = try recovered([3, 5, 2, 4, 1], pose: .identity(pixelsPerInch: 1800))
        XCTAssertEqual(reading.code, "35241")
        assertDeviations(reading)
    }

    func testRotatedScaledTranslatedPosesRecover35241() throws {
        let degrees = 37.0 * Double.pi / 180
        let poses = [
            SyntheticPose(rotationRadians: degrees, pixelsPerInch: 1500, reflectBitting: false),
            SyntheticPose(rotationRadians: degrees + .pi, pixelsPerInch: 2100, reflectBitting: false),
            SyntheticPose(rotationRadians: -degrees, pixelsPerInch: 1700, reflectBitting: true),
            SyntheticPose(rotationRadians: degrees + .pi, pixelsPerInch: 1600, reflectBitting: true)
        ]
        for pose in poses {
            let reading = try recovered([3, 5, 2, 4, 1], pose: pose)
            XCTAssertEqual(reading.code, "35241", "pose \(pose)")
            assertDeviations(reading)
        }
    }

    func testSecondCode08046() throws {
        let pose = SyntheticPose(rotationRadians: 0.4, pixelsPerInch: 1650, reflectBitting: true)
        let reading = try recovered([0, 8, 0, 4, 6], pose: pose)
        XCTAssertEqual(reading.code, "08046")
        assertDeviations(reading)
        XCTAssertFalse(reading.macsViolations.isEmpty)
        XCTAssertNotNil(reading.macsWarning)
    }

    func testAspectFillKeepsPointOnTheKeyWhenCroppedOrLetterboxed() {
        let image = Size2D(width: 1000, height: 500)
        let point = Point2D(400, 200)
        let cropped = Size2D(width: 200, height: 400)
        let mapped = AspectFill.imageToView(point: point, image: image, view: cropped)
        let roundTrip = AspectFill.viewToImage(point: mapped, image: image, view: cropped)
        XCTAssertEqual(roundTrip.x, point.x, accuracy: 1e-6)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 1e-6)

        let letterboxed = Size2D(width: 800, height: 200)
        let wide = AspectFill.imageToView(point: point, image: image, view: letterboxed)
        let back = AspectFill.viewToImage(point: wide, image: image, view: letterboxed)
        XCTAssertEqual(back.x, point.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, point.y, accuracy: 1e-6)
    }

    func testSmallAlignmentRecoversTheCode() {
        let origin = Point2D(900, 700)
        let pixelsPerInch = 480.0
        let points = dense(SyntheticKey.contour(code: [3, 5, 2, 4, 1], spec: spec), step: 0.006).map { key in
            Point2D(origin.x + key.x * pixelsPerInch, origin.y - key.y * pixelsPerInch)
        }
        let angle = 3.0 * Double.pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let template = KeyPose(
            origin: Point2D(origin.x + 10, origin.y - 8),
            tipAxis: Point2D(cosine, sine),
            bittingAxis: Point2D(sine, -cosine),
            pixelsPerInch: pixelsPerInch * 1.03
        )
        let aligned = KeyAnalyzer.reading(fromBoundary: points, alignedNear: template, spec: spec)
        XCTAssertEqual(aligned?.reading.code, "35241")
        XCTAssertLessThan(abs(aligned?.alignment.rotationDegrees ?? 99), 6.5)
        XCTAssertEqual(aligned?.alignment.scale ?? 0, 0.97, accuracy: 0.03)
    }

    func testAlignmentStaysNearTheBlank() {
        let origin = Point2D(900, 700)
        let pixelsPerInch = 480.0
        let points = dense(SyntheticKey.contour(code: [3, 5, 2, 4, 1], spec: spec), step: 0.006).map { key in
            Point2D(origin.x + key.x * pixelsPerInch, origin.y - key.y * pixelsPerInch)
        }
        let angle = 25.0 * Double.pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let template = KeyPose(
            origin: origin,
            tipAxis: Point2D(cosine, sine),
            bittingAxis: Point2D(sine, -cosine),
            pixelsPerInch: pixelsPerInch
        )
        XCTAssertNil(KeyAnalyzer.reading(fromBoundary: points, alignedNear: template, spec: spec))
    }

    func testBladeScanRecoversCodeWithShoulderOnTheLeft() throws {
        let scan = try scan(code: [3, 5, 2, 4, 1], rotationDegrees: 0)
        XCTAssertEqual(scan.code, "35241")
        XCTAssertEqual(scan.minima.count, 5)
        XCTAssertEqual(scan.bites, [3, 5, 2, 4, 1])
        let gaps = (1..<5).map { scan.equalized[$0].x - scan.equalized[$0 - 1].x }
        XCTAssertEqual(gaps.max()! - gaps.min()!, 0, accuracy: 0.6)
        XCTAssertEqual(scan.levelingDegrees, 0, accuracy: 0.8)
    }

    func testBladeScanLevelsATiltedBlade() throws {
        let scan = try scan(code: [3, 5, 2, 4, 1], rotationDegrees: 4)
        XCTAssertEqual(scan.code, "35241")
        XCTAssertEqual(scan.levelingDegrees, -4, accuracy: 0.8)
    }

    func testDepthRatiosMatchTheBiteTableWithoutUsingInches() {
        let depths = [0.290, 0.260, 0.305, 0.275, 0.320].map { $0 * 417 }
        let bites = BladeScanner.bites(matching: depths, spec: spec)
        XCTAssertEqual(bites, [3, 5, 2, 4, 1])
        let again = BladeScanner.bites(matching: depths.map { $0 * 0.42 }, spec: spec)
        XCTAssertEqual(again, bites)
    }

    func testSC1BlankUsesTheDrawing() {
        let blank = KeyBlanks.sc1
        XCTAssertEqual(blank.overallMillimeters, 52.9, accuracy: 0.001)
        XCTAssertEqual(blank.bowWidthMillimeters, 26.5, accuracy: 0.001)
        XCTAssertEqual(blank.bladeLengthMillimeters, 26.15, accuracy: 0.001)
        XCTAssertEqual(blank.bladeWidthMillimeters, 8.85, accuracy: 0.001)
        let outline = SyntheticKey.blankOutline()
        let minX = outline.map(\.x).min() ?? 0
        let maxX = outline.map(\.x).max() ?? 0
        let minY = outline.map(\.y).min() ?? 0
        let maxY = outline.map(\.y).max() ?? 0
        XCTAssertEqual((maxX - minX) * 25.4, 52.9, accuracy: 0.05)
        XCTAssertEqual((maxY - minY) * 25.4, 26.5, accuracy: 0.05)
        XCTAssertEqual(maxX * 25.4, 26.15, accuracy: 0.05)
        let pose = SyntheticKey.blankPose(cropWidth: 1000, cropHeight: 501)
        XCTAssertEqual(pose.tipAxis.x, -1, accuracy: 1e-9)
        XCTAssertEqual(pose.bittingAxis.y, -1, accuracy: 1e-9)
        XCTAssertEqual(pose.origin.x, 1000 * (26.15 / 52.9), accuracy: 0.5)
    }

    func testCatalogIsOnlySC1() {
        XCTAssertEqual(KeyCatalog.all.map(\.id), ["SC1"])
        XCTAssertEqual(KeyCatalog.spec(id: "SC1")?.bladeHeightInches, 0.343)
        XCTAssertEqual(KeyCatalog.spec(id: "SC1")?.depthIncrementInches, 0.015)
    }

    private func scan(code: [Int], rotationDegrees: Double) throws -> BladeScan {
        let shoulder = Point2D(400, 500)
        let pixelsPerInch = 460.0
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let points = dense(SyntheticKey.contour(code: code, spec: spec), step: 0.004).map { key -> Point2D in
            let dx = key.x * pixelsPerInch
            let dy = -key.y * pixelsPerInch
            return Point2D(
                shoulder.x + cosine * dx - sine * dy,
                shoulder.y + sine * dx + cosine * dy
            )
        }
        let bottom = stride(from: 0.0, through: SyntheticKey.tipInches * pixelsPerInch, by: 4).map { along in
            Point2D(shoulder.x + cosine * along, shoulder.y + sine * along)
        }
        let search = BladeBottomFinder.choose(polylines: [bottom], shoulder: shoulder)
        let attempt = BladeScanner.scan(
            boundary: points,
            shoulder: shoulder,
            spec: spec,
            search: search
        )
        XCTAssertNotNil(attempt.scan)
        return try XCTUnwrap(attempt.scan)
    }

    func testBottomEdgePrefersTheStraightSpineOverTheCuts() {
        let shoulder = Point2D(40, 208)
        let tilt = 3.0 * .pi / 180
        let spine = stride(from: 24, through: 560, by: 4).map { x -> Point2D in
            let along = Double(x - 40)
            return Point2D(Double(x), 200 + along * tan(tilt))
        }
        let wavy = stride(from: 40, through: 480, by: 4).map { x -> Point2D in
            let along = Double(x - 40)
            return Point2D(Double(x), 80 + 18 * sin(along / 28))
        }
        let wall = stride(from: 0, through: 40, by: 2).map { step -> Point2D in
            Point2D(shoulder.x + Double(step), shoulder.y - Double(step) * 1.4)
        }
        let found = BladeBottomFinder.choose(polylines: [wavy, wall, spine], shoulder: shoulder)
        let bottom = found.bottom
        XCTAssertNotNil(bottom)
        XCTAssertFalse(found.edges.isEmpty)
        XCTAssertFalse(found.selected.isEmpty)
        XCTAssertEqual(bottom?.angleDegrees ?? 99, 3, accuracy: 0.8)
        XCTAssertEqual(bottom?.offsetPixels ?? 99, 8, accuracy: 2.5)
        XCTAssertGreaterThan(bottom?.spanPixels ?? 0, 300)
    }

    func testBottomEdgePrefersTheLowerOutlineOverTheFaceReflection() {
        let shoulder = Point2D(40, 208)
        let tilt = tan(3.0 * .pi / 180)
        let outline = stride(from: 24, through: 560, by: 4).map { x -> Point2D in
            let along = Double(x - 40)
            return Point2D(Double(x), 222 + along * tilt)
        }
        let reflection = stride(from: 24, through: 560, by: 4).map { x -> Point2D in
            let along = Double(x - 40)
            return Point2D(Double(x), 198 + along * tilt)
        }
        let found = BladeBottomFinder.choose(polylines: [reflection, outline], shoulder: shoulder)
        XCTAssertEqual(found.bottom?.angleDegrees ?? 99, 3, accuracy: 0.8)
        XCTAssertEqual(found.bottom?.offsetPixels ?? 99, -14, accuracy: 3)
        XCTAssertGreaterThan(found.bottom?.spanPixels ?? 0, 300)
    }

    func testBottomEdgeKeepsALongLineThatHasOnlyEndpoints() {
        let shoulder = Point2D(40, 208)
        let tilt = tan(3.0 * .pi / 180)
        let spine = [Point2D(48, 200), Point2D(560, 200 + 520 * tilt)]
        let speckle = stride(from: 0, through: 24, by: 1).map { step -> Point2D in
            Point2D(90 + Double(step) * 3, 207 + Double(step % 2))
        }
        let found = BladeBottomFinder.choose(polylines: [speckle, spine], shoulder: shoulder)
        XCTAssertEqual(found.bottom?.angleDegrees ?? 99, 3, accuracy: 1)
        XCTAssertGreaterThan(found.bottom?.spanPixels ?? 0, 400)
    }

    func testManualMarksRecoverDepthsFromTheStationSpan() {
        let span = spec.usedStationsInches[4] - spec.usedStationsInches[0]
        let pointsPerInch = 400 / span
        let bites = [3, 5, 2, 4, 1]
        let shoulder = Point2D(0, 200)
        let markers = bites.enumerated().map { index, bite in
            let height = spec.rootDepthsInches[bite] * pointsPerInch
            return Point2D(100 + Double(index) * 100, 200 - height)
        }
        let reading = ManualBladeMeasure.adjust(
            shoulder: shoulder,
            bladeEnd: Point2D(800, 200),
            markers: markers,
            spec: spec
        )
        XCTAssertEqual(reading?.code, "35241")
        XCTAssertEqual(reading?.pointsPerInch ?? 0, pointsPerInch, accuracy: 0.01)
        for (cut, bite) in zip(reading?.cuts ?? [], bites) {
            XCTAssertEqual(cut.bite, bite)
            XCTAssertEqual(cut.depthInches, spec.rootDepthsInches[bite], accuracy: 0.0001)
        }
    }

    func testManualMarksEqualizeSpacingAndKeepHeight() {
        let shoulder = Point2D(0, 200)
        let heights = [40.0, 70, 55, 80, 48]
        let along = [80.0, 230, 300, 410, 560]
        let markers = zip(along, heights).map { Point2D($0.0, 200 - $0.1) }
        let reading = ManualBladeMeasure.adjust(
            shoulder: shoulder,
            bladeEnd: Point2D(800, 200),
            markers: markers,
            spec: spec
        )
        let cuts = reading?.cuts ?? []
        XCTAssertEqual(cuts.count, 5)
        let gaps = zip(cuts, cuts.dropFirst()).map { $1.point.x - $0.point.x }
        XCTAssertEqual(gaps.count, 4)
        for gap in gaps {
            XCTAssertEqual(gap, gaps[0], accuracy: 0.01)
        }
        for (cut, height) in zip(cuts, heights) {
            XCTAssertEqual(200 - cut.point.y, height, accuracy: 0.01)
        }
    }

    func testStationMarksUseTheMarkerSpanAsScale() {
        let span = spec.usedStationsInches[4] - spec.usedStationsInches[0]
        let markers = (0..<5).map { Point2D(100 + Double($0) * 100, 160) }
        let marks = ManualBladeMeasure.stationMarks(
            shoulder: Point2D(0, 200),
            bladeEnd: Point2D(800, 200),
            markers: markers,
            spec: spec
        )
        let pointsPerInch = 400 / span
        XCTAssertEqual(marks?.stations.count, 5)
        for index in 0..<5 {
            XCTAssertEqual(marks?.stations[index].x ?? 0, spec.usedStationsInches[index] * pointsPerInch, accuracy: 0.01)
            XCTAssertEqual(marks?.stations[index].y ?? 0, 200, accuracy: 0.01)
        }
        XCTAssertEqual(marks?.stations[4].x ?? 0, (marks?.stations[0].x ?? 0) + 400, accuracy: 0.01)
    }

    func testManualMarksMeasurePerpendicularToATiltedBottom() {
        let shoulder = Point2D(0, 0)
        let along = Point2D(1, 1).normalized()
        let normal = Point2D(along.y, -along.x)
        let height = 40.0
        let markers = (0..<5).map { index in
            shoulder + along * Double(50 + index * 100) + normal * height
        }
        let reading = ManualBladeMeasure.adjust(
            shoulder: shoulder,
            bladeEnd: shoulder + along * 800,
            markers: markers,
            spec: spec
        )
        let span = spec.usedStationsInches[4] - spec.usedStationsInches[0]
        let expected = height / (400 / span)
        XCTAssertEqual(reading?.cuts.count, 5)
        for cut in reading?.cuts ?? [] {
            XCTAssertEqual(cut.depthInches, expected, accuracy: 0.0001)
        }
        let vertical = abs(markers[0].y - markers[0].x)
        XCTAssertGreaterThan(abs(vertical - height), 1)
    }

    private func dense(_ polygon: [Point2D], step: Double) -> [Point2D] {
        guard let first = polygon.first, polygon.count >= 2 else { return polygon }
        var result: [Point2D] = []
        let closed = polygon + [first]
        for index in 0..<(closed.count - 1) {
            let start = closed[index]
            let end = closed[index + 1]
            let delta = end - start
            let length = delta.length()
            let count = max(1, Int((length / step).rounded(.down)))
            for stepIndex in 0..<count {
                result.append(start + delta * (Double(stepIndex) / Double(count)))
            }
        }
        return result
    }

    private func recovered(_ code: [Int], pose: SyntheticPose) throws -> KeyReading {
        let raster = SyntheticKey.raster(code: code, spec: spec, pose: pose)
        let reading = KeyAnalyzer.reading(from: raster, spec: spec)
        XCTAssertNotNil(reading, "no lock for \(code) pose \(pose) raster \(raster.width)x\(raster.height)")
        return try XCTUnwrap(reading)
    }

    private func assertDeviations(_ reading: KeyReading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reading.cuts.count, 5, file: file, line: line)
        for cut in reading.cuts {
            XCTAssertEqual(cut.deviationMillimeters, 0, accuracy: 0.05, "cut \(cut.index) depth \(cut.rootDepthMillimeters) dev \(cut.deviationText)", file: file, line: line)
        }
    }
}
