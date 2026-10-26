import Foundation

/// What the user streams for. Each preset sets the frame rates auto exposure moves between and the codec; the camera
/// mode and the encoder's bitrate and keyframes follow the top rate.
enum Preset: String, CaseIterable, Identifiable {
    case call, lowLight = "lowlight", obs, wifi

    private static let key = "preset"

    /// The preset the user picked last, or Call.
    static var saved: Preset {
        UserDefaults.standard.string(forKey: key).flatMap { Preset(rawValue: $0) } ?? .call
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .call: return "Call"
        case .lowLight: return "Low light"
        case .obs: return "OBS"
        case .wifi: return "WiFi"
        }
    }

    /// Auto exposure holds the top rate and slows toward the bottom one in the dark, for more light per frame.
    var frameRates: ClosedRange<Int> {
        switch self {
        case .call, .wifi: return 20...30
        case .lowLight: return 15...30
        case .obs: return 30...60
        }
    }

    var summary: String {
        switch self {
        case .call: return "20–30 fps, for Zoom, Meet and Teams, which send 30. Slows toward 20 in a dim room."
        case .lowLight: return "15–30 fps. Slows further in the dark for a brighter, cleaner face, but moves less smoothly."
        case .obs: return "30–60 fps at up to 20 Mbps, for apps that keep every frame, such as OBS. A phone without a 60 fps mode stays at 30."
        case .wifi: return "20–30 fps in HEVC, which carries a better picture in the same 10 Mbps over a WiFi link. A phone without an HEVC encoder sends H.264."
        }
    }

    /// HEVC instead of H.264, where the phone has an HEVC encoder; the receiver detects the codec as it connects.
    var prefersHEVC: Bool { self == .wifi }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}
