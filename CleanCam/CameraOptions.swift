import AVFoundation

/// The camera options the user picked in the settings sheet. The app keeps them for the next start.
struct CameraOptions: Codable, Equatable {
    private static let key = "options"
    /// The fixed white balances the settings sheet offers, in kelvins.
    static let whiteBalanceRange = 2500...8000
    /// The white balance a fixed white balance starts at, in kelvins: daylight.
    static let defaultWhiteBalance = 5000
    /// The exposure compensations the settings sheet offers, in EV.
    static let exposureBiasRange: ClosedRange<Float> = -2...2
    /// The highest bitrates the settings sheet offers.
    static let maxBitRates = [20_000_000, 10_000_000, 6_000_000, 3_000_000]

    var lens = Lens.auto
    var stabilization = Stabilization.auto
    /// Exposure compensation in EV; 0 leaves auto exposure as it is.
    var exposureBias: Float = 0
    /// A fixed white balance in kelvins, or nil for iOS's auto white balance.
    var whiteBalance: Int?
    /// Autofocus looks for near subjects first.
    var nearFocus = false
    /// The highest bitrate the stream sends, or nil for no limit.
    var maxBitRate: Int?

    /// The options the user picked last, or the defaults.
    static var saved: CameraOptions {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(CameraOptions.self, from: $0) }
            ?? CameraOptions()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// The lens the stream uses: Auto lets the multi-lens camera switch lenses as the zoom, the light and the focus
/// distance change; the others hold one lens.
enum Lens: String, Codable, CaseIterable, Identifiable {
    case auto, ultraWide = "ultrawide", wide, tele

    var id: String { rawValue }

    /// The lens of a single-lens camera, such as one of a multi-lens camera's constituents.
    init?(_ type: AVCaptureDevice.DeviceType) {
        switch type {
        case .builtInUltraWideCamera: self = .ultraWide
        case .builtInWideAngleCamera: self = .wide
        case .builtInTelephotoCamera: self = .tele
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .auto: return "Auto"
        case .ultraWide: return "Ultra wide"
        case .wide: return "Wide"
        case .tele: return "Tele"
        }
    }
}

/// The stabilization the user picked: Auto turns it on while the phone shakes and off while it stands still.
enum Stabilization: String, Codable, CaseIterable, Identifiable {
    case auto, off, standard, cinematic

    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto: return "Auto"
        case .off: return "Off"
        case .standard: return "Standard"
        case .cinematic: return "Cinematic"
        }
    }
}
