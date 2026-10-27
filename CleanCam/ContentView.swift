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
            // Each chip jumps to a lens's zoom; in dim light or up close, the camera may keep the wider lens and crop.
            if camera.lensZooms.count > 1 {
                HStack(spacing: 8) {
                    ForEach(camera.lensZooms, id: \.self) { zoom in
                        Button(Self.zoomLabel(zoom / camera.zoomDisplayScale)) { camera.setZoom(zoom) }
                            .buttonStyle(.bordered)
                            .tint(abs(camera.zoom - zoom) < 0.05 ? .yellow : .white)
                    }
                }
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

    /// A lens chip's label, such as "0.5x" or "2x".
    private static func zoomLabel(_ zoom: Double) -> String {
        zoom == zoom.rounded() ? "\(Int(zoom))x" : String(format: "%.1fx", zoom)
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

/// Picks the preset and the camera options. The camera follows each change at once, and the app keeps them for the
/// next start.
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
                Section {
                    if !camera.lenses.isEmpty {
                        Picker("Lens", selection: option(\.lens)) {
                            ForEach([Lens.auto] + camera.lenses) { Text($0.name).tag($0) }
                        }
                    }
                    Picker("Stabilization", selection: option(\.stabilization)) {
                        ForEach(Stabilization.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Near focus", isOn: option(\.nearFocus))
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Auto lets the camera switch lenses as you zoom. Auto stabilization turns on while the phone shakes and off while it stands still; Cinematic steadies most but adds delay. Near focus looks for close subjects first.")
                }
                Section {
                    HStack {
                        Text("Exposure")
                        Spacer()
                        Text(String(format: "%+.1f EV", camera.options.exposureBias)).foregroundColor(.secondary)
                    }
                    Slider(value: option(\.exposureBias), in: CameraOptions.exposureBiasRange, step: 0.1)
                    Toggle("Auto white balance", isOn: Binding(
                        get: { camera.options.whiteBalance == nil },
                        set: { update(\.whiteBalance, $0 ? nil : CameraOptions.defaultWhiteBalance) }))
                    if let kelvins = camera.options.whiteBalance {
                        HStack {
                            Text("White balance")
                            Spacer()
                            Text("\(kelvins) K").foregroundColor(.secondary)
                        }
                        Slider(value: Binding(get: { Double(kelvins) }, set: { update(\.whiteBalance, Int($0)) }),
                               in: Double(CameraOptions.whiteBalanceRange.lowerBound)...Double(CameraOptions.whiteBalanceRange.upperBound),
                               step: 100)
                    }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Lower kelvins turn the picture blue, for warm lamps; higher ones turn it yellow, for shade.")
                }
                Section {
                    Picker("Max bitrate", selection: option(\.maxBitRate)) {
                        Text("No limit").tag(Int?.none)
                        ForEach(CameraOptions.maxBitRates, id: \.self) { Text("\($0 / 1_000_000) Mbps").tag(Int?.some($0)) }
                    }
                } header: {
                    Text("Stream")
                } footer: {
                    Text("On battery the camera runs at 30 fps at most. As the phone heats up, it also drops 4K, the bitrate and stabilization.")
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

    /// A binding that sets one camera option and keeps the others.
    private func option<Value>(_ keyPath: WritableKeyPath<CameraOptions, Value>) -> Binding<Value> {
        Binding(get: { camera.options[keyPath: keyPath] }, set: { update(keyPath, $0) })
    }

    private func update<Value>(_ keyPath: WritableKeyPath<CameraOptions, Value>, _ value: Value) {
        var options = camera.options
        options[keyPath: keyPath] = value
        camera.setOptions(options)
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
