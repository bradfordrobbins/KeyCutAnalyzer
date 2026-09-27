import SwiftUI
import KeyCutCore

struct ReadoutPanel: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Key type", selection: specBinding) {
                ForEach(KeyCatalog.all) { spec in
                    Text(spec.displayName).tag(spec.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.brass)

            codeBlock

            if let warning = camera.reading?.macsWarning {
                Text(warning)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if camera.reading == nil, camera.cameraError == nil {
                Text("Hold the key in profile")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
            }

            if #available(iOS 27, *) {
                Text(camera.isolationHint)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            cutTable
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }

    private var specBinding: Binding<String> {
        Binding(
            get: { camera.spec.id },
            set: { camera.selectSpec(id: $0) }
        )
    }

    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bitting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .textCase(.uppercase)
            if let code = camera.reading?.code {
                Text(code)
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { _ in
                        Text("–")
                            .font(.system(size: 40, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 36, height: 52)
                            .background(Theme.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private var cutTable: some View {
        VStack(spacing: 0) {
            header
            if let cuts = camera.reading?.cuts {
                ForEach(cuts, id: \.index) { cut in
                    CutRow(cut: cut)
                }
            } else {
                ForEach(1...5, id: \.self) { index in
                    EmptyCutRow(index: index)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            column("Cut", width: 36, alignment: .leading)
            column("Root mm", width: 72, alignment: .trailing)
            column("Bite", width: 40, alignment: .trailing)
            column("Dev mm", width: 72, alignment: .trailing)
            column("Shoulder", width: 72, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 6)
    }

    private func column(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .frame(width: width, alignment: alignment)
    }
}

private struct CutRow: View {
    let cut: CutReading

    var body: some View {
        HStack(spacing: 0) {
            Text("\(cut.index)")
                .frame(width: 36, alignment: .leading)
            Text(cut.rootDepthText)
                .frame(width: 72, alignment: .trailing)
            Text("\(cut.bite)")
                .frame(width: 40, alignment: .trailing)
            Text(cut.deviationText)
                .frame(width: 72, alignment: .trailing)
            Text(cut.shoulderDistanceText)
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(cut.outsideDepthTolerance ? Theme.warn : Theme.ink)
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(cut.outsideDepthTolerance ? Theme.warn.opacity(0.16) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "Cut \(cut.index), root \(cut.rootDepthText) millimeters, bite \(cut.bite), deviation \(cut.deviationText), shoulder \(cut.shoulderDistanceText)"
        if cut.outsideDepthTolerance {
            text += ", outside depth tolerance"
        }
        return text
    }
}

private struct EmptyCutRow: View {
    let index: Int

    var body: some View {
        HStack(spacing: 0) {
            Text("\(index)")
                .frame(width: 36, alignment: .leading)
            Text("—")
                .frame(width: 72, alignment: .trailing)
            Text("—")
                .frame(width: 40, alignment: .trailing)
            Text("—")
                .frame(width: 72, alignment: .trailing)
            Text("—")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}
