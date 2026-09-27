import KeyCutCore
import SwiftUI

enum ReadoutArrangement {
    case sidebar
    case bottomSheet
    case bottomBar
}

enum ReadoutPalette {
    static let panel = Color(red: 0.06, green: 0.07, blue: 0.08)
    static let brass = Color(red: 0.91, green: 0.76, blue: 0.42)
    static let dim = Color(red: 0.62, green: 0.66, blue: 0.71)
    static let warn = Color(red: 0.92, green: 0.38, blue: 0.31)
    static let macs = Color(red: 0.95, green: 0.68, blue: 0.32)
}

struct ReadoutView: View {
    @Binding var keyID: String
    let reading: KeyReading?
    let errorMessage: String?
    let arrangement: ReadoutArrangement

    private var spec: KeySpec {
        KeyCatalog.spec(id: keyID) ?? KeyCatalog.sc1
    }

    var body: some View {
        Group {
            if arrangement == .bottomBar {
                bar
            } else {
                sheet
            }
        }
        .background(ReadoutPalette.panel)
        .foregroundStyle(.white)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            codeBlock
            if let reading {
                CutTable(reading: reading, horizontal: false)
                if reading.macsExceeded {
                    macsWarning
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                header
                codeBlock
                if reading?.macsExceeded == true {
                    macsWarning
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            if let reading {
                ScrollView(.horizontal, showsIndicators: false) {
                    CutTable(reading: reading, horizontal: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("KEY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ReadoutPalette.dim)
                .tracking(1.2)
            Picker("Key", selection: $keyID) {
                ForEach(KeyCatalog.all) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .tint(ReadoutPalette.brass)
            .labelsHidden()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var codeBlock: some View {
        if errorMessage != nil {
            Text("Camera unavailable")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ReadoutPalette.dim)
        } else if let reading {
            Text(spaced(reading.bittingCode))
                .font(.system(size: arrangement == .bottomBar ? 36 : 52, weight: .semibold, design: .monospaced))
                .foregroundStyle(ReadoutPalette.brass)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel("Bitting \(reading.bittingCode)")
        } else {
            Text("Hold the key in profile")
                .font(.system(size: arrangement == .bottomBar ? 18 : 22, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var macsWarning: some View {
        Text("Adjacent cuts exceed MACS \(spec.macs)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ReadoutPalette.macs)
    }

    private func spaced(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}

private struct CutTable: View {
    let reading: KeyReading
    let horizontal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if horizontal {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(reading.cuts, id: \.index) { cut in
                        CutRow(cut: cut, horizontal: true)
                    }
                }
            } else {
                ForEach(reading.cuts, id: \.index) { cut in
                    CutRow(cut: cut, horizontal: false)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Cut").frame(width: 32, alignment: .leading)
            Text("Shoulder mm").frame(maxWidth: .infinity, alignment: .trailing)
            Text("Root mm").frame(maxWidth: .infinity, alignment: .trailing)
            Text("Bite").frame(width: 40, alignment: .trailing)
            Text("Δ mm").frame(width: 68, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(ReadoutPalette.dim)
        .opacity(horizontal ? 0 : 1)
        .frame(height: horizontal ? 0 : nil)
        .clipped()
    }
}

private struct CutRow: View {
    let cut: CutMeasurement
    let horizontal: Bool

    var body: some View {
        Group {
            if horizontal {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cut.index)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ReadoutPalette.dim)
                    digit(cut.shoulderText)
                    digit(cut.rootText)
                    digit("\(cut.nearestBite)")
                        .foregroundStyle(ReadoutPalette.brass)
                    digit(cut.deviationText)
                        .foregroundStyle(cut.outsideTolerance ? ReadoutPalette.warn : .white)
                }
                .padding(8)
            } else {
                HStack(spacing: 0) {
                    Text("\(cut.index)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 32, alignment: .leading)
                    digit(cut.shoulderText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    digit(cut.rootText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    digit("\(cut.nearestBite)")
                        .foregroundStyle(ReadoutPalette.brass)
                        .frame(width: 40, alignment: .trailing)
                    digit(cut.deviationText)
                        .foregroundStyle(cut.outsideTolerance ? ReadoutPalette.warn : .white)
                        .frame(width: 68, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 4)
            }
        }
        .background(
            cut.outsideTolerance ? ReadoutPalette.warn.opacity(0.18) : Color.white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if cut.outsideTolerance {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ReadoutPalette.warn)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func digit(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .monospacedDigit()
    }

    private var accessibilityText: String {
        let tolerance = cut.outsideTolerance ? "Outside depth tolerance." : "Within depth tolerance."
        return "Cut \(cut.index). Shoulder \(cut.shoulderText) millimeters. Root \(cut.rootText) millimeters. Bite \(cut.nearestBite). Deviation \(cut.deviationText) millimeters. \(tolerance)"
    }
}
