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

        let tooDeep = BittingMath.nearestBite(rootDepthInches: 0.334, spec: spec)
        XCTAssertEqual(tooDeep.bite, 0)
        XCTAssertLessThan(tooDeep.deviationInches, 0)
        XCTAssertTrue(tooDeep.outsideTolerance)

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

    func testCatalogIsOnlySC1() {
        XCTAssertEqual(KeyCatalog.all.map(\.id), ["SC1"])
        XCTAssertEqual(KeyCatalog.spec(id: "SC1")?.bladeHeightInches, 0.343)
        XCTAssertEqual(KeyCatalog.spec(id: "SC1")?.depthIncrementInches, 0.015)
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
