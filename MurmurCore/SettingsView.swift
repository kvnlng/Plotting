//
//  SettingsView.swift
//  Murmur
//
//  Application-wide preferences, surfaced via the standard macOS Settings
//  window (App menu → Settings…, ⌘,). One TabView per preference category
//  so the same scaffolding extends cleanly when future preferences land.
//

import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            InteractionSettingsTab()
                .tabItem { Label("Interaction", systemImage: "hand.draw") }
        }
        .frame(width: 460, height: 260)
    }
}

/// Pointer / gesture preferences. Currently just haptic feedback — more
/// settings (cursor style, scroll inertia, etc.) can live here too.
private struct InteractionSettingsTab: View {
    @AppStorage(HapticPreferences.modeKey)
    private var hapticMode: HapticMode = HapticPreferences.defaultMode

    var body: some View {
        Form {
            Section {
                Picker("Haptic feedback while panning", selection: $hapticMode) {
                    ForEach(HapticMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(hapticMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Trackpad")
            } footer: {
                Text("Force Touch trackpad required. Magic Mouse and external pointers won't tick.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
