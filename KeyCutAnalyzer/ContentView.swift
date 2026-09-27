import SwiftUI
import KeyCutCore

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            let sideBySide = sizeClass == .regular && geo.size.width >= 720
            Group {
                if sideBySide {
                    HStack(spacing: 0) {
                        cameraStage
                        ReadoutPanel(camera: camera)
                            .frame(width: min(380, geo.size.width * 0.36))
                    }
                } else {
                    VStack(spacing: 0) {
                        cameraStage
                        ReadoutPanel(camera: camera)
                            .frame(height: min(340, max(220, geo.size.height * 0.40)))
                    }
                }
            }
        }
        .background(Theme.camera)
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
    }

    private var cameraStage: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                reading: camera.reading,
                imageSize: camera.imageSize,
                onPreviewReady: { camera.attachPreview($0) },
                onTapNormalized: { camera.isolate(atNormalizedTopLeft: $0) },
                onDoubleTap: { camera.clearIsolation() }
            )
            .ignoresSafeArea()

            if let error = camera.cameraError {
                Text(error)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .background(Theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                    .padding(20)
            }

            VStack {
                HStack {
                    Spacer()
                    if camera.canSwitchCamera {
                        Button(action: camera.switchCamera) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title3.weight(.semibold))
                                .padding(10)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .padding(16)
                        .accessibilityLabel("Switch camera")
                    }
                }
                Spacer()
            }
        }
        .background(Theme.camera)
    }
}

enum Theme {
    static let camera = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.13)
    static let ink = Color(red: 0.94, green: 0.92, blue: 0.86)
    static let muted = Color(red: 0.64, green: 0.66, blue: 0.68)
    static let line = Color(red: 0.24, green: 0.26, blue: 0.28)
    static let warn = Color(red: 0.89, green: 0.40, blue: 0.32)
    static let brass = Color(red: 0.86, green: 0.73, blue: 0.42)
}
