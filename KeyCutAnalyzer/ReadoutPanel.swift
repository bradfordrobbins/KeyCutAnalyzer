import SwiftUI
import KeyCutCore

struct ReadoutPanel: View {
    @ObservedObject var camera: CameraController
    var manual: ManualBladeReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let manual {
                manualReadout(manual)
            } else if let scan = camera.scan {
                scanReadout(scan)
            } else {
                legacyReadout
            }
        }
        .padding(10)
        .background(Theme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private func manualReadout(_ reading: ManualBladeReading) -> some View {
        let violations = BittingMath.macsViolations(bites: reading.cuts.map(\.bite), spec: camera.spec)
        return VStack(alignment: .leading, spacing: 6) {
            Text(reading.code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let warning = BittingMath.macsWarning(violations: violations, spec: camera.spec) {
                Text(warning)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CutTable(lines: reading.cuts.enumerated().map { index, cut in
                CutLine(
                    index: index + 1,
                    root: Units.formatInches(cut.depthInches),
                    bite: "\(cut.bite)",
                    deviation: Units.formatSignedInches(cut.deviationInches),
                    position: Units.formatInches(cut.shoulderDistanceInches),
                    ideal: idealPosition(cutNumber: index + 1),
                    offset: horizontalError(measured: cut.shoulderDistanceInches, cutNumber: index + 1),
                    width: "—",
                    band: BittingMath.depthBand(deviationInches: cut.deviationInches, spec: camera.spec)
                )
            })
        }
    }

    private func scanReadout(_ scan: BladeScan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if camera.scanStep >= 9 {
                Text(scan.code)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if camera.scanStep >= 7 {
                Text("Spacing 0.156 in")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            if camera.scanStep >= 8 {
                scanHeader
                ForEach(Array(scan.bites.enumerated()), id: \.offset) { index, bite in
                    HStack(spacing: 0) {
                        Text("\(index + 1)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(Int(scan.pixelDepths[index].rounded()))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(bite)")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 3)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            } else if camera.scanStep >= 2 {
                let count = scan.revealedMinimumCount(at: camera.scanStep)
                ForEach(1...max(count, 1), id: \.self) { index in
                    Text("Minimum \(index) of 5")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(index <= count ? Theme.ink : Theme.muted)
                }
            }
        }
    }

    private var scanHeader: some View {
        HStack(spacing: 0) {
            column("Cut", alignment: .leading)
            column("Pixels", alignment: .trailing)
            column("Bite", alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 2)
    }

    private var legacyReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let code = camera.reading?.code {
                Text(code)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            if let warning = camera.reading?.macsWarning {
                Text(warning)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            cutTable
        }
    }

    private var cutTable: some View {
        CutTable(lines: camera.reading?.cuts.map { cut in
            CutLine(
                index: cut.index,
                root: cut.rootDepthText,
                bite: "\(cut.bite)",
                deviation: cut.deviationText,
                position: Units.formatInches(cut.shoulderDistanceInches),
                ideal: idealPosition(cutNumber: cut.index),
                offset: horizontalError(measured: cut.shoulderDistanceInches, cutNumber: cut.index),
                width: cut.cutWidthText,
                band: BittingMath.depthBand(
                    deviationInches: Units.inches(fromMillimeters: cut.deviationMillimeters),
                    spec: camera.spec
                )
            )
        } ?? (1...5).map { index in
            CutLine(index: index, root: "—", bite: "—", deviation: "—", position: "—", ideal: "—", offset: "—", width: "—", dimmed: true)
        })
    }

    private func idealPosition(cutNumber: Int) -> String {
        let stations = camera.spec.usedStationsInches
        let index = cutNumber - 1
        guard stations.indices.contains(index) else { return "—" }
        return Units.formatInches(stations[index])
    }

    private func horizontalError(measured inches: Double, cutNumber: Int) -> String {
        let stations = camera.spec.usedStationsInches
        let index = cutNumber - 1
        guard stations.indices.contains(index) else { return "—" }
        return Units.formatSignedInches(inches - stations[index])
    }

    private func column(_ title: String, alignment: Alignment) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct CutLine: Identifiable {
    let index: Int
    let root: String
    let bite: String
    let deviation: String
    let position: String
    let ideal: String
    let offset: String
    let width: String
    var band: DepthBand = .nominal
    var dimmed = false

    var id: Int { index }

    var accessibilityText: String {
        var text = "Cut \(index), root \(root) inches, bite \(bite), deviation \(deviation), position \(position) inches, ideal \(ideal) inches, horizontal error \(offset) inches, width \(width)"
        switch band {
        case .nominal:
            break
        case .caution:
            text += ", outside depth tolerance"
        case .fail:
            text += ", beyond depth caution"
        }
        return text
    }

    var rowColor: Color {
        if dimmed { return Theme.muted }
        switch band {
        case .nominal: return Theme.ink
        case .caution: return Theme.caution
        case .fail: return Theme.warn
        }
    }

    var rowBackground: Color {
        switch band {
        case .nominal: return .clear
        case .caution: return Color(red: 0.36, green: 0.26, blue: 0.05)
        case .fail: return Color(red: 0.42, green: 0.10, blue: 0.08)
        }
    }
}

private struct CutTable: View {
    let lines: [CutLine]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("Cut")
                    .gridColumnAlignment(.leading)
                Text("Root in")
                Text("Bite")
                    .gridColumnAlignment(.center)
                Text("Dev in")
                Text("Pos")
                Text("Ideal")
                Text("Shift")
                Text("Width in")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 2)

            ForEach(lines) { line in
                GridRow {
                    Text("\(line.index)")
                    Text(line.root)
                    Text(line.bite)
                    Text(line.deviation)
                    Text(line.position)
                    Text(line.ideal)
                    Text(line.offset)
                    Text(line.width)
                }
                .font(.system(.subheadline, design: .monospaced).weight(line.band == .nominal ? .regular : .semibold))
                .lineLimit(1)
                .foregroundStyle(line.rowColor)
                .padding(.vertical, 3)
                .background(line.rowBackground)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.accessibilityText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
