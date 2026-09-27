import XCTest
@testable import KeyCutCore

final class KeyCutCoreTests: XCTestCase {
    private let spec = KeyCatalog.sc1

    func testCatalogIsOnlySC1() {
        XCTAssertEqual(KeyCatalog.all.map(\.id), ["SC1"])
        XCTAssertEqual(KeyCatalog.spec(id: "SC1")?.stationsUsed, 5)
        XCTAssertNil(KeyCatalog.spec(id: "KW1"))
    }

    func testSC1KeepsSixthStationUnused() {
        XCTAssertEqual(spec.stationsFromShoulderInches.count, 6)
        XCTAssertEqual(spec.stationsFromShoulderInches[5], 1.012, accuracy: 1e-12)
        XCTAssertEqual(spec.usedStationsInches.count, 5)
        XCTAssertFalse(spec.usedStationsInches.contains(1.012))
    }

    func testShoulderMillimetersFormat() {
        let formatted = spec.usedStationsInches.map(KeyMath.formatInchesAsMillimeters)
        XCTAssertEqual(formatted, ["5.867", "9.835", "13.802", "17.770", "21.737"])
    }

    func testRootMillimetersFormatAndIncrement() {
        let formatted = spec.rootDepthsInches.map(KeyMath.formatInchesAsMillimeters)
        XCTAssertEqual(
            formatted,
            ["8.509", "8.128", "7.747", "7.366", "6.985", "6.604", "6.223", "5.842", "5.461", "5.080"]
        )
        XCTAssertEqual(spec.depthIncrementInches, 0.015, accuracy: 1e-12)
        for index in 0..<9 {
            XCTAssertEqual(
                spec.rootDepthsInches[index] - spec.rootDepthsInches[index + 1],
                0.015,
                accuracy: 1e-9,
                "depth step \(index) must be 0.015 in, not 0.15"
            )
        }
    }

    func testNearestBiteExactAndHalfway() {
        for bite in 0...9 {
            XCTAssertEqual(KeyMath.nearestBite(rootInches: spec.rootDepthsInches[bite], spec: spec), bite)
        }
        let between0and1 = (spec.rootDepthsInches[0] + spec.rootDepthsInches[1]) / 2
        XCTAssertEqual(KeyMath.nearestBite(rootInches: between0and1, spec: spec), 0)
        XCTAssertEqual(KeyMath.nearestBite(rootInches: between0and1 - 0.0001, spec: spec), 1)

        let between4and5 = (spec.rootDepthsInches[4] + spec.rootDepthsInches[5]) / 2
        XCTAssertEqual(KeyMath.nearestBite(rootInches: between4and5, spec: spec), 4)
        XCTAssertEqual(KeyMath.nearestBite(rootInches: between4and5 - 0.0001, spec: spec), 5)

        XCTAssertEqual(KeyMath.nearestBite(rootInches: 0.400, spec: spec), 0)
        XCTAssertEqual(KeyMath.nearestBite(rootInches: 0.150, spec: spec), 9)
    }

    func testDeviationAndTolerance() {
        let exact = spec.rootDepthsInches[3]
        XCTAssertEqual(KeyMath.deviationMillimeters(measuredRootInches: exact, bite: 3, spec: spec), 0, accuracy: 1e-9)
        XCTAssertFalse(KeyMath.outsideTolerance(measuredRootInches: exact, bite: 3, spec: spec))

        let plusLimit = exact + spec.rootTolerancePlusInches
        XCTAssertFalse(KeyMath.outsideTolerance(measuredRootInches: plusLimit, bite: 3, spec: spec))
        XCTAssertTrue(KeyMath.outsideTolerance(measuredRootInches: plusLimit + 0.0002, bite: 3, spec: spec))

        XCTAssertTrue(KeyMath.outsideTolerance(measuredRootInches: exact - 0.0002, bite: 3, spec: spec))

        let deeper = exact - 0.001
        let deviation = KeyMath.deviationMillimeters(measuredRootInches: deeper, bite: 3, spec: spec)
        XCTAssertEqual(deviation, -0.001 * 25.4, accuracy: 1e-9)
        XCTAssertLessThan(deviation, 0)
    }

    func testMACS() {
        XCTAssertTrue(KeyMath.macsViolatingPairs(bites: [3, 5, 2, 4, 1], spec: spec).isEmpty)
        XCTAssertTrue(KeyMath.macsViolatingPairs(bites: [0, 7], spec: spec).isEmpty)
        XCTAssertEqual(KeyMath.macsViolatingPairs(bites: [0, 8, 0, 4, 6], spec: spec), [0, 1])
        XCTAssertEqual(KeyMath.macsViolatingPairs(bites: [1, 9], spec: spec), [0])
    }

    func testSignedDeviationFormat() {
        XCTAssertEqual(String(format: "%+.3f", 0.0), "+0.000")
        XCTAssertEqual(String(format: "%+.3f", -0.0254), "-0.025")
    }

    func testIdentity35241() throws {
        try assertRecovers(
            [3, 5, 2, 4, 1],
            rotationDegrees: 0,
            pixelsPerInch: 640,
            translation: Point2D(x: 0.25, y: 0.4),
            bowOnRight: false,
            bittingDown: false
        )
    }

