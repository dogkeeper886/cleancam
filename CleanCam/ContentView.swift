import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            PreviewView(previewLayer: camera.previewLayer)
                .ignoresSafeArea()
            controls
        }
        .background(Color.black)
        .statusBarHidden()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.updateOrientation(UIDevice.current.orientation)
            camera.start()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                camera.start()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                camera.stop()
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.updateOrientation(UIDevice.current.orientation)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Text(camera.status)
            if camera.zoomRange.lowerBound < camera.zoomRange.upperBound {
                Slider(value: Binding(get: { camera.zoom }, set: { camera.setZoom($0) }), in: camera.zoomRange)
                    .frame(maxWidth: 280)
                Text(String(format: "%.1fx", camera.zoom / camera.zoomDisplayScale))
                    .frame(width: 48)
            }
            Button(camera.isLocked ? "Unlock" : "Lock") { camera.toggleLock() }
                .buttonStyle(.borderedProminent)
                .tint(camera.isLocked ? .orange : .gray)
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

/// Hosts the camera controller's preview layer.
struct PreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> LayerView {
        LayerView(hosting: previewLayer)
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        private let hosted: CALayer

        init(hosting sublayer: CALayer) {
            hosted = sublayer
            super.init(frame: .zero)
            layer.addSublayer(sublayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
