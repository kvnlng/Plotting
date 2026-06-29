//
//  HapticPreferences.swift
//  Murmur
//
//  User preference for trackpad haptic feedback during chart pan. Stored
//  in UserDefaults via SwiftUI's `@AppStorage`, keyed by a versioned
//  identifier so the value-space can evolve without colliding with older
//  builds. Defaults to `.off` so first launch is silent — analysts opt
//  in from the Settings window (Cmd-,).
//

import Foundation

/// What kind of haptic tick (if any) to emit while the user pans the chart.
/// Force Touch trackpad only; no-op on Magic Mouse and external pointing devices.
public enum HapticMode: String, CaseIterable, Identifiable, Sendable {
    /// No haptic feedback during pan.
    case off
    /// Tick whenever a previously-invisible annotation enters the viewport.
    case allAnnotations
    /// Tick only when a previously-unseen *category* enters the viewport —
    /// fewer ticks in densely annotated regions where many findings of
    /// the same type cluster together.
    case categoryTransitions

    public var id: String { rawValue }

    /// Title shown in the Settings picker.
    public var displayName: String {
        switch self {
        case .off:                  return "Off"
        case .allAnnotations:       return "On every new annotation"
        case .categoryTransitions:  return "On new category only"
        }
    }

    /// One-line description shown beneath the picker.
    public var explanation: String {
        switch self {
        case .off:
            return "No haptic feedback while panning the chart."
        case .allAnnotations:
            return "Soft tick each time a new finding scrolls into the visible window."
        case .categoryTransitions:
            return "Soft tick only when entering a finding category that wasn't on screen — quieter in clusters."
        }
    }
}

/// Centralised keys + defaults for haptic preferences. Bump the version
/// suffix if the meaning of stored values ever changes.
public enum HapticPreferences {
    /// `@AppStorage` key for the active mode. Stored as the enum's
    /// raw string value.
    public static let modeKey = "MurmurHaptics.mode.v1"

    /// Default mode on first launch. Off by design — opt-in surface.
    public static let defaultMode: HapticMode = .off
}