    func testRotatedScaledTranslated35241BowLeftBittingUp() throws {
        try assertRecovers(
            [3, 5, 2, 4, 1],
            rotationDegrees: 37,
            pixelsPerInch: 520,
            translation: Point2D(x: 10.7, y: 3.3),
            bowOnRight: false,
            bittingDown: false
        )
    }

    func testRotatedScaledTranslated35241BowRightBittingUp() throws {
        try assertRecovers(
            [3, 5, 2, 4, 1],
            rotationDegrees: 37,
            pixelsPerInch: 700,
            translation: Point2D(x: 4.5, y: 8.2),
            bowOnRight: true,
            bittingDown: false
        )
    }

    func testRotated35241BowLeftBittingDown() throws {
        try assertRecovers(
            [3, 5, 2, 4, 1],
            rotationDegrees: -37,
            pixelsPerInch: 600,
            translation: Point2D(x: 1.15, y: 6.6),
            bowOnRight: false,
            bittingDown: true
        )
    }

    func testRotated35241BowRightBittingDown() throws {
        try assertRecovers(
            [3, 5, 2, 4, 1],
            rotationDegrees: 37 + 180,
            pixelsPerInch: 580,
            translation: Point2D(x: 2.2, y: 9.45),
            bowOnRight: true,
            bittingDown: true
        )
    }

    func test08046IsNotHardcoded() throws {
        try assertRecovers(
            [0, 8, 0, 4, 6],
            rotationDegrees: 15,
            pixelsPerInch: 610,
            translation: Point2D(x: 5.5, y: 2.5),
            bowOnRight: false,
            bittingDown: false
        )
        let reading = try measure(
            [0, 8, 0, 4, 6],
            rotationDegrees: 15,
            pixelsPerInch: 610,
            translation: Point2D(x: 5.5, y: 2.5),
            bowOnRight: true,
            bittingDown: true
        )
        XCTAssertEqual(reading.bittingCode, "08046")
        XCTAssertTrue(reading.macsExceeded)
        XCTAssertNotEqual(reading.bittingCode, "35241")
    }

    func testAspectFillAndFit() {
        let image = Size2D(width: 100, height: 50)
        let view = Size2D(width: 100, height: 100)
        let center = Point2D(x: 50, y: 25)
        let filled = ImageMapping.viewPoint(
            imagePoint: center,
            imageSize: image,
            viewSize: view,
            quarterTurnsClockwise: 0,
            gravity: .resizeAspectFill
        )
        XCTAssertEqual(filled.x, 50, accuracy: 1e-9)
        XCTAssertEqual(filled.y, 50, accuracy: 1e-9)

        let fitted = ImageMapping.viewPoint(
            imagePoint: center,
            imageSize: image,
            viewSize: view,
            quarterTurnsClockwise: 0,
            gravity: .resizeAspectFit
        )
        XCTAssertEqual(fitted.x, 50, accuracy: 1e-9)
        XCTAssertEqual(fitted.y, 50, accuracy: 1e-9)

        let turned = ImageMapping.viewPoint(
            imagePoint: Point2D(x: 0, y: 0),
            imageSize: image,
            viewSize: Size2D(width: 50, height: 100),
            quarterTurnsClockwise: 1,
            gravity: .resizeAspectFit
        )
        // 90° clockwise puts the top-left corner at the top-right of a 50×100 image, which already matches the view.
        XCTAssertEqual(turned.x, 50, accuracy: 1e-6)
        XCTAssertEqual(turned.y, 0, accuracy: 1e-6)
    }

    private func assertRecovers(
        _ bitting: [Int],
        rotationDegrees: Double,
        pixelsPerInch: Double,
        translation: Point2D,
        bowOnRight: Bool,
        bittingDown: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reading = try measure(
            bitting,
            rotationDegrees: rotationDegrees,
            pixelsPerInch: pixelsPerInch,
            translation: translation,
            bowOnRight: bowOnRight,
            bittingDown: bittingDown
        )
        let expected = bitting.map(String.init).joined()
        XCTAssertEqual(reading.bittingCode, expected, "measured \(reading.cuts.map(\.rootText))", file: file, line: line)
        for (cut, bite) in zip(reading.cuts, bitting) {
            let expectedMM = spec.rootDepthsInches[bite] * 25.4
            XCTAssertEqual(
                cut.rootMillimeters,
                expectedMM,
                accuracy: 0.05,
                "cut \(cut.index) bite \(cut.nearestBite) root \(cut.rootText) mm, expected \(String(format: "%.3f", expectedMM))",
                file: file,
                line: line
            )
            XCTAssertEqual(cut.nearestBite, bite, file: file, line: line)
        }
        XCTAssertGreaterThan(reading.pose.pixelsPerInch, 20, file: file, line: line)
    }

    private func measure(
        _ bitting: [Int],
        rotationDegrees: Double,
        pixelsPerInch: Double,
        translation: Point2D,
        bowOnRight: Bool,
        bittingDown: Bool
    ) throws -> KeyReading {
        let image = SyntheticKey.render(
            spec: spec,
            bitting: bitting,
            rotationRadians: rotationDegrees * .pi / 180,
            pixelsPerInch: pixelsPerInch,
            translation: translation,
            bowOnRight: bowOnRight,
            bittingDown: bittingDown
        )
        return try KeyMeasurer.measure(image: image, spec: spec)
    }
}
