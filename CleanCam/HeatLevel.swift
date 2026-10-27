import Foundation
import UIKit

/// How far the heat guard lowers the stream. On battery it caps the frame rate; as the phone heats up it also drops 4K,
/// the bitrate and stabilization, which all heat the phone.
enum HeatLevel: Int, Comparable {
    case none, battery, hot, critical

    init(thermal: ProcessInfo.ThermalState, battery: UIDevice.BatteryState) {
        switch thermal {
        case .critical: self = .critical
        case .serious: self = .hot
        default: self = battery == .unplugged ? .battery : .none
        }
    }

    static func < (a: HeatLevel, b: HeatLevel) -> Bool { a.rawValue < b.rawValue }

    /// The status line's name for the level, or nil while the guard lowers nothing.
    var name: String? {
        switch self {
        case .none: return nil
        case .battery: return "Battery"
        case .hot: return "Hot"
        case .critical: return "Too hot"
        }
    }

    /// The highest frame rate the camera may run at, or nil for the preset's.
    var topFrameRate: Int? { self == .none ? nil : 30 }
    /// The tallest camera mode, or nil for the preset's.
    var maxHeight: Int? { self >= .hot ? 1080 : nil }
    /// The share of its usual target the bitrate aims for.
    var bitRateShare: Double { self == .hot ? 0.7 : 1 }
    /// The highest bitrate, or nil for no limit.
    var maxBitRate: Int? { self == .critical ? 6_000_000 : nil }
    var allowsStabilization: Bool { self < .hot }
}
