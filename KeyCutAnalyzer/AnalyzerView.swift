import SwiftUI

struct AnalyzerView: View {
    @StateObject private var camera = CameraModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .preferredColorScheme(.dark)
        .background(ReadoutPalette.panel)
        .onAppear { camera.start() }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            cameraStage
            ReadoutView(
                keyID: $camera.selectedKeyID,
                reading: camera.reading,
                errorMessage: camera.errorMessage,
                arrangement: .sidebar
            )
            .frame(width: 380)
        }
    }

    private var compactLayout: some View {
        cameraStage
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReadoutView(
                    keyID: $camera.selectedKeyID,
                    reading: camera.reading,
                    errorMessage: camera.errorMessage,
                    arrangement: verticalSizeClass == .compact ? .bottomBar : .bottomSheet
                )
                .frame(maxHeight: verticalSizeClass == .compact ? 156 : 360)
            }
    }

    private var cameraStage: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                reading: camera.reading,
                bufferSize: camera.bufferSize,
                analysisStride: camera.analysisStride
            )
            .ignoresSafeArea()

            if let errorMessage = camera.errorMessage {
                Text(errorMessage)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if camera.devices.count > 1 {
                cameraMenu
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(camera.devices) { device in
                Button {
                    camera.select(deviceID: device.id)
                } label: {
                    if device.id == camera.activeDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel("Switch camera")
    }
}
