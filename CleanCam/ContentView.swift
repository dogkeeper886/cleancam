import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isScreenOff = false
    @State private var isSettingsOpen = false
    @State private var savedBrightness: CGFloat = 0.5

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tap: focus and exposure follow that point. Long press: back to faces, or the center.
            PreviewView(previewLayer: camera.previewLayer,
                        onTap: { camera.focus(atPreviewPoint: $0) },
                        onLongPress: { camera.resetFocus() })
                .ignoresSafeArea()
            controls
            if isScreenOff {
                Color.black
                    .ignoresSafeArea()
                    .overlay(Text("\(camera.status) · Tap to turn the screen on").font(.footnote).foregroundColor(.gray))
                    .onTapGesture { setScreenOff(false) }
            }
        }
        .background(Color.black)
        .statusBarHidden()
        .sheet(isPresented: $isSettingsOpen) { SettingsView(camera: camera) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.updateOrientation(UIDevice.current.orientation)
            camera.start()
        }
        .onChange(of: scenePhase) { phase in
            // Give the screen its brightness back before leaving the app.
            if phase != .active { setScreenOff(false) }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(camera.status)
            if !camera.details.isEmpty {
                Text(camera.details)
            }
            if camera.zoomRange.lowerBound < camera.zoomRange.upperBound {
                HStack(spacing: 12) {
                    Slider(value: Binding(get: { camera.zoom }, set: { camera.setZoom($0) }), in: camera.zoomRange)
                        .frame(maxWidth: 280)
                    // Yellow past the lossless zoom, where the camera upscales.
                    Text(String(format: "%.1fx", camera.zoom / camera.zoomDisplayScale))
                        .foregroundStyle(camera.zoom > camera.losslessZoom ? Color.yellow : Color.white)
                        .frame(width: 44)
                }
            }
            // The buttons get their own row so all four fit an upright phone.
            HStack(spacing: 12) {
                Button(camera.isLocked ? "Unlock" : "Lock") { camera.toggleLock() }
                    .buttonStyle(.borderedProminent)
                    .tint(camera.isLocked ? .orange : .gray)
                if camera.hasMic {
                    Button(camera.isMicOn ? "Mute" : "Unmute") { camera.toggleMic() }
                        .buttonStyle(.borderedProminent)
                        .tint(camera.isMicOn ? .gray : .red)
                }
                Button("Screen off") { setScreenOff(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                Button { isSettingsOpen = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                    .accessibilityLabel("Settings")
            }
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    /// iOS stops the camera when the screen really turns off, so "off" is a black screen at the lowest brightness.
    private func setScreenOff(_ off: Bool) {
        guard off != isScreenOff else { return }
        if off {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
        } else {
            UIScreen.main.brightness = savedBrightness
        }
        isScreenOff = off
        camera.setPreviewEnabled(!off)
    }
}

/// Picks the preset. The camera switches as soon as one is picked, and the app keeps it for the next start.
struct SettingsView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(Preset.allCases) { preset in
                        Button { camera.setPreset(preset) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).foregroundColor(.primary)
                                    Text(preset.summary).font(.footnote).foregroundColor(.secondary)
                                }
                                Spacer()
                                if camera.preset == preset {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Preset")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Hosts the camera controller's preview layer and reports taps and long presses on it.
struct PreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    /// Called with the tapped point in the preview layer's coordinates.
    let onTap: (CGPoint) -> Void
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> LayerView {
        LayerView(hosting: previewLayer)
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.onTap = onTap
        uiView.onLongPress = onLongPress
    }

    final class LayerView: UIView {
        var onTap: ((CGPoint) -> Void)?
        var onLongPress: (() -> Void)?
        private let hosted: CALayer

        init(hosting sublayer: CALayer) {
            hosted = sublayer
            super.init(frame: .zero)
            layer.addSublayer(sublayer)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed)))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        // The hosted layer fills the view, so a point in the view is the same point in the layer.
        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            onTap?(recognizer.location(in: self))
        }

        @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { onLongPress?() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
